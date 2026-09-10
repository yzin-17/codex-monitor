import Foundation

struct AgentCostDetail: Equatable, Identifiable, Sendable {
    let id: String
    let parentID: String?
    let depth: Int
    let model: String
    let usage: TokenUsageSummary
    let hasUsage: Bool
    let complete: Bool
}

struct SkillTurnCost: Equatable, Identifiable, Sendable {
    let id: String // 规范化 Skill 文件路径，不能按同名目录合并。
    let name: String
    var usage: TokenUsageSummary = .zero
    var turns = 0
    var agentIDs: Set<String> = []
}

struct ConversationCostDetails: Equatable, Sendable {
    let rootID: String
    let agents: [AgentCostDetail]
    let skills: [SkillTurnCost]
    let pending: Bool
    let diagnostics: [String]
    let observedAt: Date
    var usage: TokenUsageSummary {
        agents.reduce(into: .zero) { $0.add($1.usage) }
    }
}

/// 累计计数用于去重，last_token_usage 用于每次请求的定价档位。
/// Skill 金额是“出现成功读取证据的回合总费用”，不是增量账单。
struct ConversationCostAccumulator: Sendable {
    let isChild: Bool
    let skillsEnabled: Bool
    private(set) var usage = TokenUsageSummary.zero
    private(set) var hasUsage = false
    private(set) var model = "模型未知"
    private(set) var models: Set<String> = []
    private(set) var hasGap = false
    private(set) var skills: [String: SkillTurnCost] = [:]
    private var highWater: Int?
    private var lastFingerprint: String?
    private var turnID: String?
    private var turnUsage = TokenUsageSummary.zero
    private var turnSkills: [String: String] = [:]
    private var pendingReads: [String: [String: String]] = [:]
    private var seenCalls: Set<String> = []

    init(isChild: Bool, skillsEnabled: Bool) {
        self.isChild = isChild; self.skillsEnabled = skillsEnabled
    }
    mutating func resetInheritedHistory() {
        guard isChild else { return }
        self = Self(isChild: isChild, skillsEnabled: skillsEnabled)
    }
    mutating func setModel(_ value: String?) {
        model = value.flatMap { $0.isEmpty ? nil : $0 } ?? "模型未知"
    }
    mutating func beginTurn(_ id: String) {
        guard turnID != id else { return }
        finishTurn(); turnID = id
    }
    mutating func markGap() { hasGap = true }
    mutating func recordRead(callID: String, skills: [String: String]) {
        guard skillsEnabled, turnID != nil, !callID.isEmpty, !skills.isEmpty,
              !seenCalls.contains(callID) else { return }
        guard pendingReads.count < 128, seenCalls.count < 4096 else { hasGap = true; return }
        pendingReads[callID] = skills
        seenCalls.insert(callID)
    }
    mutating func completeRead(callID: String, succeeded: Bool) {
        guard let matches = pendingReads.removeValue(forKey: callID), succeeded else { return }
        turnSkills.merge(matches, uniquingKeysWith: { first, _ in first })
    }
    mutating func add(_ value: TokenUsageBreakdown, cumulativeTotal: Int?, fingerprint: String) {
        guard value.totalTokens >= 0 else { hasGap = true; return }
        if let cumulativeTotal {
            guard cumulativeTotal >= 0 else { hasGap = true; return }
            if let previous = highWater, cumulativeTotal <= previous {
                if cumulativeTotal < previous { hasGap = true }
                return
            }
            let delta = cumulativeTotal - (highWater ?? 0)
            let isInitialChildBaseline = isChild && highWater == nil
            highWater = cumulativeTotal
            if delta < value.totalTokens {
                usage.addUnpricedTokens(delta); hasGap = true; hasUsage = true
                return // 差额不按比例猜测，不归属到 Skill。
            }
            if delta > value.totalTokens && !isInitialChildBaseline {
                usage.addUnpricedTokens(delta - value.totalTokens); hasGap = true
            }
        } else {
            // 无累计数据时只排除完全重复的相邻记录，明确降低完整度。
            hasGap = true
            guard fingerprint != lastFingerprint else { return }
        }
        lastFingerprint = fingerprint
        let (componentTotal, overflow) = value.inputTokens.addingReportingOverflow(value.outputTokens)
        guard !overflow, value.inputTokens >= 0, value.outputTokens >= 0,
              value.cachedInputTokens >= 0, value.cachedInputTokens <= value.inputTokens,
              value.reasoningOutputTokens >= 0, value.reasoningOutputTokens <= value.outputTokens,
              componentTotal == value.totalTokens else {
            usage.addUnpricedTokens(value.totalTokens); hasGap = true; hasUsage = true; return
        }
        models.insert(model)
        usage.add(value, model: model); hasUsage = true
        if turnID != nil { turnUsage.add(value, model: model) }
    }
    mutating func finishTurn() {
        if turnUsage.totalTokens > 0 {
            for (path, name) in turnSkills {
                guard skills[path] != nil || skills.count < 512 else { hasGap = true; continue }
                var row = skills[path] ?? SkillTurnCost(id: path, name: name)
                row.usage.add(turnUsage); row.turns += 1; skills[path] = row
            }
        }
        turnID = nil; turnUsage = .zero; turnSkills = [:]; pendingReads = [:]; seenCalls = []
    }
    var displaySkills: [SkillTurnCost] {
        var copy = self; copy.finishTurn()
        return Array(copy.skills.values)
    }
}

/// 仅识别简单读取命令或有文件路径的结构化读取；不执行命令、不缓存正文。
enum ConversationSkillReadEvidence {
    static func paths(tool: String, arguments: String, cwd: String?) -> [String: String] {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let name = tool.split(separator: ".").last.map(String.init) ?? tool
        var rawPaths: [String] = []
        if ["read_file", "skills_read"].contains(name) || tool == "skills.read" {
            if let path = (args["path"] ?? args["file_path"]) as? String { rawPaths = [path] }
        } else if ["exec_command", "shell_command", "shell"].contains(name) {
            var command = (args["cmd"] ?? args["command"]) as? String
            if let vector = (args["cmd"] ?? args["command"]) as? [String], vector.count == 3,
               ["bash", "sh", "zsh"].contains(URL(fileURLWithPath: vector[0]).lastPathComponent),
               ["-c", "-lc"].contains(vector[1]) { command = vector[2] }
            guard let command, var tokens = shellWords(command) else { return [:] }
            if tokens.first == "rtk" {
                tokens.removeFirst()
                if tokens.first == "proxy" { tokens.removeFirst() }
            }
            guard let first = tokens.first else { return [:] }
            let executable = URL(fileURLWithPath: first).lastPathComponent
            guard ["cat", "head", "sed"].contains(executable) else { return [:] }
            // 不接受命令替换、复合命令或“echo SKILL.md”；sed 只接受纯 p 范围。
            if executable == "sed" {
                guard tokens.count == 4, tokens[1] == "-n",
                      tokens[2].range(of: #"^\d+(,\d+)?p$"#, options: .regularExpression) != nil else { return [:] }
                rawPaths = [tokens[3]]
            } else if executable == "head" {
                if tokens.count == 2 { rawPaths = [tokens[1]] }
                else if tokens.count == 4, tokens[1] == "-n", Int(tokens[2]) != nil { rawPaths = [tokens[3]] }
            } else {
                let rest = tokens.dropFirst().filter { $0 != "--" }
                guard !rest.contains(where: { $0.hasPrefix("-") }) else { return [:] }
                rawPaths = Array(rest)
            }
        }
        var result: [String: String] = [:]
        for path in rawPaths.prefix(32) where path.count <= 4096 {
            let expanded = (path as NSString).expandingTildeInPath
            let url: URL
            if expanded.hasPrefix("/") { url = URL(fileURLWithPath: expanded) }
            else if let cwd, cwd.hasPrefix("/") { url = URL(fileURLWithPath: cwd).appendingPathComponent(expanded) }
            else { continue }
            let canonical = url.standardizedFileURL
            guard canonical.lastPathComponent == "SKILL.md" else { continue }
            result[canonical.path] = canonical.deletingLastPathComponent().lastPathComponent
        }
        return result
    }
    static func succeeded(_ payload: [String: Any]) -> Bool {
        if payload["is_error"] as? Bool == true { return false }
        if let code = payload["exit_code"] as? Int { return code == 0 }
        if let object = payload["output"] as? [String: Any], let code = object["exit_code"] as? Int { return code == 0 }
        guard let output = payload["output"] as? String else { return false }
        let prefix = String(output.prefix(1024))
        // 只看工具信封元数据，不在文件正文里寻找“成功”。
        if let marker = prefix.range(of: "Final output:") {
            let metadata = String(prefix[..<marker.lowerBound])
            return metadata.range(of: #"(?m)^Process exited with code 0\s*$"#, options: .regularExpression) != nil
        }
        if let data = output.data(using: .utf8), output.utf8.count < 8192,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let meta = object["metadata"] as? [String: Any], let code = meta["exit_code"] as? Int { return code == 0 }
        return false
    }
    private static func shellWords(_ command: String) -> [String]? {
        guard command.count <= 8192, !command.contains(where: { ";|&<>`$\n\r".contains($0) }) else { return nil }
        var words: [String] = []; var word = ""; var quote: Character?
        for character in command {
            if let active = quote {
                if character == active { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" { quote = character }
            else if character == "\\" { return nil }
            else if character.isWhitespace {
                if !word.isEmpty { words.append(word); word = "" }
            } else { word.append(character) }
        }
        guard quote == nil else { return nil }
        if !word.isEmpty { words.append(word) }
        return words
    }
}
