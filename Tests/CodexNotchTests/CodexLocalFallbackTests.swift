import Foundation
import Testing
@testable import CodexNotch

@Test func localCodexIdentityReadsOnlyValidAccountIDShape() throws {
    let valid = Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"acct_local-1","access_token":"ignored"}}"#.utf8)
    #expect(CodexLocalAccountIdentity.accountID(from: valid) == "acct_local-1")

    let invalid = Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"bad id with spaces"}}"#.utf8)
    #expect(CodexLocalAccountIdentity.accountID(from: invalid) == nil)
}

@Test func codexAccountBindingFieldRemainsBackwardCompatibleWhenAbsent() throws {
    let account = CodexAccount(label: "测试账号")
    let encoded = try JSONEncoder().encode(account)
    let decoded = try JSONDecoder().decode(CodexAccount.self, from: encoded)

    #expect(decoded.label == "测试账号")
    #expect(decoded.boundLocalAccountID == nil)
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
