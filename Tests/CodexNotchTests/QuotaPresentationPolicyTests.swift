import Foundation
import Testing
@testable import CodexNotch

@Test func proCoreQuotaPolicyStillHidesFiveHourWindow() {
    #expect(!CodexPlanKind(planType: "pro").showsFiveHourQuota)
    #expect(CodexPlanKind(planType: "plus").showsFiveHourQuota)
}

@Test func hudLayoutVisibilityDependsOnActualFiveHourDataRatherThanPlan() {
    var data = HUDEntityData()
    data.planType = "pro"
    data.primary = 62
    data.primaryWindow = .init(remaining: 62, duration: 18_000, label: "5h")
    data.weekly = 81
    data.weeklyWindow = .init(remaining: 81, duration: 604_800, label: "7d")
    data.lanes = [data.primaryWindow, data.weeklyWindow].compactMap { $0 }

    #expect(data.resolvedMetric(raw: "primary", layout: .compact) == .primary)
    #expect(data.resolvedMetric(raw: "weekly", layout: .compact) == .weekly)

    data.primary = nil
    data.primaryWindow = nil
    data.lanes = [data.weeklyWindow].compactMap { $0 }
    #expect(data.resolvedMetric(raw: "primary", layout: .compact) == nil)
    #expect(data.resolvedMetric(raw: "weekly", layout: .compact) == .weekly)
}
