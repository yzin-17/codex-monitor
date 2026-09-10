import Foundation

/// 只在展开对话时使用；保留当前对话的内存游标，不新增持久化日志副本。
/// 每轮最多 32 MiB / 4 秒；超限通过“继续扫描”恢复，不循环全量重扫。
final class ConversationCostLoader: @unchecked Sendable {
    private struct Node {
        let id: String
        let parentID: String?
        let path: String
        let modified: Date
        let size: UInt64
    }
    private struct Progress {
        var accumulator: ConversationCostAccumulator
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var inode: UInt64 = 0
        var modified = Date.distantPast
        var discarding = false
        var complete = false
        var skillEvidenceGap = false
        var cwd: String?
    }
    private let home: URL
    private let byteBudget: UInt64
    private let wallTime: TimeInterval
    private let lock = NSLock()
    private var selectedID: String?
    private var skillsEnabled = true
    private var nodes: [String: Node] = [:]
    private var progress: [String: Progress] = [:]
    private var enumerator: FileManager.DirectoryEnumerator?
    private var directoryIndex = 0
    private var discoveryDone = false
    private var seenFiles = 0
    private var discoveryWarnings: Set<String> = []
    private let decoder = CodexSessionEventDecoder()
    private var roots: [URL] { [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")] }

    init(codexHome: URL, byteBudget: UInt64 = 32 * 1024 * 1024, wallTime: TimeInterval = 4) {
        home = codexHome.standardizedFileURL.resolvingSymlinksInPath()
        self.byteBudget = max(512 * 1024, byteBudget)
        self.wallTime = max(0.05, wallTime)
    }

    func load(rootID: String, includeSkills: Bool,
              shouldCancel: @escaping @Sendable () -> Bool = { false }) throws -> ConversationCostDetails {
        lock.lock(); defer { lock.unlock() }
        try checkCancellation(shouldCancel)
        let id = rootID.lowercased()
        if selectedID != id || skillsEnabled != includeSkills {
            nodes = [:]; progress = [:]; directoryIndex = 0; enumerator = nil
            discoveryDone = false; seenFiles = 0; discoveryWarnings = []
            selectedID = id; skillsEnabled = includeSkills
        } else if discoveryDone && progress.values.allSatisfy(\.complete) {
            // 用户主动刷新后重新发现新子代理；已读日志仍使用原游标。
            nodes = [:]; directoryIndex = 0; enumerator = nil
            discoveryDone = false; seenFiles = 0; discoveryWarnings = []
        }
        let deadline = ProcessInfo.processInfo.systemUptime + wallTime
        var remaining = byteBudget
        try discover(deadline: deadline, remaining: &remaining, shouldCancel: shouldCancel)
        guard discoveryDone else {
            return ConversationCostDetails(rootID: id, agents: [], skills: [], pending: true,
                diagnostics: ["正在发现对话与子代理关系，请继续扫描。"] + discoveryWarnings.sorted(), observedAt: Date())
        }
        let participants = family(rootID: id)
        var warnings = discoveryWarnings
        var agents: [AgentCostDetail] = []
        var skillRows: [String: SkillTurnCost] = [:]
        var pending = false
        for (agentID, depth) in participants {
            try checkCancellation(shouldCancel)
            guard let node = nodes[agentID] else {
                agents.append(.init(id: agentID, parentID: nil, depth: depth, model: "模型未知",
                    usage: .zero, hasUsage: false, complete: false))
                warnings.insert("主对话日志不可用；不将缺失费用显示为零。")
                continue
            }
            var state = progress[agentID] ?? Progress(accumulator: .init(isChild: depth > 0, skillsEnabled: includeSkills))
            if remaining > 0 && ProcessInfo.processInfo.systemUptime < deadline {
                do { try scan(node, state: &state, deadline: deadline, remaining: &remaining, shouldCancel: shouldCancel) }
                catch is CancellationError { throw CancellationError() }
                catch { state.complete = false; warnings.insert("部分日志读取失败，当前金额仅包含已读取记录。") }
            }
            progress[agentID] = state
            pending = pending || !state.complete
            if state.accumulator.hasGap { warnings.insert("存在计数或日志缺口：缺失部分不猜价，也不分摊给 Skill。") }
            if state.skillEvidenceGap { warnings.insert("部分行过长或损坏，对应代理的 Skill 关联费用暂不可归属。") }
            // 未读完整个子日志前，后部可能还有 world_state 继承分界，不能先展示父历史。
            let canShowUsage = depth == 0 || state.complete
            if !canShowUsage { warnings.insert("子代理日志仍在扫描，尚未确认继承边界；暂不计入该代理费用。") }
            agents.append(.init(id: node.id, parentID: node.parentID, depth: depth,
                model: state.accumulator.models.isEmpty ? state.accumulator.model : state.accumulator.models.sorted().joined(separator: " / "),
                usage: canShowUsage ? state.accumulator.usage : .zero,
                hasUsage: canShowUsage && state.accumulator.hasUsage,
                complete: state.complete && !state.accumulator.hasGap))
            if canShowUsage && !state.skillEvidenceGap {
                for value in state.accumulator.displaySkills {
                    var combined = skillRows[value.id] ?? SkillTurnCost(id: value.id, name: value.name)
                    combined.usage.add(value.usage); combined.turns += value.turns
                    combined.agentIDs.insert(node.id); skillRows[value.id] = combined
                }
            }
        }
        if participants.count >= 256 { warnings.insert("单次明细最多展开 256 个代理，超出部分未计入。") }
        if !includeSkills { warnings.insert("Skills 已关闭，本次不提取 Skill 读取证据。") }
        return ConversationCostDetails(rootID: id, agents: agents,
            skills: skillRows.values.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name },
            pending: pending, diagnostics: warnings.sorted(), observedAt: Date())
    }

    private func discover(deadline: TimeInterval, remaining: inout UInt64,
                          shouldCancel: @escaping @Sendable () -> Bool) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        while directoryIndex < roots.count && !discoveryDone {
            try checkCancellation(shouldCancel)
            if remaining < 256 * 1024 || ProcessInfo.processInfo.systemUptime >= deadline { return }
            if enumerator == nil {
                let root = roots[directoryIndex]
                guard isAllowed(root) else { directoryIndex += 1; continue }
                enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles], errorHandler: { [weak self] _, _ in
                        self?.discoveryWarnings.insert("部分目录不可读，子代理关系可能不完整。")
                        return true
                    })
                if enumerator == nil { directoryIndex += 1; continue }
            }
            guard let url = enumerator?.nextObject() as? URL else {
                enumerator = nil; directoryIndex += 1; continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { enumerator?.skipDescendants(); continue }
            guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-"),
                  values?.isRegularFile == true, isAllowed(url) else { continue }
            seenFiles += 1
            if seenFiles > 50_000 {
                discoveryWarnings.insert("对话文件超过 50,000 个，关系发现结果不完整。")
                discoveryDone = true; enumerator = nil; break
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                discoveryWarnings.insert("部分对话元数据不可读，关系发现结果不完整。")
                continue
            }
            let data: Data
            do { data = try firstLine(handle, remaining: &remaining) }
            catch { try? handle.close(); discoveryWarnings.insert("部分元数据读取失败。"); continue }
            try? handle.close()
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any],
                  let id = (payload["id"] as? String)?.lowercased(), UUID(uuidString: id) != nil,
                  let meta = decoder.meta(from: String(decoding: data, as: UTF8.self)) else {
                discoveryWarnings.insert("部分日志缺少可识别的会话元数据，未猜测父子关系。")
                continue
            }
            let node = Node(id: id, parentID: meta.isSubagent ? meta.parentThreadID : nil,
                path: url.standardizedFileURL.path, modified: values?.contentModificationDate ?? .distantPast,
                size: UInt64(max(0, values?.fileSize ?? 0)))
            if let old = nodes[id] {
                // 同会话归档副本只选一份，不相加；优先完整的大文件。
                if node.size < old.size || (node.size == old.size && node.modified <= old.modified) { continue }
                if node.path != old.path { progress[id] = nil }
            }
            nodes[id] = node
        }
        if directoryIndex >= roots.count { discoveryDone = true }
    }

    private func firstLine(_ handle: FileHandle, remaining: inout UInt64) throws -> Data {
        var result = Data()
        while result.count < 256 * 1024 {
            let chunk = try handle.read(upToCount: 4096) ?? Data()
            remaining -= min(remaining, UInt64(chunk.count))
            if let newline = chunk.firstIndex(of: 10) { result.append(chunk[..<newline]); break }
            if chunk.isEmpty { break }
            result.append(chunk)
        }
        return result
    }

    private func family(rootID: String) -> [(String, Int)] {
        let children = Dictionary(grouping: nodes.values.filter { $0.parentID != nil }, by: { $0.parentID! })
        var result: [(String, Int)] = [(rootID, 0)]; var seen: Set<String> = [rootID]; var cursor = 0
        while cursor < result.count && result.count < 256 {
            let parent = result[cursor]; cursor += 1
            for child in (children[parent.0] ?? []).sorted(by: { $0.id < $1.id }) {
                guard seen.insert(child.id).inserted else { continue }
                if result.count >= 256 { break }
                result.append((child.id, parent.1 + 1))
            }
        }
        return result
    }

    private func scan(_ node: Node, state: inout Progress, deadline: TimeInterval,
                      remaining: inout UInt64, shouldCancel: @escaping @Sendable () -> Bool) throws {
        let url = URL(fileURLWithPath: node.path)
        guard isAllowed(url) else { throw CocoaError(.fileReadNoPermission) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        if state.inode != 0 && (inode != state.inode || size < state.size ||
            (size == state.size && modified != state.modified)) {
            state = Progress(accumulator: .init(isChild: node.parentID != nil, skillsEnabled: skillsEnabled))
        }
        state.inode = inode; state.size = size; state.modified = modified
        guard size > state.offset else { state.complete = true; return }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let result = try SkillJSONLReader.read(handle: handle, startOffset: state.offset, fileSize: size,
            byteBudget: remaining, maxRowBytes: 512 * 1024, initialDiscardingOversizedRow: state.discarding,
            wallDeadlineUptime: deadline, cpuDeadlineNanoseconds: .max,
            shouldCancel: shouldCancel, classify: { _ in .parse }) { data, offset in
                consume(data, offset: offset, state: &state)
            }
        remaining -= min(remaining, result.analyzedBytes)
        state.offset = result.processedOffset; state.discarding = result.discardingOversizedRow
        state.complete = result.stopReason == .endOfFile && !result.hasIncompleteRow
        if result.skippedOversizedRows > 0 { state.accumulator.markGap(); state.skillEvidenceGap = true }
        try checkCancellation(shouldCancel)
    }

    private func consume(_ data: Data, offset: UInt64, state: inout Progress) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            state.accumulator.markGap(); state.skillEvidenceGap = true; return
        }
        let type = object["type"] as? String
        let payload = object["payload"] as? [String: Any] ?? [:]
        let subtype = payload["type"] as? String
        if type == "world_state" {
            if state.accumulator.isChild {
                state.accumulator.resetInheritedHistory(); state.skillEvidenceGap = false
            }
            return
        }
        if type == "session_meta" { state.cwd = payload["cwd"] as? String; return }
        if type == "turn_context" {
            state.cwd = payload["cwd"] as? String ?? state.cwd
            let line = String(decoding: data, as: UTF8.self)
            state.accumulator.setModel(decoder.turnContextModel(from: line))
            if let turn = payload["turn_id"] as? String { state.accumulator.beginTurn(turn) }
            return
        }
        if type == "event_msg" && subtype == "task_started" {
            state.accumulator.beginTurn(payload["turn_id"] as? String ?? "offset-\(offset)"); return
        }
        if type == "event_msg" && ["task_complete", "turn_aborted"].contains(subtype ?? "") {
            state.accumulator.finishTurn(); return
        }
        if type == "event_msg" && subtype == "token_count" {
            let line = String(decoding: data, as: UTF8.self)
            guard let record = decoder.tokenUsageRecord(from: line) else { return }
            let info = payload["info"] as? [String: Any]
            let total = (info?["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int
            state.accumulator.add(record.usage, cumulativeTotal: total,
                fingerprint: "\(record.timestamp):\(record.usage)")
            return
        }
        guard skillsEnabled, type == "response_item" else { return }
        if subtype == "function_call", let call = payload["call_id"] as? String,
           let tool = payload["name"] as? String, let arguments = payload["arguments"] as? String {
            let matches = ConversationSkillReadEvidence.paths(tool: tool, arguments: arguments, cwd: state.cwd)
            state.accumulator.recordRead(callID: call, skills: matches)
        } else if subtype == "function_call_output", let call = payload["call_id"] as? String {
            state.accumulator.completeRead(callID: call, succeeded: ConversationSkillReadEvidence.succeeded(payload))
        }
    }

    private func isAllowed(_ url: URL) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        return roots.contains { root in resolved == root.path || resolved.hasPrefix(root.path + "/") }
    }
    private func checkCancellation(_ check: @Sendable () -> Bool) throws {
        if check() { throw CancellationError() }
    }
}
