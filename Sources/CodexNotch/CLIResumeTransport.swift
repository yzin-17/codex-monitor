import AppKit
import Foundation
import Darwin

private final class ResumeOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var overflow = false
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; if bytes.count + data.count > 8 * 1024 * 1024 { overflow = true } else { bytes.append(data) } }
    func lines() throws -> [Data] {
        lock.lock(); defer { lock.unlock() }
        if overflow { throw CLIResumeError.outputTooLarge }
        var result: [Data] = []
        while let end = bytes.firstIndex(of: 10) { let line = Data(bytes[..<end]); bytes.removeSubrange(...end); if !line.isEmpty { result.append(line) } }
        return result
    }
}
struct CLIResumeNativeFiles {
    static func auth(home: URL) throws -> (CLIResumeIdentity, String) {
        let url = home.appendingPathComponent("auth.json")
        let data: Data
        do { data = try readRegular(url, maximum: 256 * 1024) } catch { throw CLIResumeError.missingAuth }
        let credential: CodexCredentialImport
        do { credential = try CodexCredentialImport.parse(data) } catch { throw CLIResumeError.missingAuth }
        guard !credential.workspaceID.isEmpty,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any], let idToken = tokens["id_token"] as? String else { throw CLIResumeError.unknownIdentity }
        let pieces = idToken.split(separator: ".")
        guard pieces.count == 3 else { throw CLIResumeError.unknownIdentity }
        var raw = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
        guard let decoded = Data(base64Encoded: raw), let payload = try JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let sub = PublicInsightParser.text(payload["sub"], limit: 200), !sub.isEmpty else { throw CLIResumeError.unknownIdentity }
        let identity = CLIResumeIdentity(workspaceID: credential.workspaceID, subject: sub,
            label: PublicInsightParser.text(payload["email"], limit: 200) ?? "本机 Codex 账号")
        // JWT 仅用于标识，不能据此认定登录成功；调用者必须完成带此凭据的官方额度请求。
        return (identity, credential.accessToken)
    }
    static func readRegular(_ url: URL, maximum: Int) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= maximum else { throw CLIResumeError.unsupportedSession }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw CLIResumeError.outputTooLarge }
        return data
    }
    static func context(home: URL, threadID: String, cachedPath: String? = nil) throws -> CLIResumeContext {
        guard UUID(uuidString: threadID) != nil else { throw CLIResumeError.unsupportedSession }
        let root = home.appendingPathComponent("sessions").resolvingSymlinksInPath()
        var selected: URL?
        if let cachedPath, cachedPath.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: cachedPath) { selected = URL(fileURLWithPath: cachedPath) }
        if selected == nil {
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { throw CLIResumeError.unsupportedSession }
            let started = ProcessInfo.processInfo.systemUptime; var visited = 0
            for case let file as URL in enumerator {
                try Task.checkCancellation(); visited += 1
                guard visited <= 30_000, ProcessInfo.processInfo.systemUptime - started < 4 else { throw CLIResumeError.timedOut }
                let info = try file.resourceValues(forKeys: Set(keys))
                if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if info.isRegularFile == true, file.pathExtension == "jsonl", file.lastPathComponent.contains(threadID) {
                    guard selected == nil else { throw CLIResumeError.unsupportedSession }; selected = file
                }
            }
        }
        guard let file = selected, file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw CLIResumeError.unsupportedSession }
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let bytes = info.fileSize, let modified = info.contentModificationDate else { throw CLIResumeError.unsupportedSession }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let head = try handle.read(upToCount: 128 * 1024) ?? Data()
        let offset = max(0, bytes - 4 * 1024 * 1024)
        try handle.seek(toOffset: UInt64(offset))
        var tail = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
        if offset > 0, let newline = tail.firstIndex(of: 10) { tail.removeSubrange(...newline) }
        guard tail.last == 10 else { throw CLIResumeError.busy }
        return try parseContext(head: head, tail: tail, threadID: threadID, path: file.path, size: UInt64(bytes), modified: modified)
    }
    static func parseContext(head: Data, tail: Data, threadID: String, path: String, size: UInt64, modified: Date) throws -> CLIResumeContext {
        guard let first = head.split(separator: 10).first,
              let meta = try JSONSerialization.jsonObject(with: Data(first)) as? [String: Any], meta["type"] as? String == "session_meta",
              let payload = meta["payload"] as? [String: Any], payload["id"] as? String == threadID,
              payload["model_provider"] as? String == "openai" else { throw CLIResumeError.unsupportedSession }
        var latest: [String: Any]?
        for line in tail.split(separator: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw CLIResumeError.unsupportedSession }
            if object["type"] as? String == "turn_context" { latest = object["payload"] as? [String: Any] }
        }
        guard let latest, let cwd = latest["cwd"] as? String, cwd.hasPrefix("/"),
              let model = latest["model"] as? String, let approval = latest["approval_policy"] as? String,
              let sandbox = (latest["sandbox_policy"] as? [String: Any])?["type"] as? String else { throw CLIResumeError.unsupportedSession }
        let context = CLIResumeContext(threadID: threadID, path: path, cwd: cwd, model: model,
            effort: latest["effort"] as? String ?? latest["reasoning_effort"] as? String, sandbox: sandbox, approval: approval,
            fileSize: size, modifiedAt: modified)
        _ = try CLIResumePolicy.arguments(context: context, sandbox: "read-only")
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue else { throw CLIResumeError.unsupportedSession }
        return context
    }
}

@MainActor
struct CLIResumeTransport {
    var executablePath: String?
    var inspectTimeout: TimeInterval = 20
    var runTimeout: TimeInterval = 3600
    private func executable() throws -> URL {
        guard let path = executablePath ?? CodexBrowserLoginClient.executable(), FileManager.default.isExecutableFile(atPath: path) else { throw CLIResumeError.missingCLI }
        return URL(fileURLWithPath: path)
    }
    private func process(home: URL, cwd: URL, args: [String]) throws -> (Process, Pipe, Pipe, ResumeOutputBuffer) {
        let process = Process(), input = Pipe(), output = Pipe(), buffer = ResumeOutputBuffer()
        process.executableURL = try executable(); process.arguments = args
        process.currentDirectoryURL = cwd
        process.environment = CodexBrowserLoginClient.environment(home: home, inherited: ProcessInfo.processInfo.environment)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }
        do { try process.run() } catch { output.fileHandleForReading.readabilityHandler = nil; throw CLIResumeError.missingCLI }
        return (process, input, output, buffer)
    }
    private func finish(_ process: Process, input: Pipe, output: Pipe) async {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        await Task.detached(priority: .utility) {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(40)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit(); try? output.fileHandleForReading.close()
        }.value
    }
    func inspect(home: URL, threadID: String, cachedPath: String? = nil) async throws -> CLIResumeInspection {
        let context = try await Task.detached(priority: .utility) { try CLIResumeNativeFiles.context(home: home, threadID: threadID, cachedPath: cachedPath) }.value
        let (identity, token) = try CLIResumeNativeFiles.auth(home: home)
        let usage = try await CodexAccountHTTPClient().load(account: .init(workspaceID: identity.workspaceID), token: token)
        let last = try await lastTurn(home: home, context: context)
        // CLI 探查之后重新核对文件登录身份，认证失败与额度耗尽是不同状态。
        let current = try CLIResumeNativeFiles.auth(home: home).0
        guard current.key == identity.key else { throw CLIResumeError.changedAccount }
        return .init(context: context, identity: identity, lastTurnID: last.0, quotaPaused: last.1, lastTurnStatus: last.2, usage: usage, checkedAt: Date())
    }
    func lastTurn(home: URL, context: CLIResumeContext) async throws -> (String, Bool, String) {
        let (process, input, output, buffer) = try process(home: home, cwd: home, args: ["-c", "cli_auth_credentials_store=\"file\"", "-c", "model_provider=\"openai\"", "app-server"])
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        let result: Result<(String, Bool, String), Error>
        do {
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_monitor_read", "version": AppInfo.version], "capabilities": ["experimentalApi": true]]])
            let deadline = ProcessInfo.processInfo.systemUptime + inspectTimeout
            var thread: [String: Any]?; var answer: (String, Bool, String)?
            while answer == nil {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CLIResumeError.timedOut }
                for line in try buffer.lines() {
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int else { continue }
                    if object["error"] is [String: Any] {
                        if id == 3 { try send(["id": 4, "method": "thread/read", "params": ["threadId": context.threadID, "includeTurns": true]]); continue }
                        throw CLIResumeError.incompatible
                    }
                    guard let value = object["result"] as? [String: Any] else { throw CLIResumeError.incompatible }
                    switch id {
                    case 1:
                        try send(["method": "initialized", "params": [:]])
                        try send(["id": 5, "method": "config/read", "params": ["includeLayers": false, "cwd": context.cwd]])
                    case 5:
                        guard let config = value["config"] as? [String: Any] else { throw CLIResumeError.incompatible }
                        // 同名 openai 自定义路由不属于此功能支持的官方 CLI 登录范围。
                        if let custom = (config["model_providers"] as? [String: Any])?["openai"] as? [String: Any], !custom.isEmpty { throw CLIResumeError.unsupportedSession }
                        try send(["id": 2, "method": "thread/read", "params": ["threadId": context.threadID, "includeTurns": false]])
                    case 2:
                        guard let t = value["thread"] as? [String: Any], t["id"] as? String == context.threadID,
                              t["cwd"] as? String == context.cwd, t["modelProvider"] as? String == "openai" else { throw CLIResumeError.unsupportedSession }
                        thread = t
                        try send(["id": 3, "method": "thread/turns/list", "params": ["threadId": context.threadID, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"]])
                    case 3:
                        guard var t = thread, let turns = value["data"] as? [[String: Any]], turns.count == 1 else { throw CLIResumeError.incompatible }
                        t["turns"] = turns; answer = try CLIResumePolicy.lastTurn(["thread": t], threadID: context.threadID)
                    case 4: answer = try CLIResumePolicy.lastTurn(value, threadID: context.threadID)
                    default: break
                    }
                }
                if answer == nil { guard process.isRunning else { throw CLIResumeError.incompatible }; try await Task.sleep(for: .milliseconds(50)) }
            }
            result = .success(answer!)
        } catch { result = .failure(error) }
        await finish(process, input: input, output: output)
        try Task.checkCancellation()
        return try result.get()
    }
    func run(home: URL, ticket: CLIResumeTicket, onStarted: @escaping @MainActor () -> Void) async throws {
        try Task.checkCancellation()
        guard try CLIResumeNativeFiles.auth(home: home).0.key == ticket.identity.key else { throw CLIResumeError.changedAccount }
        let current = try await Task.detached(priority: .utility) {
            try CLIResumeNativeFiles.context(home: home, threadID: ticket.id, cachedPath: ticket.context.path)
        }.value
        guard current == ticket.context else { throw CLIResumeError.changedSession }
        let args = try CLIResumePolicy.arguments(context: current, sandbox: ticket.sandbox)
        let (process, input, output, buffer) = try process(home: home, cwd: URL(fileURLWithPath: current.cwd), args: args)
        let result: Result<Void, Error>
        do {
            try input.fileHandleForWriting.write(contentsOf: Data((try CLIResumePolicy.message(ticket.message) + "\n").utf8))
            try input.fileHandleForWriting.close()
            let deadline = ProcessInfo.processInfo.systemUptime + runTimeout
            var started = false; var completed = false; var failed = false
            // 只保留执行状态；正文、工具输出与 stderr 不进入 Monitor 日志或缓存。
            repeat {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CLIResumeError.unknownOutcome }
                for line in try buffer.lines() {
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    switch object["type"] as? String {
                    case "thread.started":
                        guard object["thread_id"] as? String == ticket.id else { throw CLIResumeError.changedSession }
                        started = true; onStarted()
                    case "turn.completed": completed = true
                    case "turn.failed": failed = true
                    default: break
                    }
                }
                if process.isRunning { try await Task.sleep(for: .milliseconds(80)) }
            } while process.isRunning
            // 退出时管道中最后一批事件仍可能排队。
            try await Task.sleep(for: .milliseconds(80))
            for line in try buffer.lines() {
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                if object?["type"] as? String == "turn.completed" { completed = true }
                if object?["type"] as? String == "turn.failed" { failed = true }
                if object?["type"] as? String == "thread.started", object?["thread_id"] as? String == ticket.id { started = true }
            }
            guard process.terminationStatus == 0, started, completed, !failed else { throw CLIResumeError.unknownOutcome }
            result = .success(())
        } catch { result = .failure(error) }
        await finish(process, input: input, output: output)
        try Task.checkCancellation()
        try result.get()
    }
}
