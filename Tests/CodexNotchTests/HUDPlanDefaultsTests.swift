import Foundation
import Testing
@testable import CodexNotch

@Test func hudSessionAndWeeklyVisibilityIsDrivenByAvailableDataNotPlanName() {
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
    #expect(data.resolvedMetric(raw: "primary", layout: .compact) == .primary)
    #expect(data.resolvedMetric(raw: "fiveHour", layout: .compact) == .fiveHour)
    #expect(data.resolvedMetric(raw: "weekly", layout: .compact) == .weekly)

    var rateLimits = RateLimitSnapshot(
        primaryPercent: 46,
        secondaryPercent: 79,
        primaryResetsAt: nil,
        secondaryResetsAt: nil,
        capturedAt: Date(),
        isPrimaryCodexLimit: true
    )
    rateLimits.planType = "pro"
    #expect(rateLimits.displayWindows().map(\.shortLabel) == ["7d"])
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

@Test func hudAlwaysShowsRemainingAndLegacyProviderLayoutsCannotResizeRuntimeHUD() {
    var configuration = HUDConfiguration()
    configuration.showRemaining = false
    configuration.updateActiveLayout(.init(lines: [["weekly", "icon"]]))
    configuration.providerLayouts["codex"] = .init(lines: [["weekly"]])

    let normalized = configuration.normalized
    #expect(normalized.showRemaining)
    #expect(normalized.layout(for: "codex") == normalized.activeLayout)
    #expect(normalized.layout(for: "codex").lines == [["weekly@@local", "icon"]])
}

@Test @MainActor func hudMeasuredWidthIncludesCompleteIconAndWeeklyValue() {
    var data = HUDEntityData()
    data.weekly = 79
    data.weeklyWindow = .init(remaining: 79, duration: 604_800, label: "7d")
    data.lanes = [data.weeklyWindow].compactMap { $0 }
    let withIcon = HUDMetricStrip.measuredWidth(
        layout: .init(lines: [["weekly", "icon"]]),
        data: data,
        remaining: true,
        menuBar: true
    )
    let withoutIcon = HUDMetricStrip.measuredWidth(
        layout: .init(lines: [["weekly"]]),
        data: data,
        remaining: true,
        menuBar: true
    )
    #expect(withIcon >= withoutIcon + 18)
}

@Test func recentActivitySanitizesInternalTranscriptTitles() {
    let raw = """
    The following is the Codex agent history whose request action you are assessing.
    >>> TRANSCRIPT START
    [1] user:
    private internal payload
    """
    let task = CodexTask(
        id: "internal-wrapper",
        title: raw,
        status: .recent,
        detailPrefix: "gpt-5.6-sol",
        tokenCount: 1,
        updatedAt: Date()
    )
    #expect(task.title == "未命名任务")

    let normal = CodexTask(
        id: "normal",
        title: "正常任务标题\n不应把后续正文展示到首页",
        status: .recent,
        detailPrefix: "gpt-5.6-sol",
        tokenCount: 1,
        updatedAt: Date()
    )
    #expect(normal.title == "正常任务标题")
}
