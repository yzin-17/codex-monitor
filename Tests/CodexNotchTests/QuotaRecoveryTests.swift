import Foundation
import Testing
@testable import CodexNotch

private final class RecoveryVault: @unchecked Sendable {
    let lock = NSLock()
    private var token = "synthetic-old"
    private var failing = false
    func read() -> String { lock.withLock { token } }
    func write(_ value: String) { lock.withLock { token = value } }
    func fail() { lock.withLock { failing = true } }
    func fetch(_ request: URLRequest) throws -> Data {
        if lock.withLock({ failing }) { throw CodexAccountError.http(401) }
        return Data(#"{"account_id":"acct-a","rate_limit":{"secondary_window":{"used_percent":20,"limit_window_seconds":604800}}}"#.utf8)
    }
}

@Test @MainActor func quotaReauthenticationUpdatesOriginalAccountOnlyAfterVerification() async throws {
    let suite = "QuotaRecovery.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let vault = RecoveryVault()
    let store = CodexAccountsStore(defaults: defaults,
        vault: .init(read: { _, _ in vault.read() }, write: { _, token in vault.write(token) }, delete: { _ in }),
        client: .init(fetch: vault.fetch), automaticStart: false,
        localAuthURL: URL(fileURLWithPath: "/nonexistent/synthetic-auth"))
    try await store.verifyAndSave(.init(label: "测试", workspaceID: "acct-a"), token: "synthetic-old")
    let original = try #require(store.accounts.first)
    do {
        try await store.reauthenticate(original, credential: .init(accessToken: "synthetic-wrong", workspaceID: "acct-b"))
        Issue.record("不同账号不得覆盖原凭据")
    } catch CodexAccountError.accountMismatch {}
    #expect(vault.read() == "synthetic-old")
    try await store.reauthenticate(original, credential: .init(accessToken: "synthetic-new", workspaceID: "acct-a"))
    #expect(store.accounts.count == 1)
    #expect(store.accounts.first?.id == original.id)
    #expect(vault.read() == "synthetic-new")
    let updated = try #require(store.accounts.first)
    let usage = store.states[original.id]?.usage
    vault.fail()
    do {
        try await store.reauthenticate(updated, credential: .init(accessToken: "synthetic-invalid", workspaceID: "acct-a"))
        Issue.record("认证失败必须保留旧凭据")
    } catch CodexAccountError.http(401) {}
    #expect(vault.read() == "synthetic-new")
    #expect(store.states[original.id]?.usage == usage)
    #expect(store.accounts.first?.revision == updated.revision)
}

@Test func quotaRuntimeFailureAndIdentityRecoveryHaveDistinctDiagnostics() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaRecovery-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let auth = root.appendingPathComponent("auth.json")
    try #"{"tokens":{"account_id":"acct-a"}}"#.write(to: auth, atomically: true, encoding: .utf8)
    let store = CodexUsageStore(codexDirectory: root, ripgrepCandidates: [], appServerExecutable: "/nonexistent/codex")
    let snapshot = store.loadSnapshot(includePeriodUsage: false, bypassFastCache: true)
    #expect(snapshot.rateLimitDiagnostic?.failure == .runtimeMissing)
    #expect(snapshot.quotaWarning() == "未找到 Codex 运行时")
    try "{".write(to: auth, atomically: true, encoding: .utf8)
    let unreadable = store.loadSnapshot(includePeriodUsage: false, bypassFastCache: true)
    #expect(unreadable.rateLimitDiagnostic?.failure == .identityUnavailable)
    #expect(unreadable.secondaryPercent == nil)
}
