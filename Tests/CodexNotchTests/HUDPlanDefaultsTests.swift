import Testing
@testable import CodexNotch

@Test func hudPlanAwareDefaultQuotaVisibility() {
    var data = HUDEntityData()
    data.providerID = "codex"
    data.primary = 46
    data.weekly = 79
    data.primaryWindow = .init(remaining: 46, duration: 18_000, label: "5h")
    data.weeklyWindow = .init(remaining: 79, duration: 604_800, label: "7d")
    data.lanes = [data.primaryWindow, data.weeklyWindow].compactMap { $0 }

    data.planType = "plus"
    #expect(data.resolvedMetric(raw: "primary", layout: .compact) == .primary)
    #expect(data.resolvedMetric(raw: "weekly", layout: .compact) == .weekly)

    data.planType = "pro"
    #expect(data.resolvedMetric(raw: "primary", layout: .compact) == nil)
    #expect(data.resolvedMetric(raw: "fiveHour", layout: .compact) == nil)
    #expect(data.resolvedMetric(raw: "weekly", layout: .compact) == .weekly)
}

@Test func hudLocalWeeklyOnlySourceDoesNotRenderEmptyFiveHourQuota() {
    var data = HUDEntityData()
    data.providerID = "codex"
    data.weekly = 72
    data.weeklyWindow = .init(remaining: 72, duration: 604_800, label: "7d")
    data.lanes = [data.weeklyWindow].compactMap { $0 }

    #expect(data.resolvedMetric(raw: "primary", layout: .compact) == nil)
    #expect(data.resolvedMetric(raw: "weekly", layout: .compact) == .weekly)
}

@Test func hudLegacyOrdinalQuotaControlsStayCompatibleButAreNotSelectable() {
    #expect(!HUDMetric.palette.contains(.primaryLane))
    #expect(!HUDMetric.palette.contains(.secondaryLane))
    #expect(!HUDMetric.palette.contains(.tertiaryLane))
    #expect(HUDMetric.parse("primaryLane") == .primaryLane)
}

@Test func hudIconDoesNotCarryAccountBinding() {
    #expect(HUDLayoutToken.applying(sourceID: "codex-account:test", to: "icon") == "icon")
    #expect(HUDLayout(lines: [["icon@@codex-account:test"]]).normalized.lines == [["icon"]])
}