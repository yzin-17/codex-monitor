import Foundation
import Testing
@testable import CodexNotch

private final class CodexRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var accountIDs: [String] = []
    var delay: Duration?

    func record(_ request: URLRequest) async throws -> Data {
        if let delay { try await Task.sleep(for: delay) }
        let accountID = request.value(forHTTPHeaderField: "ChatGPT-Account-Id") ?? ""
        lock.withLock { accountIDs.append(accountID) }
        return Data("""
        {"account_id":"\(accountID)","plan_type":"pro","credits":{"balance":12.5},
         "rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000},
         "secondary_window":{"used_percent":20,"limit_window_seconds":604800}}}
        """.utf8)
    }

    func reset() { lock.withLock { accountIDs = [] } }
    func values() -> [String] { lock.withLock { accountIDs } }
}

@MainActor
private func makeLocalFirstStore(
    accountIDs: [String],
    boundAccountIDs: Set<String> = [],
    currentAccountID: String = "acct-a",
    delay: Duration? = nil
) throws -> (CodexAccountsStore, CodexRequestRecorder, UserDefaults, String, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFirst-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let authURL = root.appendingPathComponent("auth.json")
    try Data("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"account_id\":\"\(currentAccountID)\"}}".utf8)
        .write(to: authURL)
    let suite = "CodexLocalFirst.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(true, forKey: "codexAccounts.enabled")
    let accounts = accountIDs.map {
        CodexAccount(
            label: $0,
            workspaceID: $0,
            boundLocalAccountID: boundAccountIDs.contains($0) ? $0 : nil
        )
    }
    defaults.set(try JSONEncoder().encode(accounts), forKey: "codexAccounts.v1")
    let recorder = CodexRequestRecorder()
    recorder.delay = delay
    let vault = CodexAccountVault(
        read: { _, _ in "synthetic-token" },
        write: { _, _ in },
        delete: { _ in }
    )
    let store = CodexAccountsStore(
        defaults: defaults,
        vault: vault,
        client: .init(fetch: recorder.record),
        automaticStart: false,
        localAuthURL: authURL
    )
    store.refreshAll()
    return (store, recorder, defaults, suite, root)
}

private func localQuotaSnapshot(
    weeklyRemaining: Int?,
    capturedAt: Date?,
    origin: LocalRateLimitOrigin = .appServer
) -> UsageSnapshot {
    var snapshot = UsageSnapshot.empty
    snapshot.secondaryPercent = weeklyRemaining
    snapshot.secondaryResetsAt = capturedAt?.addingTimeInterval(604_800)
    snapshot.rateLimitCapturedAt = capturedAt
    snapshot.rateLimitOrigin = capturedAt == nil ? nil : origin
    snapshot.lastUpdated = capturedAt?.addingTimeInterval(30) ?? Date()
    return snapshot
}

private func waitForRequests(_ recorder: CodexRequestRecorder, count: Int) async {
    for _ in 0..<150 {
        if recorder.values().count >= count { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

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

@Test func matchingLocalWeeklyQuotaTakesPriorityOverFreshRemote() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var remote = CodexAccountUsage(capturedAt: now)
    remote.quotas = [
        .init(id: "secondary_window", label: "7d", usedPercent: 20, resetsAt: now.addingTimeInterval(86_400), durationSeconds: 604_800)
    ]

    #expect(CodexAccountQuotaFallbackPolicy.shouldUseLocal(
        remoteUsage: remote,
        remoteError: nil,
        monitoringEnabled: true,
        interval: 300,
        bindingMatches: true,
        localHasWeekly: true,
        now: now
    ))
}

@Test @MainActor func validLocalQuotaSuppressesOnlyTheCurrentAccount() async throws {
    let (store, recorder, defaults, suite, root) = try makeLocalFirstStore(
        accountIDs: ["acct-a", "acct-b"],
        boundAccountIDs: ["acct-a"]
    )
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    await waitForRequests(recorder, count: 1)
    recorder.reset()
    let now = Date()
    store.updateLocalQuota(snapshot: localQuotaSnapshot(weeklyRemaining: 72, capturedAt: now), idleRefreshInterval: 60, now: now)
    store.refreshAll()
    await waitForRequests(recorder, count: 1)
    #expect(recorder.values() == ["acct-b"])
    #expect(store.localQuotaAvailability == .available)
}

@Test @MainActor func singleCurrentAccountWithValidLocalQuotaMakesNoAutomaticRequest() async throws {
    let (store, recorder, defaults, suite, root) = try makeLocalFirstStore(
        accountIDs: ["acct-a"],
        boundAccountIDs: ["acct-a"]
    )
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    recorder.reset()
    let now = Date()
    store.updateLocalQuota(snapshot: localQuotaSnapshot(weeklyRemaining: 72, capturedAt: now), idleRefreshInterval: 60, now: now)
    store.refreshAll()
    try await Task.sleep(for: .milliseconds(80))
    #expect(recorder.values().isEmpty)
}

@Test @MainActor func localValidityUsesTwiceIdleIntervalAndAllowsMissingFiveHourQuota() throws {
    let (store, _, defaults, suite, root) = try makeLocalFirstStore(
        accountIDs: ["acct-a"],
        boundAccountIDs: ["acct-a"]
    )
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let now = Date()
    store.updateLocalQuota(
        snapshot: localQuotaSnapshot(weeklyRemaining: 72, capturedAt: now.addingTimeInterval(-200)),
        idleRefreshInterval: 120,
        now: now
    )
    #expect(store.localQuotaAvailability == .available)
    let account = try #require(store.accounts.first)
    let display = store.displayData(for: account, now: now)
    #expect(display.usesLocalQuota)
    #expect(display.quotaUsage?.quotas.contains(where: CodexAccountQuotaFallbackPolicy.isFiveHourQuota) == false)
}

@Test @MainActor func unboundAccountContinuesAutomaticRemoteRefresh() async throws {
    let (store, recorder, defaults, suite, root) = try makeLocalFirstStore(accountIDs: ["acct-a"])
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    await waitForRequests(recorder, count: 1)
    recorder.reset()
    let now = Date()
    store.updateLocalQuota(snapshot: localQuotaSnapshot(weeklyRemaining: 72, capturedAt: now), idleRefreshInterval: 60, now: now)
    store.refreshAll()
    await waitForRequests(recorder, count: 1)
    #expect(recorder.values() == ["acct-a"])
}

@Test @MainActor func unavailableTransitionFallsBackOnceAndRepeatedUnavailableDoesNotBurst() async throws {
    let (store, recorder, defaults, suite, root) = try makeLocalFirstStore(
        accountIDs: ["acct-a"],
        boundAccountIDs: ["acct-a"]
    )
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    recorder.reset()
    let now = Date()
    store.updateLocalQuota(snapshot: localQuotaSnapshot(weeklyRemaining: 72, capturedAt: now), idleRefreshInterval: 60, now: now)
    let expired = localQuotaSnapshot(weeklyRemaining: 72, capturedAt: now.addingTimeInterval(-121))
    store.updateLocalQuota(snapshot: expired, idleRefreshInterval: 60, now: now)
    await waitForRequests(recorder, count: 1)
    #expect(recorder.values() == ["acct-a"])
    store.updateLocalQuota(snapshot: expired, idleRefreshInterval: 60, now: now.addingTimeInterval(1))
    try await Task.sleep(for: .milliseconds(80))
    #expect(recorder.values() == ["acct-a"])
    #expect(store.localQuotaAvailability == .unavailable)
}

@Test @MainActor func firstMissingLocalQuotaTriggersOneImmediateFallback() async throws {
    let (store, recorder, defaults, suite, root) = try makeLocalFirstStore(
        accountIDs: ["acct-a"],
        boundAccountIDs: ["acct-a"]
    )
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    recorder.reset()
    store.updateLocalQuota(snapshot: localQuotaSnapshot(weeklyRemaining: nil, capturedAt: nil), idleRefreshInterval: 60)
    await waitForRequests(recorder, count: 1)
    #expect(recorder.values() == ["acct-a"])
    store.updateLocalQuota(snapshot: localQuotaSnapshot(weeklyRemaining: nil, capturedAt: nil), idleRefreshInterval: 60)
    try await Task.sleep(for: .milliseconds(80))
    #expect(recorder.values() == ["acct-a"])
}

@Test @MainActor func manualRefreshBypassesLocalSuppressionAndKeepsRequestDeduplication() async throws {
    let (store, recorder, defaults, suite, root) = try makeLocalFirstStore(
        accountIDs: ["acct-a"],
        boundAccountIDs: ["acct-a"],
        delay: .milliseconds(80)
    )
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    try await Task.sleep(for: .milliseconds(100))
    recorder.reset()
    let now = Date()
    store.updateLocalQuota(snapshot: localQuotaSnapshot(weeklyRemaining: 72, capturedAt: now), idleRefreshInterval: 60, now: now)
    store.refreshAll(interactive: true)
    store.refreshAll(interactive: true)
    await waitForRequests(recorder, count: 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(recorder.values() == ["acct-a"])
}

@Test @MainActor func currentAccountDisplayKeepsLocalQuotaWithRemoteOnlyFields() async throws {
    let (store, recorder, defaults, suite, root) = try makeLocalFirstStore(
        accountIDs: ["acct-a"],
        boundAccountIDs: ["acct-a"]
    )
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    try await Task.sleep(for: .milliseconds(80))
    #expect(recorder.values() == [])
    store.refreshAll(interactive: true)
    await waitForRequests(recorder, count: 1)
    let remoteCapturedAt = try #require(store.states.values.first?.usage?.capturedAt)
    let now = remoteCapturedAt.addingTimeInterval(1)
    store.updateLocalQuota(snapshot: localQuotaSnapshot(weeklyRemaining: 61, capturedAt: now), idleRefreshInterval: 60, now: now)
    let account = try #require(store.accounts.first)
    let localDisplay = store.displayData(for: account, now: now)
    #expect(localDisplay.usesLocalQuota)
    #expect(localDisplay.quotaUsage?.quotas.first(where: CodexAccountQuotaFallbackPolicy.isWeeklyQuota)?.remainingPercent == 61)
    #expect(localDisplay.remotePlan == "pro")
    #expect(localDisplay.remoteCredits == "12.50 credits")
    #expect(localDisplay.remoteCapturedAt == remoteCapturedAt)

    store.updateLocalQuota(
        snapshot: localQuotaSnapshot(weeklyRemaining: 61, capturedAt: now.addingTimeInterval(-121)),
        idleRefreshInterval: 60,
        now: now
    )
    let remoteDisplay = store.displayData(for: account, now: now)
    #expect(remoteDisplay.quotaSource == .remoteFallback)
    #expect(remoteDisplay.quotaUsage?.quotas.first(where: CodexAccountQuotaFallbackPolicy.isWeeklyQuota)?.remainingPercent == 80)
}

@Test @MainActor func localOnlyNeverAutomaticallyRequestsCurrentAccountOrDisplaysRemoteQuota() async throws {
    let (store, recorder, defaults, suite, root) = try makeLocalFirstStore(
        accountIDs: ["acct-a"],
        boundAccountIDs: ["acct-a"]
    )
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    recorder.reset()
    store.updateLocalQuota(
        snapshot: localQuotaSnapshot(weeklyRemaining: nil, capturedAt: nil),
        idleRefreshInterval: 60,
        sourcePreference: .localOnly
    )
    store.refreshAll()
    try await Task.sleep(for: .milliseconds(80))
    #expect(recorder.values().isEmpty)

    store.refreshAll(interactive: true)
    await waitForRequests(recorder, count: 1)
    let account = try #require(store.accounts.first)
    let display = store.displayData(for: account)
    #expect(display.quotaUsage == nil)
    #expect(display.quotaSource == nil)
    #expect(display.remotePlan == "pro")
    #expect(display.remoteCredits == "12.50 credits")
}

@Test @MainActor func remoteOnlyIgnoresFreshLocalQuotaAndAutomaticallyRequestsCurrentAccount() async throws {
    let (store, recorder, defaults, suite, root) = try makeLocalFirstStore(
        accountIDs: ["acct-a"],
        boundAccountIDs: ["acct-a"]
    )
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    recorder.reset()
    let now = Date()
    store.updateLocalQuota(
        snapshot: localQuotaSnapshot(weeklyRemaining: 61, capturedAt: now),
        idleRefreshInterval: 60,
        sourcePreference: .remoteOnly,
        now: now
    )
    await waitForRequests(recorder, count: 1)
    let account = try #require(store.accounts.first)
    let display = store.displayData(for: account, now: now)
    #expect(display.quotaSource == .remote)
    #expect(display.quotaUsage?.quotas.first(where: CodexAccountQuotaFallbackPolicy.isWeeklyQuota)?.remainingPercent == 80)
}

@Test @MainActor func actualLocalChannelIsPreservedInDisplayData() throws {
    let (store, _, defaults, suite, root) = try makeLocalFirstStore(
        accountIDs: ["acct-a"],
        boundAccountIDs: ["acct-a"]
    )
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let now = Date()
    store.updateLocalQuota(
        snapshot: localQuotaSnapshot(weeklyRemaining: 63, capturedAt: now, origin: .localRecords),
        idleRefreshInterval: 60,
        sourcePreference: .localFirst,
        now: now
    )
    let account = try #require(store.accounts.first)
    #expect(store.displayData(for: account, now: now).quotaSource == .localRecords)
}

@Test @MainActor func remoteOnlyDoesNotGuessAnUnboundCurrentAccount() async throws {
    let (store, recorder, defaults, suite, root) = try makeLocalFirstStore(accountIDs: ["acct-a"])
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    await waitForRequests(recorder, count: 1)
    let now = Date()
    store.updateLocalQuota(
        snapshot: localQuotaSnapshot(weeklyRemaining: 64, capturedAt: now),
        idleRefreshInterval: 60,
        sourcePreference: .remoteOnly,
        now: now
    )
    #expect(store.currentLocalAccountDisplayData(now: now) == nil)
}

@Test @MainActor func remoteOnlyDoesNotEnableMonitoringOrUseCachedLocalQuota() throws {
    let (store, recorder, defaults, suite, root) = try makeLocalFirstStore(
        accountIDs: ["acct-a"],
        boundAccountIDs: ["acct-a"]
    )
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    recorder.reset()
    store.monitoringEnabled = false
    let now = Date()
    store.updateLocalQuota(
        snapshot: localQuotaSnapshot(weeklyRemaining: 64, capturedAt: now),
        idleRefreshInterval: 60,
        sourcePreference: .remoteOnly,
        now: now
    )
    let account = try #require(store.accounts.first)
    let display = store.displayData(for: account, now: now)
    #expect(!store.monitoringEnabled)
    #expect(display.quotaUsage == nil)
    #expect(display.quotaSource == nil)
    #expect(recorder.values().isEmpty)
}

@Test @MainActor func identitySwitchImmediatelyRefreshesFormerCurrentAndWaitsForNewLocalQuota() async throws {
    let (store, recorder, defaults, suite, root) = try makeLocalFirstStore(
        accountIDs: ["acct-a", "acct-b"],
        boundAccountIDs: ["acct-a", "acct-b"]
    )
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    await waitForRequests(recorder, count: 1)
    recorder.reset()
    let now = Date()
    store.updateLocalQuota(snapshot: localQuotaSnapshot(weeklyRemaining: 70, capturedAt: now), idleRefreshInterval: 60, now: now)

    let authURL = root.appendingPathComponent("auth.json")
    try Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"acct-b"}}"#.utf8).write(to: authURL)
    try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(1)],
        ofItemAtPath: authURL.path
    )
    store.refreshAll()
    await waitForRequests(recorder, count: 1)
    #expect(store.currentLocalAccountID == "acct-b")
    #expect(store.localQuotaAvailability == .unknown)
    #expect(recorder.values() == ["acct-a"])

    let settledNow = now.addingTimeInterval(CodexAccountQuotaFallbackPolicy.localIdentitySettleDelay + 2)
    store.updateLocalQuota(
        snapshot: localQuotaSnapshot(weeklyRemaining: 66, capturedAt: settledNow),
        idleRefreshInterval: 60,
        now: settledNow
    )
    let accountB = try #require(store.accounts.first(where: { $0.workspaceID == "acct-b" }))
    #expect(store.displayData(for: accountB, now: settledNow).usesLocalQuota)
}

@Test func stabilizedQuotaKeepsTheOriginalCaptureTimeAndExternalJSONOmitsIt() throws {
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var previous = localQuotaSnapshot(weeklyRemaining: 73, capturedAt: capturedAt)
    previous.rateLimitOrigin = .localRecords
    previous.rateLimitWindows = [
        UsageQuotaWindow(
            id: "primary-7d",
            shortLabel: "7d",
            remainingPercent: 73,
            resetsAt: capturedAt.addingTimeInterval(604_800)
        )
    ]
    var next = UsageSnapshot.empty
    next.lastUpdated = capturedAt.addingTimeInterval(90)
    let stabilized = next.stabilizedRateLimits(against: previous)
    #expect(stabilized.rateLimitCapturedAt == capturedAt)
    #expect(stabilized.rateLimitOrigin == .localRecords)
    #expect(stabilized.lastUpdated == next.lastUpdated)

    let json = String(decoding: SnapshotOutputFormatter.jsonData(for: stabilized), as: UTF8.self)
    #expect(!json.contains("rateLimitCapturedAt"))
    #expect(!json.contains("rate_limit_captured_at"))
    #expect(!json.contains("rateLimitOrigin"))
    #expect(!json.contains("rate_limit_origin"))
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
