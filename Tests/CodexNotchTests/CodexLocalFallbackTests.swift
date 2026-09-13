import Foundation
import Testing
@testable import CodexNotch

@Test func localCodexIdentityReadsOnlyValidAccountIDShape() throws {
    let valid = Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"acct_local-1","access_token":"ignored"}}"#.utf8)
    #expect(CodexLocalAccountIdentity.accountID(from: valid) == "acct_local-1")

    let invalid = Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"bad id with spaces"}}"#.utf8)
    #expect(CodexLocalAccountIdentity.accountID(from: invalid) == nil)

    let wrongMode = Data(#"{"auth_mode":"apikey","tokens":{"account_id":"acct_local-1"}}"#.utf8)
    #expect(CodexLocalAccountIdentity.accountID(from: wrongMode) == nil)
}

@Test func codexAccountBindingFieldRemainsBackwardCompatibleWhenAbsent() throws {
    let account = CodexAccount(label: "测试账号")
    let encoded = try JSONEncoder().encode(account)
    let decoded = try JSONDecoder().decode(CodexAccount.self, from: encoded)

    #expect(decoded.label == "测试账号")
    #expect(decoded.boundLocalAccountID == nil)
}

@Test @MainActor func explicitLocalBindingRequiresTheSameVerifiedAccountID() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let authURL = root.appendingPathComponent("auth.json")
    try Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"acct-a","access_token":"ignored"}}"#.utf8).write(to: authURL)

    let suite = "CodexLocalFallbackTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let vault = CodexAccountVault(
        read: { _, _ in "synthetic-token" },
        write: { _, _ in },
        delete: { _ in }
    )
    let client = CodexAccountHTTPClient(fetch: { request in
        let accountID = request.value(forHTTPHeaderField: "ChatGPT-Account-Id") ?? "acct-a"
        return Data("{\"account_id\":\"\(accountID)\",\"rate_limit\":{\"secondary_window\":{\"used_percent\":20,\"limit_window_seconds\":604800}}}".utf8)
    })
    let store = CodexAccountsStore(
        defaults: defaults,
        vault: vault,
        client: client,
        automaticStart: false,
        localAuthURL: authURL
    )

    try await store.verifyAndSave(.init(label: "远程 A", workspaceID: "acct-a"), token: "synthetic-token")
    let accountA = try #require(store.accounts.first(where: { $0.label == "远程 A" }))
    store.bindCurrentLocalAccount(to: accountA.id)
    #expect(store.accounts.first(where: { $0.id == accountA.id })?.boundLocalAccountID == "acct-a")

    try await store.verifyAndSave(.init(label: "远程 B", workspaceID: "acct-b"), token: "synthetic-token")
    let accountB = try #require(store.accounts.first(where: { $0.label == "远程 B" }))
    store.bindCurrentLocalAccount(to: accountB.id)
    #expect(store.accounts.first(where: { $0.id == accountB.id })?.boundLocalAccountID == nil)
    #expect(store.lastError?.contains("不是同一账号") == true)
}

@Test func freshRemoteWeeklyQuotaDoesNotFallbackToLocal() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var remote = CodexAccountUsage(capturedAt: now)
    remote.quotas = [
        .init(id: "secondary_window", label: "7d", usedPercent: 20, resetsAt: now.addingTimeInterval(86_400), durationSeconds: 604_800)
    ]

    #expect(!CodexAccountQuotaFallbackPolicy.shouldUseLocal(
        remoteUsage: remote,
        remoteError: nil,
        monitoringEnabled: true,
        interval: 300,
        bindingMatches: true,
        localHasWeekly: true,
        now: now
    ))
}

@Test func remoteFailureOrMissingWeeklyUsesMatchedLocalQuota() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var remoteWithoutWeekly = CodexAccountUsage(capturedAt: now)
    remoteWithoutWeekly.quotas = [
        .init(id: "primary_window", label: "5h", usedPercent: 10, resetsAt: now.addingTimeInterval(3_600), durationSeconds: 18_000)
    ]

    #expect(CodexAccountQuotaFallbackPolicy.shouldUseLocal(
        remoteUsage: remoteWithoutWeekly,
        remoteError: nil,
        monitoringEnabled: true,
        interval: 300,
        bindingMatches: true,
        localHasWeekly: true,
        now: now
    ))

    #expect(CodexAccountQuotaFallbackPolicy.shouldUseLocal(
        remoteUsage: remoteWithoutWeekly,
        remoteError: "网络失败",
        monitoringEnabled: true,
        interval: 300,
        bindingMatches: true,
        localHasWeekly: true,
        now: now
    ))
}

@Test func localFallbackRequiresExplicitMatchingBindingAndWeeklyData() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    #expect(!CodexAccountQuotaFallbackPolicy.shouldUseLocal(
        remoteUsage: nil,
        remoteError: "网络失败",
        monitoringEnabled: true,
        interval: 300,
        bindingMatches: false,
        localHasWeekly: true,
        now: now
    ))

    #expect(!CodexAccountQuotaFallbackPolicy.shouldUseLocal(
        remoteUsage: nil,
        remoteError: "网络失败",
        monitoringEnabled: true,
        interval: 300,
        bindingMatches: true,
        localHasWeekly: false,
        now: now
    ))
}

@Test func switchedLocalAccountWaitsForOldQuotaCachesToExpire() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let changedAt = now.addingTimeInterval(-30)
    #expect(!CodexAccountQuotaFallbackPolicy.localIdentityIsSettled(changedAt: changedAt, now: now))

    let settledAt = now.addingTimeInterval(-CodexAccountQuotaFallbackPolicy.localIdentitySettleDelay - 1)
    #expect(CodexAccountQuotaFallbackPolicy.localIdentityIsSettled(changedAt: settledAt, now: now))
}

@Test func singleRemotePrimaryWindowWithoutDurationDefaultsToWeekly() throws {
    let data = Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":20}}}"#.utf8)
    let usage = try CodexAccountUsageParser.parse(data)
    let primary = try #require(usage.quotas.first(where: { $0.id == "primary_window" }))
    #expect(primary.label == "7d")
    #expect(CodexAccountQuotaFallbackPolicy.isWeeklyQuota(primary))
    #expect(!CodexAccountQuotaFallbackPolicy.isFiveHourQuota(primary))
}

@Test func sevenDayPrimaryWindowIsNotMistakenForFiveHourQuota() {
    let weeklyOnly = AccountQuota(
        id: "primary_window",
        label: "7d",
        usedPercent: 20,
        resetsAt: nil,
        durationSeconds: 604_800
    )
    #expect(!CodexAccountQuotaFallbackPolicy.isFiveHourQuota(weeklyOnly))
    #expect(CodexAccountQuotaFallbackPolicy.isWeeklyQuota(weeklyOnly))
}

@Test func fallbackPresentationHidesOnlyMissingFiveHourQuota() {
    var data = HUDEntityData()
    data.primary = nil
    data.primaryWindow = nil
    data.weekly = nil
    data.weeklyWindow = nil

    #expect(data.resolvedMetric(raw: "fiveHour", layout: .compact) == nil)
    #expect(data.resolvedMetric(raw: "weekly", layout: .compact) == .weekly)
    #expect(data.display(.weekly, remaining: true).text == "7d —")
}
