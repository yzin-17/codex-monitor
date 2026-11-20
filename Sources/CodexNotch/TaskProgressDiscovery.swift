import Foundation

enum TaskProgressDiscoveryOrigin: String, Codable, Sendable {
    case written, mentioned, read, workspace

    var label: String {
        switch self {
        case .written: "任务创建或更新"
        case .mentioned: "任务明确引用"
        case .read: "任务读取过"
        case .workspace: "目录扫描"
        }
    }
}

struct TaskProgressDiscoveryHint: Equatable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    var origins: [TaskProgressDiscoveryOrigin]
    var sectionHint: String? = nil
    var hasConflictingSectionHints = false
    var shouldAutoBind: Bool { origins.contains(.written) || origins.contains(.mentioned) }
    var reason: String { origins.map(\.label).joined(separator: " · ") }
}

struct TaskProgressDiscoveryResult: Sendable {
    let hints: [TaskProgressDiscoveryHint]
    let workspacePath: String?
    let message: String?
    let hasMore: Bool
    var hasUnreadSessionRecords = false
}

/// 沿用 Task Lens 的只读发现方式，仅检查已经定位的会话文件，不另建全量 Codex 索引。
actor TaskProgressDiscoveryService {
    private struct Cursor {
        var identity: String
        var modifiedAt: Date?
        var offset: UInt64 = 0
        var head = Data()
        var anchor = Data()
        var pending = Data()
        var dropping = false
        var matched = false
        var ownsRecords = false
        var awaitingOwnedBoundary = false
        var createdAt: Date?
        var cwd: String?
        var hints: [TaskProgressDiscoveryHint] = []
        var skipped = 0
        var clipped = false
        var accessedAt = Date()
    }

    private struct DirectoryCache {
        let result: TaskProgressDiscoveryResult
        let createdAt: Date
    }

    private var cursors: [String: Cursor] = [:]
    private var directories: [String: DirectoryCache] = [:]
    private let maximumReadBytes: Int
    private let maximumLineBytes: Int
    private let maximumHints: Int
    private let maximumDirectoryEntries: Int
    private let maximumDirectoryCandidates: Int
    private let scanBudget: TimeInterval
    private static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    private static let ignored: Set<String> = [
        ".git", "node_modules", "vendor", "dist", "build", "coverage", "archive", "archives",
        ".archive", ".next", ".cache", ".venv", ".build", "target"
    ]

    init(maximumReadBytes: Int = 4 * 1_048_576, maximumLineBytes: Int = 1_048_576,
         maximumHints: Int = 256, maximumDirectoryEntries: Int = 10_000,
         maximumDirectoryCandidates: Int = 512, scanBudget: TimeInterval = 0.25) {
        self.maximumReadBytes = max(1, maximumReadBytes)
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.maximumHints = max(1, maximumHints)
        self.maximumDirectoryEntries = max(1, maximumDirectoryEntries)
        self.maximumDirectoryCandidates = max(1, maximumDirectoryCandidates)
        self.scanBudget = max(0.01, scanBudget)
    }

    func scan(threadID: String, rolloutPath: String?, workspacePath: String? = nil,
              includeWorkspace: Bool = true, force: Bool = false) async -> TaskProgressDiscoveryResult {
        guard !Task.isCancelled else { return .init(hints: [], workspacePath: nil, message: nil, hasMore: false) }
        let fallback = Self.absoluteDirectory(workspacePath)
        var hints: [TaskProgressDiscoveryHint] = []
        var workspace = fallback
        var messages: [String] = []
        var hasMore = false
        var hasUnreadSessionRecords = false
        if let path = rolloutPath, path.hasPrefix("/"), path.hasSuffix(".jsonl"),
           !threadID.isEmpty, threadID.utf8.count <= 128 {
            do {
                let read = try readSession(threadID: threadID, path: path, fallback: fallback)
                hints = read.hints
                workspace = read.workspacePath ?? fallback
                if let message = read.message { messages.append(message) }
                hasMore = read.hasMore
                hasUnreadSessionRecords = read.hasMore
            } catch {
                messages.append("会话记录暂时不可读，可重试或手动选择文档。")
            }
        } else if fallback == nil {
            messages.append("尚未取得此任务的会话记录，可选择文档或扫描目录。")
        }
        if includeWorkspace, let workspace, !Task.isCancelled {
            let found = directoryHints(path: workspace, conventionalOnly: true, force: force)
            for hint in found.hints { Self.merge(hint, into: &hints) }
            if let message = found.message { messages.append(message) }
            hasMore = hasMore || found.hasMore
        }
        return .init(hints: hints.sorted(by: Self.precedes), workspacePath: workspace,
                     message: messages.isEmpty ? nil : messages.joined(separator: " "), hasMore: hasMore,
                     hasUnreadSessionRecords: hasUnreadSessionRecords)
    }

    func scanDirectory(path: String) async -> TaskProgressDiscoveryResult {
        guard let path = Self.absoluteDirectory(path) else {
            return .init(hints: [], workspacePath: nil, message: "请选择有效的绝对目录路径。", hasMore: false)
        }
        return directoryHints(path: path, conventionalOnly: false, force: true)
    }

    func reset() { cursors.removeAll(); directories.removeAll() }

    private func readSession(threadID: String, path: String, fallback: String?) throws -> TaskProgressDiscoveryResult {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            throw TaskProgressError.invalid("会话记录不是普通文件。")
        }
        let identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
        let modifiedAt = attributes[.modificationDate] as? Date
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let key = threadID + "\0" + url.path
        var current = cursors[key]
        if let previous = current {
            var changed = previous.identity != identity || size < previous.offset
                || (size == previous.offset && modifiedAt != previous.modifiedAt)
            if !changed, !previous.head.isEmpty {
                try handle.seek(toOffset: 0)
                changed = try handle.read(upToCount: previous.head.count) != previous.head
            }
            if !changed, !previous.anchor.isEmpty {
                try handle.seek(toOffset: previous.offset - UInt64(previous.anchor.count))
                changed = try handle.read(upToCount: previous.anchor.count) != previous.anchor
            }
            if changed { current = nil }
        }
        var cursor = current ?? Cursor(identity: identity, modifiedAt: modifiedAt, cwd: fallback)
        try handle.seek(toOffset: cursor.offset)
        let deadline = ProcessInfo.processInfo.systemUptime + scanBudget
        var remaining = maximumReadBytes
        while cursor.offset < size, remaining > 0, !Task.isCancelled,
              ProcessInfo.processInfo.systemUptime < deadline {
            let amount = min(65_536, remaining, Int(min(size - cursor.offset, UInt64(Int.max))))
            guard let bytes = try handle.read(upToCount: amount), !bytes.isEmpty else { break }
            cursor.offset += UInt64(bytes.count)
            remaining -= bytes.count
            consume(bytes, threadID: threadID, cursor: &cursor)
        }
        if cursor.offset > 0 {
            if cursor.head.isEmpty {
                try handle.seek(toOffset: 0)
                cursor.head = try handle.read(upToCount: min(128, Int(cursor.offset))) ?? Data()
            }
            let count = min(64, Int(cursor.offset))
            try handle.seek(toOffset: cursor.offset - UInt64(count))
            cursor.anchor = try handle.read(upToCount: count) ?? Data()
        }
        cursor.modifiedAt = modifiedAt
        cursor.accessedAt = Date()
        cursors[key] = cursor
        if cursors.count > 256, let oldest = cursors.min(by: { $0.value.accessedAt < $1.value.accessedAt })?.key {
            cursors.removeValue(forKey: oldest)
        }
        let unread = cursor.offset < size
        guard cursor.matched else {
            return .init(hints: [], workspacePath: nil,
                         message: unread ? "正在增量读取会话记录。" : "会话记录未包含匹配的任务标识，未使用其中的文档线索。",
                         hasMore: unread)
        }
        var messages: [String] = []
        if unread { messages.append("正在增量读取会话记录。") }
        if cursor.clipped { messages.append("会话线索超过数量上限，保留最近的文档线索。") }
        if cursor.skipped > 0 { messages.append("已跳过无法解析或过大的日志行。") }
        return .init(hints: cursor.hints, workspacePath: cursor.cwd,
                     message: messages.isEmpty ? nil : messages.joined(separator: " "), hasMore: unread)
    }

    private func consume(_ bytes: Data, threadID: String, cursor: inout Cursor) {
        var start = bytes.startIndex
        for end in bytes.indices where bytes[end] == 0x0A {
            let length = bytes.distance(from: start, to: end)
            if cursor.dropping || cursor.pending.count + length > maximumLineBytes {
                cursor.skipped += 1
                cursor.pending.removeAll(keepingCapacity: false)
                cursor.dropping = false
            } else {
                cursor.pending.append(bytes[start..<end])
                consumeLine(cursor.pending, threadID: threadID, cursor: &cursor)
                cursor.pending.removeAll(keepingCapacity: true)
            }
            start = bytes.index(after: end)
        }
        let rest = bytes[start...]
        if !cursor.dropping, cursor.pending.count + rest.count <= maximumLineBytes {
            cursor.pending.append(rest)
        } else {
            cursor.pending.removeAll(keepingCapacity: false)
            cursor.dropping = true
        }
    }

    private func consumeLine(_ line: Data, threadID: String, cursor: inout Cursor) {
        guard !line.isEmpty else { return }
        guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = row["type"] as? String else { cursor.skipped += 1; return }
        let payload = row["payload"] as? [String: Any] ?? [:]
        if kind == "session_meta" {
            guard let id = payload["id"] as? String, id == threadID else {
                cursor.ownsRecords = false
                return
            }
            cursor.matched = true
            cursor.ownsRecords = true
            cursor.cwd = Self.absoluteDirectory(payload["cwd"] as? String) ?? cursor.cwd
            cursor.createdAt = Self.date(payload["timestamp"] as? String ?? row["timestamp"] as? String)
            let source = payload["source"] as? [String: Any]
            let subagent = (source?["subagent"] ?? source?["subAgent"]) as? [String: Any]
            let spawn = subagent?["thread_spawn"] as? [String: Any]
            cursor.awaitingOwnedBoundary = payload["parent_thread_id"] != nil || payload["parentThreadId"] != nil
                || payload["forked_from_id"] != nil || spawn != nil
            return
        }
        guard cursor.matched else { return }
        let owner = payload["thread_id"] as? String ?? row["thread_id"] as? String
        if let owner, owner != threadID { return }
        if kind == "world_state" {
            cursor.ownsRecords = true
            cursor.awaitingOwnedBoundary = false
            return
        }
        if owner == threadID { cursor.ownsRecords = true; cursor.awaitingOwnedBoundary = false }
        if cursor.awaitingOwnedBoundary, let stamp = Self.date(row["timestamp"] as? String),
           let created = cursor.createdAt, stamp >= created,
           kind == "event_msg", ["task_started", "turn_started"].contains(payload["type"] as? String ?? "") {
            cursor.awaitingOwnedBoundary = false
        }
        guard cursor.ownsRecords, !cursor.awaitingOwnedBoundary else { return }
        if kind == "turn_context" {
            cursor.cwd = Self.absoluteDirectory(payload["cwd"] as? String) ?? cursor.cwd
            return
        }
        guard kind == "event_msg" || kind == "response_item" else { return }
        for hint in TaskProgressHintExtractor.extract(row: row, cwd: cursor.cwd) {
            Self.merge(hint, into: &cursor.hints)
            if cursor.hints.count > maximumHints {
                cursor.hints.removeFirst(cursor.hints.count - maximumHints)
                cursor.clipped = true
            }
        }
    }

    private func directoryHints(path: String, conventionalOnly: Bool, force: Bool) -> TaskProgressDiscoveryResult {
        let key = (conventionalOnly ? "workspace:" : "directory:") + path
        if !force, let cached = directories[key], Date().timeIntervalSince(cached.createdAt) < 30 { return cached.result }
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .init(hints: [], workspacePath: root.path, message: "工作目录暂时不可读。", hasMore: false)
        }
        var found: [TaskProgressDiscoveryHint] = []
        var visited = 0
        var incomplete = false
        let deadline = ProcessInfo.processInfo.systemUptime + scanBudget
        func add(_ url: URL) {
            guard Self.extensions.contains(url.pathExtension.lowercased()),
                  let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  value.isRegularFile == true, value.isSymbolicLink != true else { return }
            Self.merge(.init(path: TaskProgressPath.canonical(url.path), origins: [.workspace]), into: &found)
        }
        if conventionalOnly {
            add(root.appendingPathComponent("TASKS.md"))
            add(root.appendingPathComponent("tasks.md"))
        }
        let roots = conventionalOnly ? [root.appendingPathComponent("tasks"), root.appendingPathComponent("docs/tasks")] : [root]
        for directory in roots {
            guard !incomplete, !Task.isCancelled,
                  let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let walker = FileManager.default.enumerator(at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            while let file = walker.nextObject() as? URL {
                visited += 1
                if Task.isCancelled || visited > maximumDirectoryEntries || found.count >= maximumDirectoryCandidates
                    || ProcessInfo.processInfo.systemUptime >= deadline {
                    incomplete = true; break
                }
                if Self.ignored.contains(file.lastPathComponent.lowercased()) { walker.skipDescendants(); continue }
                guard let value = try? file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
                if value.isSymbolicLink == true { walker.skipDescendants(); continue }
                if value.isDirectory == true {
                    if walker.level >= 32 { walker.skipDescendants(); incomplete = true }
                    continue
                }
                add(file)
            }
        }
        let result = TaskProgressDiscoveryResult(hints: found.sorted(by: Self.precedes), workspacePath: root.path,
            message: incomplete ? "目录扫描达到数量、深度或时间上限，可选择更小的目录继续查找。" : nil, hasMore: incomplete)
        directories[key] = .init(result: result, createdAt: Date())
        if directories.count > 16, let oldest = directories.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            directories.removeValue(forKey: oldest)
        }
        return result
    }

    private static func absoluteDirectory(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), value.utf8.count <= 4_096,
              !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else { return nil }
        return TaskProgressPath.canonical(value)
    }

    private static func merge(_ hint: TaskProgressDiscoveryHint, into hints: inout [TaskProgressDiscoveryHint]) {
        guard let index = hints.firstIndex(where: { $0.path == hint.path }) else { hints.append(hint); return }
        var combined = hints.remove(at: index)
        for origin in hint.origins where !combined.origins.contains(origin) { combined.origins.append(origin) }
        if let section = hint.sectionHint, !combined.hasConflictingSectionHints {
            if let previous = combined.sectionHint, previous != section {
                combined.sectionHint = nil
                combined.hasConflictingSectionHints = true
            } else { combined.sectionHint = section }
        }
        hints.append(combined)
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func precedes(_ a: TaskProgressDiscoveryHint, _ b: TaskProgressDiscoveryHint) -> Bool {
        if a.shouldAutoBind != b.shouldAutoBind { return a.shouldAutoBind }
        if a.origins.contains(.read) != b.origins.contains(.read) { return a.origins.contains(.read) }
        return a.path.localizedStandardCompare(b.path) == .orderedAscending
    }
}

/// 只解释字面路径；不执行 shell、JavaScript、变量替换或 glob。
private enum TaskProgressHintExtractor {
    static func extract(row: [String: Any], cwd: String?) -> [TaskProgressDiscoveryHint] {
        let payload = row["payload"] as? [String: Any] ?? [:]
        let kind = payload["type"] as? String ?? ""
        var hints: [TaskProgressDiscoveryHint] = []
        func add(_ value: String, origin: TaskProgressDiscoveryOrigin, base: String? = nil) {
            if let hint = literalHint(value, origin: origin, cwd: base ?? cwd) { hints.append(hint) }
        }
        func fromText(_ text: String) {
            guard text.utf8.count <= 1_048_576 else { return }
            let pattern = #"\]\((?:<([^>\n]+)>|([^\s)\n]+))(?:\s+[\"'][^\n]*?[\"'])?\)|`([^`\n]+)`"#
            for match in matches(pattern, in: text) {
                for group in 1...3 where match.range(at: group).location != NSNotFound {
                    let raw = (text as NSString).substring(with: match.range(at: group))
                    add(raw.removingPercentEncoding ?? raw, origin: .mentioned)
                }
            }
        }
        if row["type"] as? String == "event_msg", ["user_message", "agent_message"].contains(kind), let text = payload["message"] as? String {
            fromText(text)
        }
        guard row["type"] as? String == "response_item" else { return hints }
        if kind == "message", ["user", "assistant"].contains(payload["role"] as? String ?? ""), let content = payload["content"] as? [[String: Any]] {
            for part in content { if let text = part["text"] as? String { fromText(text) } }
        }
        let name = (payload["name"] as? String ?? "").split(separator: ".").last.map(String.init) ?? ""
        if ["custom_tool_call", "function_call"].contains(kind), name == "apply_patch", let input = payload["input"] as? String {
            hints += patchHints(input, cwd: cwd)
        }
        if kind == "function_call", ["exec_command", "shell_command"].contains(name) {
            let args: [String: Any]?
            if let input = payload["arguments"] as? String { args = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] }
            else { args = payload["arguments"] as? [String: Any] }
            if let command = (args?["cmd"] ?? args?["command"]) as? String {
                hints += commandHints(command, cwd: commandDirectory(args?["workdir"] as? String, fallback: cwd))
            }
        }
        if kind == "custom_tool_call", name == "exec", let input = payload["input"] as? String, input.utf8.count <= 1_048_576 {
            for call in literalCalls(input) {
                if call.name == "apply_patch" {
                    if let value = firstLiteral(call.arguments) { hints += patchHints(value, cwd: cwd) }
                } else {
                    let fields = objectFields(call.arguments)
                    if let command = fields["cmd"] ?? fields["command"] {
                        hints += commandHints(command, cwd: commandDirectory(fields["workdir"], fallback: cwd))
                    }
                }
            }
        }
        return hints
    }

    private static func literalHint(_ input: String, origin: TaskProgressDiscoveryOrigin, cwd: String?) -> TaskProgressDiscoveryHint? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4_096,
              value.rangeOfCharacter(from: CharacterSet(charactersIn: "\0\n\r$`*?<>|")) == nil else { return nil }
        if value.hasPrefix("sandbox:/") { value.removeFirst("sandbox:".count) }
        if value.hasPrefix("file://"), let url = URL(string: value), url.host == nil || url.host == "" || url.host == "localhost" { value = url.path }
        if value.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil { return nil }
        var section: String?
        if let fragment = value.lastIndex(of: "#") {
            let tail = String(value[value.index(after: fragment)...])
            value = String(value[..<fragment])
            if !tail.isEmpty, tail.range(of: #"^L?\d+(?:-L?\d+)?$"#, options: .regularExpression) == nil { section = tail }
        }
        value = value.replacingOccurrences(of: #":\d+(?::\d+)?$"#, with: "", options: .regularExpression)
        guard ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: value).pathExtension.lowercased()), !value.hasPrefix("~") else { return nil }
        let path: String
        if value.hasPrefix("/") { path = value }
        else if let cwd, cwd.hasPrefix("/") { path = URL(fileURLWithPath: cwd).appendingPathComponent(value).path }
        else { return nil }
        return .init(path: TaskProgressPath.canonical(path),
                     origins: [origin], sectionHint: section)
    }

    private static func commandDirectory(_ explicit: String?, fallback: String?) -> String? {
        guard let explicit else { return fallback }
        guard explicit.hasPrefix("/"), !explicit.contains("\0"), !explicit.contains("$"), !explicit.contains("`"), explicit.utf8.count <= 4_096 else { return nil }
        return URL(fileURLWithPath: explicit).standardizedFileURL.path
    }

    private static func patchHints(_ patch: String, cwd: String?) -> [TaskProgressDiscoveryHint] {
        guard patch.utf8.count <= 1_048_576 else { return [] }
        return matches(#"(?m)^\*\*\* (?:(?:Add|Update) File: |Move to: )([^\r\n]+)\r?$"#, in: patch).compactMap { match in
            literalHint((patch as NSString).substring(with: match.range(at: 1)), origin: .written, cwd: cwd)
        }
    }

    private static func commandHints(_ command: String, cwd: String?) -> [TaskProgressDiscoveryHint] {
        guard command.utf8.count <= 65_536, !command.contains("\0") else { return [] }
        // cd、子 shell 和命令替换不能用会话 cwd 猜测；工作目录应来自工具参数。
        guard !command.contains("$("), !command.contains("`"),
              matches(#"(?:^|[\n;&|])\s*\(?\s*cd(?:\s|$)"#, in: command).isEmpty else { return [] }
        var result = patchHints(command, cwd: cwd)
        for words in shellSegments(command) {
            guard !words.isEmpty else { continue }
            var tokens = words
            if tokens.first == "rtk" { tokens.removeFirst(); if tokens.first == "proxy" { tokens.removeFirst() } }
            guard let executable = tokens.first else { continue }
            let name = URL(fileURLWithPath: executable).lastPathComponent
            let readers: Set<String> = ["cat", "head", "tail", "sed", "rg", "grep", "less", "bat", "read", "wc"]
            let writers: Set<String> = ["tee", "touch"]
            if readers.contains(name) || writers.contains(name) {
                for token in tokens.dropFirst() where !token.hasPrefix("-") {
                    if let hint = literalHint(token, origin: writers.contains(name) ? .written : .read, cwd: cwd) { result.append(hint) }
                }
            }
            for (index, token) in tokens.enumerated() where [">", ">>"].contains(token) && index + 1 < tokens.count {
                if let hint = literalHint(tokens[index + 1], origin: .written, cwd: cwd) { result.append(hint) }
            }
            if ["cp", "mv"].contains(name), let target = tokens.last,
               let hint = literalHint(target, origin: .written, cwd: cwd) { result.append(hint) }
        }
        return result
    }

    private static func shellSegments(_ input: String) -> [[String]] {
        let chars = Array(input)
        var segments: [[String]] = [], tokens: [String] = [], token = ""
        var quote: Character?, escaped = false, index = 0
        func flush() { if !token.isEmpty { tokens.append(token); token = "" } }
        func finish() { flush(); if !tokens.isEmpty { segments.append(tokens); tokens = [] } }
        while index < chars.count {
            let char = chars[index]
            if escaped { token.append(char); escaped = false; index += 1; continue }
            if char == "\\", quote != "'" { escaped = true; index += 1; continue }
            if let current = quote {
                if char == current { quote = nil } else { token.append(char) }
            } else if char == "'" || char == "\"" { quote = char }
            else if char == "\n" || char == ";" || char == "|" || char == "&" { finish() }
            else if char == ">" {
                flush()
                if index + 1 < chars.count, chars[index + 1] == ">" { tokens.append(">>"); index += 1 }
                else { tokens.append(">") }
            } else if char.isWhitespace { flush() }
            else { token.append(char) }
            index += 1
        }
        if quote == nil { finish() }
        return segments
    }

    private struct LiteralCall { let name: String; let arguments: String }

    private static func literalCalls(_ input: String) -> [LiteralCall] {
        let chars = Array(input.utf16)
        var result: [LiteralCall] = [], index = 0
        let names = ["tools.exec_command", "tools.shell_command", "tools.apply_patch", "exec_command", "shell_command", "apply_patch"]
        while index < chars.count {
            if let end = skipComment(chars, at: index) { index = end; continue }
            if [34, 39, 96].contains(chars[index]) { index = literal(chars, at: index)?.end ?? chars.count; continue }
            var matched = false
            if index == 0 || !identifier(chars[index - 1]) {
                for name in names {
                    let token = Array(name.utf16)
                    guard index + token.count <= chars.count, Array(chars[index..<(index + token.count)]) == token else { continue }
                    var open = index + token.count
                    while open < chars.count, whitespace(chars[open]) { open += 1 }
                    guard open < chars.count, chars[open] == 40 else { continue }
                    var position = open + 1, depth = 1
                    while position < chars.count, depth > 0 {
                        if let end = skipComment(chars, at: position) { position = end; continue }
                        if [34, 39, 96].contains(chars[position]) { position = literal(chars, at: position)?.end ?? chars.count; continue }
                        if chars[position] == 40 { depth += 1 }
                        if chars[position] == 41 { depth -= 1 }
                        position += 1
                    }
                    if depth == 0 {
                        result.append(.init(name: String(name.split(separator: ".").last!),
                            arguments: String(decoding: chars[(open + 1)..<(position - 1)], as: UTF16.self)))
                    }
                    index = position; matched = true; break
                }
            }
            if !matched { index += 1 }
        }
        return result
    }

    private static func objectFields(_ input: String) -> [String: String] {
        let chars = Array(input.utf16)
        var fields: [String: String] = [:], index = 0, depth = 0
        while index < chars.count {
            if let end = skipComment(chars, at: index) { index = end; continue }
            if chars[index] == 123 { depth += 1; index += 1; continue }
            if chars[index] == 125 { depth -= 1; index += 1; continue }
            var key: String?, end = index
            if [34, 39, 96].contains(chars[index]), let value = literal(chars, at: index) { key = value.value; end = value.end }
            else if identifier(chars[index]) {
                end += 1
                while end < chars.count, identifier(chars[end]) { end += 1 }
                key = String(decoding: chars[index..<end], as: UTF16.self)
            }
            guard let key else { index += 1; continue }
            index = end
            guard depth == 1, ["cmd", "command", "workdir"].contains(key) else { continue }
            while index < chars.count, whitespace(chars[index]) { index += 1 }
            guard index < chars.count, chars[index] == 58 else { continue }
            index += 1
            while index < chars.count, whitespace(chars[index]) { index += 1 }
            guard let value = literal(chars, at: index) else { continue }
            index = value.end
            while index < chars.count, whitespace(chars[index]) { index += 1 }
            if index < chars.count, chars[index] == 44 || chars[index] == 125 { fields[key] = value.value }
        }
        return fields
    }

    private static func firstLiteral(_ input: String) -> String? {
        let chars = Array(input.utf16)
        var index = 0
        while index < chars.count, whitespace(chars[index]) { index += 1 }
        guard let value = literal(chars, at: index) else { return nil }
        index = value.end
        while index < chars.count, whitespace(chars[index]) { index += 1 }
        return index == chars.count ? value.value : nil
    }

    private static func literal(_ chars: [UInt16], at start: Int) -> (value: String, end: Int)? {
        guard start < chars.count, [34, 39, 96].contains(chars[start]) else { return nil }
        let quote = chars[start]
        var value: [UInt16] = [], index = start + 1
        while index < chars.count {
            let char = chars[index]
            if char == quote { return (String(decoding: value, as: UTF16.self), index + 1) }
            if quote == 96, char == 36, index + 1 < chars.count, chars[index + 1] == 123 { return nil }
            if char == 92 {
                index += 1
                guard index < chars.count else { return nil }
                switch chars[index] {
                case 110: value.append(10)
                case 114: value.append(13)
                case 116: value.append(9)
                case 98: value.append(8)
                case 102: value.append(12)
                case 10: break
                case 117, 120:
                    let count = chars[index] == 117 ? 4 : 2
                    guard index + count < chars.count,
                          let code = UInt16(String(decoding: chars[(index + 1)...(index + count)], as: UTF16.self), radix: 16) else { return nil }
                    value.append(code); index += count
                default: value.append(chars[index])
                }
            } else { value.append(char) }
            index += 1
        }
        return nil
    }

    private static func skipComment(_ chars: [UInt16], at index: Int) -> Int? {
        guard index + 1 < chars.count, chars[index] == 47 else { return nil }
        if chars[index + 1] == 47 {
            var end = index + 2
            while end < chars.count, chars[end] != 10 { end += 1 }
            return end
        }
        if chars[index + 1] == 42 {
            var end = index + 2
            while end + 1 < chars.count {
                if chars[end] == 42, chars[end + 1] == 47 { return end + 2 }
                end += 1
            }
            return chars.count
        }
        return nil
    }

    private static func identifier(_ char: UInt16) -> Bool {
        (65...90).contains(char) || (97...122).contains(char) || (48...57).contains(char) || char == 95 || char == 36 || char == 46
    }
    private static func whitespace(_ char: UInt16) -> Bool { [9, 10, 13, 32].contains(char) }
    private static func matches(_ pattern: String, in value: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value))
    }
}
