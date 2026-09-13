import Foundation

/// 只在展开对话时使用；保留当前对话的内存游标，不新增持久化日志副本。
/// 每次调用只处理一个有界协作切片；调用方可在后台连续调用直到追平。
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
        var waitingForAppend = false
        var unavailable = false
        var skillEvidenceGap = false
        var oversizedRowClassification: SkillJSONLRowClassification?
        var cwd: String?
        var sawWorldState = false
        var sawForeignSessionMeta = false
        var childTransitionConfirmed = false
        var candidateTurnID: String?
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
    private var scanCursor = 0
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
            nodes = [:]; progress = [:]; directoryIndex = 0; enumerator = nil; scanCursor = 0
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
                diagnostics: ["正在发现对话与子代理关系。"] + discoveryWarnings.sorted(), observedAt: Date(),
                scanState: .discovering)
        }
        let participants = family(rootID: id)
        var warnings = discoveryWarnings

        // 以轮转顺序处理尚未追平的代理。已完成代理不占用本轮 I/O
        // 预算；实际未用完的切片回收到下一个候选代理。
        let rotated = participants.indices.map { (scanCursor + $0) % max(1, participants.count) }
        var queue = rotated.filter { participantIndex in
            let (agentID, _) = participants[participantIndex]
            guard let node = nodes[agentID] else { return false }
            let state = progress[agentID] ?? Progress(
                accumulator: .init(isChild: node.parentID != nil, skillsEnabled: includeSkills)
            )
            return !state.unavailable && (!state.complete || node.size != state.size ||
                node.modified != state.modified || state.inode == 0) &&
                (!state.waitingForAppend || fileSignatureChanged(node, state: state))
        }
        var scannedCount = 0
        var queueOffset = 0
        while queueOffset < queue.count {
            let participantIndex = queue[queueOffset]
            queueOffset += 1
            let (agentID, _) = participants[participantIndex]
            try checkCancellation(shouldCancel)
            guard let node = nodes[agentID] else { continue }
            var state = progress[agentID] ?? Progress(accumulator: .init(isChild: node.parentID != nil, skillsEnabled: includeSkills))
            let needsScan = !state.unavailable && (!state.complete || node.size != state.size ||
                node.modified != state.modified || state.inode == 0) &&
                (!state.waitingForAppend || fileSignatureChanged(node, state: state))
            guard needsScan, remaining > 0, ProcessInfo.processInfo.systemUptime < deadline else {
                progress[agentID] = state
                continue
            }

            let agentsLeft = max(1, queue[queueOffset...].reduce(into: 0) { count, index in
                let id = participants[index].0
                if let current = progress[id], !current.complete && !current.unavailable { count += 1 }
                else if progress[id] == nil { count += 1 }
            })
            let minimumSlice: UInt64 = 256 * 1024
            let byteSlice = min(remaining, max(minimumSlice, remaining / UInt64(agentsLeft)))
            var localRemaining = byteSlice
            let now = ProcessInfo.processInfo.systemUptime
            let timeSlice = max(0.05, (deadline - now) / Double(agentsLeft))
            let localDeadline = min(deadline, now + timeSlice)
            do {
                try scan(node, state: &state, deadline: localDeadline, remaining: &localRemaining, shouldCancel: shouldCancel)
            } catch is CancellationError { throw CancellationError() }
            catch {
                state.complete = false; state.unavailable = true
                warnings.insert("部分日志读取失败，当前金额仅包含已读取记录。")
            }
            let consumed = min(remaining, byteSlice - localRemaining)
            remaining -= consumed
            progress[agentID] = state
            scannedCount += 1
            if !state.complete && !state.unavailable {
                queue.append(participantIndex)
                // A partial row can make a scan consume zero bytes. Do not
                // spin on it; the next load call will resume after an append.
                if consumed == 0 { break }
            }
            if remaining == 0 || ProcessInfo.processInfo.systemUptime >= deadline { break }
        }
        if !participants.isEmpty {
            scanCursor = queue.dropFirst(queueOffset).first
                ?? (scanCursor + max(1, scannedCount)) % participants.count
        }

        var agents: [AgentCostDetail] = []
        var skillRows: [String: SkillTurnCost] = [:]
        var pending = false
        for (agentID, depth) in participants {
            guard let node = nodes[agentID] else {
                agents.append(.init(id: agentID, parentID: nil, depth: depth, model: "模型未知",
                    usage: .zero, hasUsage: false, complete: false,
                    unavailableReason: .unreadable))
                warnings.insert("主对话日志不可用；不将缺失费用显示为零。")
                continue
            }
        let state = progress[agentID] ?? Progress(accumulator: .init(isChild: depth > 0, skillsEnabled: includeSkills))
            pending = pending || (!state.complete && !state.unavailable)
            if state.accumulator.hasGap { warnings.insert("存在计数或日志缺口：缺失部分不猜价。") }
            let ownershipUnconfirmed = depth > 0 && state.sawForeignSessionMeta && !state.childTransitionConfirmed
            if ownershipUnconfirmed {
                warnings.insert("子代理继承边界未确认；该代理费用保持未知，不将父历史计入。")
            }
            // 未读完整个子日志前，后部可能还有 world_state 继承分界，不能先展示父历史。
            let canShowUsage = depth == 0 || (state.complete && !ownershipUnconfirmed)
            if !canShowUsage && !ownershipUnconfirmed {
                warnings.insert("子代理日志仍在扫描，尚未确认继承边界；暂不计入该代理费用。")
            }
            agents.append(.init(id: node.id, parentID: node.parentID, depth: depth,
                model: state.accumulator.models.isEmpty ? state.accumulator.model : state.accumulator.models.sorted().joined(separator: " / "),
                usage: canShowUsage ? state.accumulator.usage : .zero,
                hasUsage: canShowUsage && state.accumulator.hasUsage,
                complete: state.complete && !state.accumulator.hasGap && !ownershipUnconfirmed,
                hasGap: state.accumulator.hasGap,
                processedBytes: min(state.offset, state.size == 0 ? node.size : state.size),
                targetBytes: max(node.size, state.size),
                unavailableReason: ownershipUnconfirmed ? .ownershipUnconfirmed : (state.unavailable ? .unreadable : nil)))
            if canShowUsage && !state.skillEvidenceGap {
                for value in state.accumulator.displaySkills {
                    var combined = skillRows[value.id] ?? SkillTurnCost(id: value.id, name: value.name)
                    combined.usage.add(value.usage); combined.turns += value.turns
                    combined.agentIDs.insert(node.id); skillRows[value.id] = combined
                }
            }
        }
        if participants.count >= 256 { warnings.insert("单次明细最多展开 256 个代理，超出部分未计入。") }
        let hasSkillEvidenceGap = !skillRows.isEmpty && participants.contains { agentID, _ in
            progress[agentID]?.skillEvidenceGap == true
        }
        let processedBytes = agents.reduce(UInt64(0)) { $0 + min($1.processedBytes, $1.targetBytes) }
        let targetBytes = agents.reduce(UInt64(0)) { $0 + $1.targetBytes }
        let scanState: ConversationCostScanState
        let nextQueuedAgentID = queue.dropFirst(queueOffset).map { participants[$0].0 }.first
        if pending && nextQueuedAgentID != nil {
            let current = queue.dropFirst(queueOffset).map { participants[$0].0 }.first
                ?? agents.first(where: { $0.complete == false })?.id
            scanState = .scanning(processedBytes: processedBytes, targetBytes: targetBytes, currentAgentID: current)
        } else if let waitingID = participants.first(where: { agentID, _ in
            progress[agentID]?.waitingForAppend == true
        })?.0 {
            scanState = .waitingForAppend(processedBytes: processedBytes,
                targetBytes: targetBytes, currentAgentID: waitingID)
        } else if let ownershipUnconfirmed = participants.first(where: { agentID, depth in
            depth > 0 && progress[agentID].map { $0.sawForeignSessionMeta && !$0.childTransitionConfirmed } == true
        }) {
            scanState = .unavailable(agentID: ownershipUnconfirmed.0, reason: .ownershipUnconfirmed)
        } else if pending {
            let current = agents.first(where: { $0.complete == false })?.id
            scanState = .scanning(processedBytes: processedBytes, targetBytes: targetBytes, currentAgentID: current)
        } else if agents.contains(where: { $0.hasGap || $0.usage.unpricedTokens > 0 }) {
            scanState = .gap
        } else if let unavailable = agents.first(where: { !$0.complete }) {
            scanState = .unavailable(agentID: unavailable.id, reason: .unreadable)
        } else if agents.allSatisfy({ !$0.hasUsage }) {
            scanState = .noToken
        } else {
            scanState = .caughtUp
        }
        return ConversationCostDetails(rootID: id, agents: agents,
            skills: skillRows.values.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name },
            pending: pending, diagnostics: warnings.sorted(), observedAt: Date(), scanState: scanState,
            hasSkillEvidenceGap: hasSkillEvidenceGap)
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
        let previousSize = state.size
        let previousInode = state.inode
        let previousModified = state.modified
        if state.waitingForAppend && inode == previousInode && size == previousSize && modified == previousModified {
            // EOF + partial row is a stable observation point. Keep the cursor
            // at the row start so an append can complete it, but do not reread
            // the same bytes on every automatic progress turn.
            return
        }
        if state.inode != 0 && (inode != state.inode || size < state.size ||
            (size == state.size && modified != state.modified)) {
            state = Progress(accumulator: .init(isChild: node.parentID != nil, skillsEnabled: skillsEnabled))
        }
        state.inode = inode; state.size = size; state.modified = modified
        guard size > state.offset else { state.complete = true; return }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let result = try SkillJSONLReader.read(handle: handle, startOffset: state.offset, fileSize: size,
            byteBudget: remaining, maxRowBytes: 512 * 1024, initialDiscardingOversizedRow: state.discarding,
            initialOversizedRowClassification: state.oversizedRowClassification,
            wallDeadlineUptime: deadline, cpuDeadlineNanoseconds: .max,
            shouldCancel: shouldCancel, classify: Self.classifyCostRow) { data, offset in
                consume(data, offset: offset, agentID: node.id, state: &state)
            }
        remaining -= min(remaining, result.analyzedBytes)
        state.offset = result.processedOffset; state.discarding = result.discardingOversizedRow
        state.oversizedRowClassification = result.oversizedRowClassification
        state.complete = result.stopReason == .endOfFile && !result.hasIncompleteRow
        state.waitingForAppend = result.stopReason == .endOfFile && result.hasIncompleteRow
        if result.skippedOversizedRows > 0 { state.accumulator.markGap(); state.skillEvidenceGap = true }
        try checkCancellation(shouldCancel)
    }

    /// `compacted` only carries replacement history. It does not carry fresh
    /// token_count or ownership evidence, so a large row can be skipped without
    /// lowering cost completeness when its outer type is visible before payload.
    private static func classifyCostRow(_ row: Data) -> SkillJSONLRowClassification {
        let prefix = row.prefix(8 * 1024)
        let compacted = Data("\"type\":\"compacted\"".utf8)
        let payload = Data("\"payload\":".utf8)
        guard let typeRange = prefix.range(of: compacted) else { return .parse }
        if let payloadRange = prefix.range(of: payload), payloadRange.lowerBound < typeRange.lowerBound {
            return .parse
        }
        return .irrelevant
    }

    private func fileSignatureChanged(_ node: Node, state: Progress) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: node.path) else { return true }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        return inode != state.inode || size != state.size || modified != state.modified
    }

    private func consume(_ data: Data, offset: UInt64, agentID: String, state: inout Progress) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            state.accumulator.markGap(); state.skillEvidenceGap = true; return
        }
        let type = object["type"] as? String
        let payload = object["payload"] as? [String: Any] ?? [:]
        let subtype = payload["type"] as? String
        if type == "inter_agent_communication_metadata" {
            // 目前通常位于 payload；兼容少数版本把标记放在事件根对象的形状。
            let triggerValue = payload["trigger_turn"] ?? object["trigger_turn"]
            let triggerTurn = triggerValue as? Bool == true
                || (triggerValue as? String)?.lowercased() == "true"
            if state.accumulator.isChild && triggerTurn && !state.childTransitionConfirmed {
                state.accumulator.resetInheritedHistory(
                    preservingModel: state.accumulator.model,
                    preservingTurnID: state.candidateTurnID
                )
                state.childTransitionConfirmed = true
            }
            return
        }
        if type == "world_state" {
            if state.accumulator.isChild {
                state.sawWorldState = true
                // Older rollout versions do not emit inter-agent metadata. Their
                // single world_state is the bounded fallback boundary, unless
                // the copied parent session_meta proves the newer shape.
                let kind = payload["kind"] as? String
                if kind == "child_start" || !state.sawForeignSessionMeta {
                    state.accumulator.resetInheritedHistory(
                        preservingModel: state.accumulator.model,
                        preservingTurnID: state.candidateTurnID
                    )
                    state.childTransitionConfirmed = true
                    state.skillEvidenceGap = false
                }
            }
            return
        }
        if type == "session_meta" {
            let isOwnSessionMeta = (payload["id"] as? String)?.lowercased() == agentID.lowercased()
            if isOwnSessionMeta {
                state.cwd = payload["cwd"] as? String ?? state.cwd
            } else if payload["id"] != nil {
                state.sawForeignSessionMeta = true
            }
            // 某些 Codex 版本会把实际模型直接写进子代理 session_meta。只接受明确字段，
            // 不从父代理、文件名或角色猜测模型。
            if let model = (payload["model"] as? String) ?? (payload["model_name"] as? String),
               isOwnSessionMeta,
               !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.accumulator.setModel(model)
            }
            return
        }
        if type == "turn_context" {
            state.cwd = payload["cwd"] as? String ?? state.cwd
            let line = String(decoding: data, as: UTF8.self)
            state.accumulator.setModel(decoder.turnContextModel(from: line))
            if let turn = payload["turn_id"] as? String {
                state.accumulator.beginTurn(turn)
                if state.accumulator.isChild && state.sawWorldState && !state.childTransitionConfirmed {
                    state.candidateTurnID = turn
                }
            }
            return
        }
        if type == "event_msg" && subtype == "task_started" {
            let turn = payload["turn_id"] as? String ?? "offset-\(offset)"
            state.accumulator.beginTurn(turn)
            if state.accumulator.isChild && state.sawWorldState && !state.childTransitionConfirmed {
                state.candidateTurnID = turn
            }
            return
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
