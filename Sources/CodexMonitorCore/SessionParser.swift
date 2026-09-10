import Foundation

struct PendingRead: Codable, Sendable {
    var paths: [String]; var turnID: String; var date: Date?; var offset: UInt64
}
struct ParserState: Codable, Sendable {
    var session: Session
    var previous: Tokens?
    var model = "未知模型"
    var turnID = "local:0"
    var fallbackTurn = 0
    var hasExplicitTurn = false
    var pendingReads: [String: PendingRead] = [:]
    var evidenceKeys: Set<String> = []
    var sampleKeys: Set<String> = []
    var initialized = false
    var lastInput: Int64?
    var contextLimit: Int64?
    init(path: String) { session = Session(id: "unresolved:" + path, files: [path]) }
    mutating func issue(_ text: String) {
        if !session.issues.contains(text), session.issues.count < 30 { session.issues.append(text) }
    }
}

enum SessionParser {
    static func consume(_ data: Data, offset: UInt64, state: inout ParserState, skillsEnabled: Bool) {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            state.issue("存在损坏 JSON 行，统计可能不完整"); return
        }
        let type = JSONValue.text(raw["type"]) ?? ""
        let payload = JSONValue.dict(raw["payload"])
        let date = JSONValue.date(raw["timestamp"])
        if let date { state.session.lastActivity = max(state.session.lastActivity ?? date, date) }
        switch type {
        case "session_meta":
            // 重放文件可能包含祖先的 metadata；只取第一个。
            guard !state.initialized else { return }
            state.initialized = true
            if let id = JSONValue.text(payload["id"]), !id.isEmpty { state.session.id = id }
            state.session.cwd = JSONValue.text(payload["cwd"])
            state.session.forkedFromID = JSONValue.text(payload["forked_from_id"] ?? payload["forkedFromId"])
            state.session.parentID = JSONValue.text(payload["parent_thread_id"])
            if let model = JSONValue.text(payload["model"]) { state.model = model }
            let source = JSONValue.dict(payload["source"])
            if let sub = source["subagent"] {
                state.session.isSubagent = true
                let subDict = JSONValue.dict(sub)
                let spawn = JSONValue.dict(subDict["thread_spawn"])
                state.session.parentID = JSONValue.text(spawn["parent_thread_id"] ?? subDict["parent_thread_id"]) ?? state.session.parentID
            }
            state.session.isSubagent = state.session.isSubagent || state.session.parentID != nil
        case "turn_context":
            if let model = JSONValue.text(payload["model"]) { state.model = model }
            if let cwd = JSONValue.text(payload["cwd"]) { state.session.cwd = cwd }
            if let id = JSONValue.text(payload["turn_id"] ?? payload["turnId"]) {
                state.turnID = id; state.hasExplicitTurn = true
            }
            state.contextLimit = JSONValue.int(payload["model_context_window"]) ?? state.contextLimit
        case "compacted": state.session.compactions += 1
        case "event_msg":
            switch JSONValue.text(payload["type"]) ?? "" {
            case "token_count": readUsage(payload, date: date, offset: offset, state: &state)
            case "task_started", "turn_started":
                state.session.status = "日志显示运行中"
                state.fallbackTurn += 1
                state.turnID = JSONValue.text(payload["turn_id"] ?? payload["turnId"]) ?? "local:\(state.fallbackTurn)"
                state.hasExplicitTurn = true
            case "task_complete", "task_completed", "turn_complete", "turn_completed":
                state.session.status = "已完成"; state.hasExplicitTurn = false
            case "turn_aborted", "task_cancelled", "task_failed", "turn_failed":
                state.session.status = "已中断"; state.hasExplicitTurn = false
            case "user_message":
                if !state.hasExplicitTurn {
                    state.fallbackTurn += 1; state.turnID = "local:\(state.fallbackTurn)"
                    state.hasExplicitTurn = true
                }
                if skillsEnabled {
                    mentions(JSONValue.stringContent(payload["message"]), kind: .requested, date: date, offset: offset, state: &state)
                }
            default: break
            }
        case "response_item":
            if skillsEnabled { readEvidence(payload, date: date, offset: offset, state: &state) }
        default: break // 不认识的事件不作确定性推断。
        }
    }

    private static func readUsage(_ payload: [String: Any], date: Date?, offset: UInt64, state: inout ParserState) {
        let limits = JSONValue.dict(payload["rate_limits"])
        if !limits.isEmpty {
            let bucket = JSONValue.text(limits["limit_id"]) ?? "codex"
            for name in ["primary", "secondary"] {
                let item = JSONValue.dict(limits[name])
                if let used = item["used_percent"] as? Double, used.isFinite,
                   let minutes = JSONValue.int(item["window_minutes"]), minutes > 0 {
                    let window = QuotaWindow(id: "\(bucket):\(name)", minutes: Int(minutes), usedPercent: used,
                        resetsAt: JSONValue.date(item["resets_at"]), observedAt: date)
                    state.session.quotas.removeAll { $0.id == window.id }
                    state.session.quotas.append(window)
                }
            }
        }
        let info = JSONValue.dict(payload["info"])
        let cumulative = JSONValue.tokens(info["total_token_usage"])
        let last = JSONValue.tokens(info["last_token_usage"])
        if let limit = JSONValue.int(info["model_context_window"]) { state.contextLimit = limit }
        state.lastInput = last?.input ?? state.lastInput
        guard let cumulative else {
            if last != nil { state.issue("Token 事件缺少累计计数，未将 last_token_usage 盲目相加") }
            return
        }
        let signature = [date.map { String($0.timeIntervalSince1970) } ?? "undated", state.turnID,
                         "\(cumulative.input)", "\(cumulative.cached)", "\(cumulative.output)", "\(cumulative.reasoning)"].joined(separator: "|")
        guard state.sampleKeys.insert(signature).inserted else { return }
        let delta: Tokens
        var baseline = false
        if let previous = state.previous {
            if cumulative.isAtLeast(previous) {
                delta = cumulative.delta(from: previous)
            } else {
                // 回退可能是重播而非新请求，不猜测重置后的用量。
                state.issue("累计 Token 出现回退；保留历史高水位，未重复计入回退段")
                return
            }
        } else if let last, cumulative == last {
            delta = cumulative
        } else {
            // 不知道首条累计值发生在哪天、哪个模型，只作为未归属基线。
            delta = cumulative; baseline = true
            state.issue("首条累计值含既有历史，基线未归入日期或模型")
        }
        if let last, !baseline, delta != last, delta.total > 0 {
            baseline = true
            state.issue("相邻累计值增量与最后请求不一致，该增量不归属日期或模型")
        }
        state.previous = cumulative
        if let total = JSONValue.int(JSONValue.dict(info["total_token_usage"])["total_tokens"]), total != cumulative.total {
            state.issue("上游 total_tokens 与输入加输出不一致；按输入加输出展示")
        }
        guard delta.total > 0 else { return }
        if date == nil { state.issue("用量事件时间戳缺失或无法解析，未归入时间窗口") }
        state.session.samples.append(UsageSample(id: signature, date: baseline ? nil : date,
            turnID: state.turnID, model: baseline ? "未归属基线" : state.model, tokens: delta, cumulative: cumulative,
            lastInput: last?.input, contextLimit: state.contextLimit, isBaseline: baseline, sourceOffset: offset))
    }

    private static func mentions(_ text: String, kind: EvidenceKind, date: Date?, offset: UInt64, state: inout ParserState) {
        let pattern = #"(?<![\w$])\$([a-z][a-z0-9]*(?:-[a-z0-9]+)*)(?![\w-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(50) {
            add(name: ns.substring(with: match.range(at: 1)), path: nil, kind: kind, date: date, offset: offset, state: &state)
        }
    }

    private static func readEvidence(_ p: [String: Any], date: Date?, offset: UInt64, state: inout ParserState) {
        let type = JSONValue.text(p["type"]) ?? ""
        if type == "message", let role = JSONValue.text(p["role"]), ["user", "assistant"].contains(role) {
            mentions(JSONValue.stringContent(p["content"]), kind: role == "user" ? .requested : .declared,
                     date: date, offset: offset, state: &state)
        }
        if type == "function_call" || type == "custom_tool_call" {
            let tool = JSONValue.text(p["name"]) ?? ""
            guard ["exec_command", "shell_command", "shell", "read_file"].contains(tool) else { return }
            let argsString = JSONValue.text(p["arguments"] ?? p["input"]) ?? ""
            let args = argsString.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            var command = JSONValue.text(args["cmd"] ?? args["command"]) ?? ""
            if let list = args["command"] as? [String] { command = list.joined(separator: " ") }
            let paths: [String]
            if tool == "read_file", let path = JSONValue.text(args["path"] ?? args["file_path"]), path.hasSuffix("/SKILL.md") {
                paths = [resolve(path, cwd: state.session.cwd)]
            } else { paths = readPaths(command, cwd: state.session.cwd) }
            for path in paths {
                add(name: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent, path: path,
                    kind: .readAttempt, date: date, offset: offset, state: &state)
            }
            if !paths.isEmpty, let callID = JSONValue.text(p["call_id"]) {
                if state.pendingReads.count >= 100 { state.pendingReads.removeAll(); state.issue("过多未配对工具调用，部分读取证据未确认") }
                state.pendingReads[callID] = PendingRead(paths: paths, turnID: state.turnID, date: date, offset: offset)
            }
        }
        if ["function_call_output", "custom_tool_call_output"].contains(type),
           let id = JSONValue.text(p["call_id"]), let pending = state.pendingReads.removeValue(forKey: id) {
            let output = JSONValue.stringContent(p["output"])
            let object = JSONValue.dict(p["output"])
            let successful = (object["exit_code"] as? Int == 0) ||
                output.contains("Process exited with code 0") || output.contains("Exit code: 0") ||
                output.contains("\"exit_code\":0") || output.contains("\"exit_code\": 0")
            // 没有明确退出状态时只保留尝试，不因缺少 error 字符串而宣称成功。
            if successful {
                let current = state.turnID; state.turnID = pending.turnID
                for path in pending.paths {
                    add(name: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent, path: path,
                        kind: .fileRead, date: date ?? pending.date, offset: pending.offset, state: &state)
                }
                state.turnID = current
            }
        }
    }
    static func readPaths(_ command: String, cwd: String?) -> [String] {
        // 首版只确认简单读取命令；含管道、重定向、复合命令时宁可漏报，不把 echo/grep 当读取执行。
        guard !command.contains("\n"), !command.contains(";"), !command.contains("|"),
              !command.contains("&&"), !command.contains(">"), !command.contains("$(") else { return [] }
        let parts = shellWords(command)
        guard let first = parts.first else { return [] }
        let executable = URL(fileURLWithPath: first).lastPathComponent
        guard ["cat", "sed", "head", "tail"].contains(executable) else { return [] }
        return Array(Set(parts.dropFirst().filter { $0.hasSuffix("/SKILL.md") || $0 == "SKILL.md" }
            .filter { !$0.contains("$") && !$0.contains("*") }
            .map { resolve($0, cwd: cwd) })).sorted()
    }
    private static func shellWords(_ s: String) -> [String] {
        var result: [String] = []; var current = ""; var quote: Character?; var escape = false
        for c in s {
            if escape { current.append(c); escape = false; continue }
            if c == "\\", quote != "'" { escape = true; continue }
            if c == "\"" || c == "'" {
                if quote == c { quote = nil } else if quote == nil { quote = c } else { current.append(c) }
            } else if c.isWhitespace && quote == nil {
                if !current.isEmpty { result.append(current); current = "" }
            } else { current.append(c) }
        }
        guard quote == nil, !escape else { return [] }
        if !current.isEmpty { result.append(current) }
        return result
    }
    private static func resolve(_ path: String, cwd: String?) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~") { return Paths.url(path).path }
        guard let cwd else { return path }
        return Paths.url(cwd).appendingPathComponent(path).standardizedFileURL.path
    }
    private static func add(name: String, path: String?, kind: EvidenceKind, date: Date?, offset: UInt64, state: inout ParserState) {
        let key = [state.turnID, kind.rawValue, path ?? name].joined(separator: "|")
        guard state.evidenceKeys.insert(key).inserted else { return }
        state.session.evidence.append(SkillEvidence(id: state.session.id + "|" + key, sessionID: state.session.id,
            turnID: state.turnID, name: name, path: path, kind: kind, date: date, sourceOffset: offset,
            sourceFile: state.session.files.first ?? "", cwd: state.session.cwd))
    }
}
