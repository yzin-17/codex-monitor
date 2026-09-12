import Foundation
import Combine
import Security
import LocalAuthentication

private final class NoCodexAccountRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct CodexAccountHTTPClient: Sendable {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    var fetch: @Sendable (URLRequest) async throws -> Data = Self.read
    static func request(account: CodexAccount, token: String) throws -> URLRequest {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        try CodexCredentialImport.validateToken(token)
        try CodexCredentialImport.validateWorkspace(account.workspaceID)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !account.workspaceID.isEmpty { request.setValue(account.workspaceID, forHTTPHeaderField: "ChatGPT-Account-Id") }
        return request
    }
    static func read(_ request: URLRequest) async throws -> Data {
        guard request.url == endpoint, request.httpMethod == "GET", request.httpBody == nil else { throw CodexAccountError.invalidCredential }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12; configuration.timeoutIntervalForResource = 18
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoCodexAccountRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw CodexAccountError.invalidResponse }
        if (300..<400).contains(response.statusCode) { throw CodexAccountError.redirect }
        guard response.statusCode == 200 else { throw CodexAccountError.http(response.statusCode) }
        guard response.expectedContentLength <= CodexAccountUsageParser.maximumBytes else { throw CodexAccountError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < CodexAccountUsageParser.maximumBytes else { throw CodexAccountError.tooLarge }
            data.append(byte)
        }
        return data
    }
    func load(account: CodexAccount, token: String) async throws -> CodexAccountUsage {
        let data = try await fetch(Self.request(account: account, token: token))
        try Task.checkCancellation()
        return try CodexAccountUsageParser.parse(data, workspaceID: account.workspaceID)
    }
}
struct CodexAccountVault: Sendable {
    var read: @Sendable (CodexAccount, Bool) throws -> String
    var write: @Sendable (CodexAccount, String) throws -> Void
    var delete: @Sendable (CodexAccount) throws -> Void
    static let keychain = Self(read: { account, interactive in
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(account), kSecAttrAccount as String: account.id.uuidString,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data, let token = String(data: data, encoding: .utf8) else { throw CodexAccountError.missingCredential }
        return token
    }, write: { account, token in
        do { try KeychainStore.write(token, service: service(account), account: account.id.uuidString) }
        catch { throw CodexAccountError.keychain }
    }, delete: { account in
        do { try KeychainStore.delete(service: service(account), account: account.id.uuidString) }
        catch { throw CodexAccountError.keychain }
    })
    private static func service(_ account: CodexAccount) -> String { "dev.yzin.codexmonitor.codex-accounts" }
}
struct CodexAccountState {
    var usage: CodexAccountUsage?
    var error: String?
    var isRefreshing = false
    var isStale: Bool { error != nil && usage != nil }
}
@MainActor final class CodexAccountsStore: ObservableObject {
    @Published private(set) var accounts: [CodexAccount]
    @Published private(set) var states: [UUID: CodexAccountState] = [:]
    @Published private(set) var currentLocalAccountID: String?
    @Published private(set) var localIdentityChangedAt: Date?
    @Published var monitoringEnabled: Bool { didSet { defaults.set(monitoringEnabled, forKey: "codexAccounts.enabled"); reconfigure() } }
    @Published var interval: Double { didSet { defaults.set(min(1800, max(60, interval)), forKey: "codexAccounts.interval"); schedule() } }
    @Published var lastError: String?
    private let defaults: UserDefaults
    private let vault: CodexAccountVault
    private let client: CodexAccountHTTPClient
    private let localAuthURL: URL
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]
    private var verifications: [UUID: UUID] = [:]
    private var queue: [(UUID, Bool)] = []
    private var timer: Timer?
    private var localIdentityWatcher: CodexFileWatcher?
    private var localIdentityPollTimer: Timer?
    private var lastLocalAuthModificationDate: Date?
    private let automaticStart: Bool
    init(defaults: UserDefaults = .standard, vault: CodexAccountVault = .keychain,
         client: CodexAccountHTTPClient = .init(), automaticStart: Bool = true,
         localAuthURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")) {
        self.defaults = defaults; self.vault = vault; self.client = client; self.automaticStart = automaticStart
        self.localAuthURL = localAuthURL
        currentLocalAccountID = nil
        localIdentityChangedAt = nil
        let loadedAccounts = defaults.data(forKey: "codexAccounts.v1").flatMap { try? JSONDecoder().decode([CodexAccount].self, from: $0) } ?? []
        var ids = Set<UUID>(); accounts = Array(loadedAccounts.filter { ids.insert($0.id).inserted }.prefix(30))
        monitoringEnabled = defaults.bool(forKey: "codexAccounts.enabled")
        let stored = defaults.double(forKey: "codexAccounts.interval")
        interval = stored.isFinite && stored >= 60 ? min(1800, stored) : 300
        if automaticStart {
            startLocalIdentityMonitoring()
            reconfigure()
        }
    }
    /// HTTP 额度请求成功之后才保存。JWT 解码或文件存在本身不算验证。
    func verifyAndSave(_ draft: CodexAccount, token: String) async throws {
        var next = draft
        next.label = String(next.label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        next.workspaceID = next.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.label.isEmpty else { throw CodexAccountError.invalidResponse }
        let old = accounts.first { $0.id == next.id }
        guard old != nil || accounts.count < 30 else { throw CodexAccountError.invalidResponse }
        let replacement = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard old != nil || !replacement.isEmpty else { throw CodexAccountError.missingCredential }
        if let old, old.workspaceID != next.workspaceID && replacement.isEmpty { throw CodexAccountError.missingCredential }
        let ticket = UUID(); verifications[next.id] = ticket
        defer { if verifications[next.id] == ticket { verifications[next.id] = nil } }
        let secret = try replacement.isEmpty ? vault.read(next, true) : replacement
        let usage = try await client.load(account: next, token: secret)
        try Task.checkCancellation()
        guard verifications[next.id] == ticket, accounts.first(where: { $0.id == next.id })?.revision == old?.revision,
              old != nil || accounts.count < 30 else { throw CodexAccountError.superseded }
        // 保存失败保留旧元数据、旧快照；只有验证通过的新凭据进入本应用 Keychain。
        if !replacement.isEmpty { try vault.write(next, replacement) }
        if let old, old.workspaceID != next.workspaceID { next.boundLocalAccountID = nil }
        next.revision = UUID(); next.verifiedAt = usage.capturedAt
        cancel(id: next.id)
        if let index = accounts.firstIndex(where: { $0.id == next.id }) { accounts[index] = next } else { accounts.append(next) }
        states[next.id] = .init(usage: usage)
        persist(); lastError = nil; pump()
    }
    func cancelVerification(id: UUID) { verifications[id] = nil }
    func remove(_ account: CodexAccount) throws {
        try vault.delete(account)
        cancelVerification(id: account.id) // 失败时不丢失可恢复的账户配置。
        cancel(id: account.id); states[account.id] = nil
        accounts.removeAll { $0.id == account.id }; persist(); pump()
    }
    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        cancelVerification(id: id); cancel(id: id); states[id] = nil
        accounts[index].enabled = enabled; accounts[index].revision = UUID(); persist()
        if enabled { refresh(id: id) }; pump()
    }
    func bindCurrentLocalAccount(to id: UUID) {
        refreshLocalIdentity(force: true)
        guard let currentLocalAccountID, !currentLocalAccountID.isEmpty else {
            lastError = "未检测到当前本机 Codex 账号，无法绑定。"
            return
        }
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        if let conflict = accounts.first(where: { $0.id != id && $0.boundLocalAccountID == currentLocalAccountID }) {
            lastError = "当前本机账号已绑定到“\(conflict.label)”，请先解绑。"
            return
        }
        accounts[index].boundLocalAccountID = currentLocalAccountID
        persist(); lastError = nil
    }
    func unbindLocalAccount(id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].boundLocalAccountID = nil
        persist(); lastError = nil
    }
    func canUseLocalFallback(for account: CodexAccount, localCapturedAt: Date?) -> Bool {
        guard account.enabled,
              let bound = account.boundLocalAccountID,
              !bound.isEmpty,
              bound == currentLocalAccountID,
              let localCapturedAt else { return false }
        if let localIdentityChangedAt, localCapturedAt < localIdentityChangedAt { return false }
        return true
    }
    func refreshAll(interactive: Bool = false) {
        refreshLocalIdentity()
        guard monitoringEnabled else { return }
        for account in accounts where account.enabled { refresh(id: account.id, interactive: interactive) }
        schedule()
    }
    func refresh(id: UUID, interactive: Bool = false) {
        guard monitoringEnabled, accounts.contains(where: { $0.id == id && $0.enabled }), tasks[id] == nil, !queue.contains(where: { $0.0 == id }) else { return }
        queue.append((id, interactive)); pump()
    }
    func stop() { timer?.invalidate(); timer = nil; queue = []; for id in Array(tasks.keys) { cancel(id: id) } }
    private func cancel(id: UUID) {
        generations[id] = nil; tasks[id]?.cancel(); tasks[id] = nil; queue.removeAll { $0.0 == id }
        states[id]?.isRefreshing = false
    }
    private func pump() {
        while tasks.count < 3, !queue.isEmpty, monitoringEnabled {
            let (id, interactive) = queue.removeFirst()
            guard let account = accounts.first(where: { $0.id == id && $0.enabled }) else { continue }
            let generation = UUID(); generations[id] = generation
            var state = states[id] ?? .init(); state.isRefreshing = true; states[id] = state
            let vault = vault, client = client
            tasks[id] = Task { [weak self] in
                let result: Result<CodexAccountUsage, Error>
                do {
                    let token = try await Task.detached(priority: .utility) { try vault.read(account, interactive) }.value
                    try Task.checkCancellation()
                    result = .success(try await client.load(account: account, token: token))
                } catch { result = .failure(error) }
                guard let self, self.generations[id] == generation,
                      self.monitoringEnabled, self.accounts.contains(where: { $0.id == id && $0.revision == account.revision && $0.enabled }) else { return }
                self.tasks[id] = nil
                var next = self.states[id] ?? .init(); next.isRefreshing = false
                switch result {
                case .success(let usage): next.usage = usage; next.error = nil
                case .failure(let error):
                    // 不显示原始 HTTP body/URL/Token 或任意第三方错误字符串。
                    next.error = (error as? CodexAccountError)?.errorDescription ?? "网络请求失败；请检查连接后重试。"
                }
                self.states[id] = next; self.pump()
            }
        }
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(accounts), forKey: "codexAccounts.v1") }
    private func reconfigure() {
        stop()
        if monitoringEnabled && automaticStart { refreshAll() }
        else if !monitoringEnabled { states = [:] }
    }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard monitoringEnabled && automaticStart else { return }
        let seconds = interval.isFinite ? min(1800, max(60, interval)) : 300
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        timer.tolerance = min(30, seconds * 0.1); self.timer = timer
    }
    private func startLocalIdentityMonitoring() {
        refreshLocalIdentity(force: true)
        scheduleLocalIdentityPoll()
    }
    private func scheduleLocalIdentityPoll() {
        localIdentityPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLocalIdentity() }
        }
        timer.tolerance = 1
        localIdentityPollTimer = timer
    }
    private func refreshLocalIdentity(force: Bool = false) {
        let values = try? localAuthURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        let modificationDate = values?.contentModificationDate
        if !force, modificationDate == lastLocalAuthModificationDate { return }
        lastLocalAuthModificationDate = modificationDate
        let next = values?.isRegularFile == true ? CodexLocalAccountIdentity.readAccountID(from: localAuthURL) : nil
        if next != currentLocalAccountID {
            currentLocalAccountID = next
            localIdentityChangedAt = Date()
        }
        installLocalIdentityWatcher()
    }
    private func installLocalIdentityWatcher() {
        localIdentityWatcher?.cancel()
        localIdentityWatcher = CodexFileWatcher(path: localAuthURL.path) { [weak self] in
            Task { @MainActor in self?.refreshLocalIdentity(force: true) }
        }
    }
}
