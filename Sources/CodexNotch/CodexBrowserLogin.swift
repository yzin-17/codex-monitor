import AppKit
import Foundation
import Darwin

/// 由本机 Codex app-server 托管 OAuth/PKCE 和 localhost 回调；本应用不收集密码或 Cookie。
/// 每次登录使用独立、权限为 0700 的 CODEX_HOME，结束时删除，包括 CLI 临时写入的刷新令牌。
enum CodexBrowserLoginError: Error, LocalizedError, Equatable {
    case missingExecutable, launchFailed, timedOut, invalidResponse, rejectedURL, browserUnavailable, loginFailed, outputTooLarge
    var errorDescription: String? {
        switch self {
        case .missingExecutable: "未找到 Codex 可执行文件。请安装 Codex Desktop 或 Codex CLI 后重试；也可使用高级导入。"
        case .launchFailed: "无法启动用于授权的独立 Codex 进程。当前桌面端登录未修改。"
        case .timedOut: "网页登录超时（5 分钟），本次授权已取消。请重试。"
        case .invalidResponse: "Codex 登录协议不兼容或返回无效数据。请更新 Codex Desktop/CLI 后重试。"
        case .rejectedURL: "已拒绝非官方或无效的授权地址。未打开网页，未保存凭据。"
        case .browserUnavailable: "无法打开系统浏览器。本次授权已取消，请检查默认浏览器设置后重试。"
        case .loginFailed: "网页授权未成功或被拒绝，未保存账号。请重试。"
        case .outputTooLarge: "登录进程输出超过限制，已终止本次授权。"
        }
    }
}

struct CodexBrowserLoginProtocol {
    enum Event: Equatable { case initialized, authorization(URL), completed, ignored }
    private(set) var loginID: String?
    private var initialized = false

    static func authorizationURL(_ value: String) throws -> URL {
        guard value.utf8.count < 16_384, let c = URLComponents(string: value),
              c.scheme == "https", let host = c.host?.lowercased(),
              ["auth.openai.com", "auth0.openai.com", "chatgpt.com"].contains(host),
              c.user == nil, c.password == nil, c.fragment == nil,
              c.port == nil || c.port == 443, let url = c.url else { throw CodexBrowserLoginError.rejectedURL }
        // 回调必须是 CLI 的本地地址；禁止开放重定向或把授权码送往第三方。
        let callbacks = (c.queryItems ?? []).filter { $0.name == "redirect_uri" }
        guard callbacks.count == 1, let raw = callbacks[0].value,
              let callback = URLComponents(string: raw), callback.scheme == "http",
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(callback.host ?? ""),
              callback.user == nil, callback.password == nil, callback.query == nil,
              callback.fragment == nil, callback.path == "/auth/callback",
              let port = callback.port, (1...65535).contains(port) else { throw CodexBrowserLoginError.rejectedURL }
        return url
    }

    mutating func consume(_ data: Data) throws -> Event {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexBrowserLoginError.invalidResponse
        }
        if let id = object["id"] as? Int {
            if id == 1, !initialized {
                guard object["error"] == nil || object["error"] is NSNull, object["result"] is [String: Any] else { throw CodexBrowserLoginError.invalidResponse }
                initialized = true; return .initialized
            }
            if id == 2, initialized, loginID == nil {
                guard object["error"] == nil || object["error"] is NSNull, let result = object["result"] as? [String: Any],
                      result["type"] as? String == "chatgpt", let id = result["loginId"] as? String,
                      !id.isEmpty, id.count < 200, let url = result["authUrl"] as? String else { throw CodexBrowserLoginError.invalidResponse }
                let authorized = try Self.authorizationURL(url)
                loginID = id; return .authorization(authorized)
            }
        }
        if object["method"] as? String == "account/login/completed", let expected = loginID,
           let params = object["params"] as? [String: Any], params["loginId"] as? String == expected {
            guard params["success"] as? Bool == true else { throw CodexBrowserLoginError.loginFailed }
            return .completed
        }
        return .ignored
    }
}

private final class LoginOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var exceeded = false
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if bytes.count + data.count > 1_048_576 { exceeded = true; return }
        bytes.append(data)
    }
    func takeLines() throws -> [Data] {
        lock.lock(); defer { lock.unlock() }
        if exceeded { throw CodexBrowserLoginError.outputTooLarge }
        var lines: [Data] = []
        while let end = bytes.firstIndex(of: 10) {
            let line = Data(bytes[..<end]); bytes.removeSubrange(...end)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

@MainActor struct CodexBrowserLoginClient {
    var executablePath: String? = nil
    var timeout: TimeInterval = 300

    static func executable() -> String? {
        if let bundled = CodexRuntimeLocator.executable(named: "codex") { return bundled }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func environment(home: URL, inherited: [String: String]) -> [String: String] {
        var value = inherited
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CHATGPT_ACCESS_TOKEN", "OPENAI_BASE_URL"] { value[key] = nil }
        value["CODEX_HOME"] = home.path
        return value
    }

    nonisolated private static func finish(process: Process, output: Pipe, home: URL) {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.04) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        if process.isRunning { process.waitUntilExit() }
        try? output.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: home)
    }

    func login(openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) async throws -> CodexCredentialImport {
        try Task.checkCancellation()
        guard let path = executablePath ?? Self.executable(), FileManager.default.isExecutableFile(atPath: path) else {
            throw CodexBrowserLoginError.missingExecutable
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-monitor-login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let process = Process(), input = Pipe(), output = Pipe(), buffer = LoginOutputBuffer()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "app-server"]
        process.currentDirectoryURL = home
        process.environment = Self.environment(home: home, inherited: ProcessInfo.processInfo.environment)
        process.standardInput = input; process.standardOutput = output
        // 不保存服务器日志，防止授权 URL、令牌或账号标识进入持久日志。
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in buffer.append(handle.availableData) }
        do { try process.run() }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            try? FileManager.default.removeItem(at: home)
            throw CodexBrowserLoginError.launchFailed
        }
        var protocolState = CodexBrowserLoginProtocol()
        func send(_ object: [String: Any]) throws {
            guard process.isRunning else { throw CodexBrowserLoginError.loginFailed }
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        let result: Result<CodexCredentialImport, Error>
        do {
            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_monitor", "title": "Codex Monitor", "version": AppInfo.version]]])
            let deadline = ProcessInfo.processInfo.systemUptime + max(0.1, min(300, timeout))
            var credential: CodexCredentialImport?
            while credential == nil {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexBrowserLoginError.timedOut }
                for line in try buffer.takeLines() {
                    switch try protocolState.consume(line) {
                    case .initialized:
                        try send(["method": "initialized", "params": [:]])
                        try send(["id": 2, "method": "account/login/start", "params": ["type": "chatgpt"]])
                    case .authorization(let url):
                        try Task.checkCancellation()
                        guard openURL(url) else { throw CodexBrowserLoginError.browserUnavailable }
                    case .completed:
                        let file = home.appendingPathComponent("auth.json")
                        let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                        guard info.isRegularFile == true, info.isSymbolicLink != true,
                              (info.fileSize ?? Int.max) <= CodexCredentialImport.maximumBytes else { throw CodexAccountError.tooLarge }
                        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                        credential = try CodexCredentialImport.parse(handle.read(upToCount: CodexCredentialImport.maximumBytes + 1) ?? Data())
                    case .ignored: break
                    }
                }
                if credential == nil {
                    guard process.isRunning else { throw CodexBrowserLoginError.loginFailed }
                    try await Task.sleep(for: .milliseconds(80))
                }
            }
            try Task.checkCancellation()
            guard let credential else { throw CodexBrowserLoginError.loginFailed }
            result = .success(credential)
        } catch { result = .failure(error) }
        // 只取消本次独立登录，不调用用户当前 Codex 的 logout 或结束桌面端进程。
        if let id = protocolState.loginID { try? send(["id": 9, "method": "account/login/cancel", "params": ["loginId": id]]) }
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        await Task.detached(priority: .utility) { Self.finish(process: process, output: output, home: home) }.value
        try Task.checkCancellation()
        return try result.get()
    }
}
