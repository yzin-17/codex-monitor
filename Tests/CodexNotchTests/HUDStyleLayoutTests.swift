import Foundation
import Testing
@testable import CodexNotch

@Test func runtimeStateIsNotACustomizableComponent() {
    #expect(!HUDMetric.palette.contains(.state))
    #expect(HUDLayout(lines: [["state", "primary"], ["state", "weekly"]]).normalized.lines == [["primary"], ["weekly"]])
    #expect(HUDLayout.compact.inserting(.state, row: 0) == .compact)
    #expect(HUDLayout(lines: [["state"]]).normalized.lines == [[]])
}
@Test func repeatedSpacesPersistAndMoveIndependently() throws {
    let layout = HUDLayout(lines: [["primary", "space:8", "weekly", "space:16"], ["tokensToday"]])
    #expect(try JSONDecoder().decode(HUDLayout.self, from: JSONEncoder().encode(layout)) == layout)
    let moved = layout.moving(from: .init(row: 0, index: 1), toRow: 1, before: 0)
    #expect(moved.lines == [["primary", "weekly", "space:16"], ["space:8", "tokensToday"]])
    #expect(moved.removing(at: .init(row: 0, index: 2)).lines[1][0] == "space:8")
    #expect(moved.settingSpace(24, at: .init(row: 1, index: 0)).lines[1][0] == "space:24")
}
@Test func spacesAndSeparatorsCanBeAddedMoreThanOnce() {
    let layout = HUDLayout.compact.inserting(.space, row: 0).inserting(.space, row: 0)
        .inserting(.separatorDot, row: 1).inserting(.separatorDot, row: 1)
    #expect(layout.metrics[0].filter { $0 == .space }.count == 2)
    #expect(layout.metrics[1] == [.separatorDot, .separatorDot])
}
@Test func spacerSizesAndMoveTargetsAreBounded() {
    #expect(HUDLayout.spaceWidth("space:-1") == 2)
    #expect(HUDLayout.spaceWidth("space:10000000") == 48)
    #expect(HUDLayout.spaceWidth("space:invalid") == 8)
    let layout = HUDLayout.compact
    #expect(layout.moving(from: .init(row: 9, index: 8), toRow: 0) == layout)
    #expect(layout.removing(at: .init(row: 0, index: 99)) == layout)
    #expect(HUDLayout(lines: [Array(repeating: "space:8", count: 40)]).normalized.lines[0].count == 12)
}
@Test func rightSideCanBeEmptyWithoutRestoringUnwantedMetrics() {
    let empty = HUDLayout(lines: [["primary"]]).removing(at: .init(row: 0, index: 0))
    #expect(empty.lines == [[]])
    #expect(empty.normalized == empty)
    #expect(empty.inserting(.space, row: 0).lines == [["space:8"]])
}
@Test func oldLayoutJSONMigratesWithoutLosingSourceIndependentItems() throws {
    let old = Data(#"{"lines":[["state","primary","weekly"],["tokensToday","resetCountdown"]]}"#.utf8)
    let loaded = try JSONDecoder().decode(HUDLayout.self, from: old).normalized
    #expect(loaded == .detailed)
    #expect(loaded.conditionals.isEmpty)
}
@Test func quotaLabelsValuesAndPaletteStaySemantic() {
    var d = HUDEntityData(primary: 46, weekly: 79, todayTokens: "473.7M")
    #expect(d.display(.primary, remaining: true) == .init(label: "5h", value: "46%", tone: .healthy))
    #expect(d.display(.weekly, remaining: true).tone == .healthy)
    #expect(d.display(.tokensToday, remaining: true).tone == .primary)
    #expect(d.display(.primary, remaining: false).tone == .healthy)
    d.primary = 15
    #expect(d.display(.primary, remaining: true).tone == .critical)
    d.primary = 30
    #expect(d.display(.primary, remaining: true).tone == .warning)
    d.primary = .nan
    #expect(d.display(.primary, remaining: true).value == "—")
    #expect(d.display(.primary, remaining: true).tone == .tertiary)
}
private func pacedSample(now: Date) -> HUDEntityData {
    HUDEntityData(primary: 25, weekly: 80,
        primaryWindow: .init(remaining: 25, resetsAt: now.addingTimeInterval(9000), duration: 18000, label: "5h"),
        weeklyWindow: .init(remaining: 80, resetsAt: now.addingTimeInterval(302400), duration: 604800, label: "7d"), capturedAt: now)
}
@Test func paceAndRunOutRequireRealWindowEvidence() {
    let now = Date(timeIntervalSince1970: 1800000000), d = pacedSample(now: Date(timeIntervalSince1970: 1800000000))
    #expect(d.numeric(.primaryPace, now: now) == 25)
    #expect(d.numeric(.weeklyPace, now: now) == -30)
    #expect(abs((d.numeric(.runsOut, now: now) ?? 0) - 5.0 / 6.0) < 0.0001)
    #expect(HUDEntityData(primary: 25).numeric(.runsOut, now: now) == nil)
    #expect(d.numeric(.primaryPace, now: now.addingTimeInterval(601)) == nil)
    var failed = d; failed.warning = "刷新失败"
    #expect(failed.numeric(.primaryPace, now: now) == nil)
    var justReset = d; justReset.primaryWindow?.resetsAt = now.addingTimeInterval(17999)
    #expect(justReset.numeric(.primaryPace, now: now) == nil)
}
@Test func windowControlsDoNotMixAutomaticWithWeeklyReset() {
    let now = Date(timeIntervalSince1970: 1800000000), d = pacedSample(now: Date(timeIntervalSince1970: 1800000000))
    #expect(d.numeric(.resetCountdown, now: now) == 2.5)
    #expect(d.numeric(.weeklyCountdown, now: now) == 84)
    #expect(d.numeric(.scopedCountdown, now: now) == nil)
    #expect(d.text(.scopedWeekly, remaining: true) == "范围 —")
    #expect(d.text(.tertiaryLane, remaining: true) == "第三 —")
}
@Test func conditionalControlsRoundTripAndResolveWithoutDoubleBilling() throws {
    let now = Date(timeIntervalSince1970: 1800000000), d = pacedSample(now: Date(timeIntervalSince1970: 1800000000))
    var rule = HUDConditional(); rule.predicates[0].threshold = 70; rule.thenMetric = .primaryCountdown
    let layout = HUDLayout.compact.addingConditional(rule)
    let raw = try #require(layout.lines[0].last)
    #expect(d.resolvedMetric(raw: raw, layout: layout, now: now) == .primaryCountdown)
    #expect(try JSONDecoder().decode(HUDLayout.self, from: JSONEncoder().encode(layout)) == layout)
    let removed = layout.removing(at: .init(row: 0, index: 2))
    #expect(removed.conditionals.isEmpty)
    #expect(d.resolvedMetric(raw: raw, layout: layout, now: now.addingTimeInterval(601)) == nil)
}
@Test func conditionalUnknownIsNotMistakenForFalseOrZero() throws {
    let layout = HUDLayout.compact.addingConditional(.init())
    let raw = try #require(layout.lines[0].last)
    #expect(HUDEntityData().resolvedMetric(raw: raw, layout: layout) == nil)
    #expect(HUDEntityData(primary: 90).resolvedMetric(raw: raw, layout: layout) == .hidden)
    #expect(HUDEntityData(primary: 10).resolvedMetric(raw: raw, layout: layout) == .primary)
}
@Test func conditionalBranchesCannotRecurseOrOverrideRuntimeState() {
    var rule = HUDConditional(); rule.thenMetric = .conditional; rule.elseMetric = .state
    #expect(rule.normalized.thenMetric == .primary && rule.normalized.elseMetric == .hidden)
    #expect(HUDLayout(lines: [["conditional:missing", "primary"]]).normalized.lines == [["primary"]])
}
@Test func conditionalAndOrAndRemainingDirectionWork() throws {
    let d = HUDEntityData(primary: 25, weekly: 80)
    var rule = HUDConditional(); rule.predicates = [HUDPredicate(metric: .primary, remaining: true, comparison: .less, threshold: 30), .init(metric: .weekly, remaining: true, comparison: .less, threshold: 30)]
    var layout = HUDLayout.compact.addingConditional(rule); var raw = try #require(layout.lines[0].last)
    #expect(d.resolvedMetric(raw: raw, layout: layout) == .hidden)
    rule.matchAll = false; layout = HUDLayout.compact.addingConditional(rule); raw = try #require(layout.lines[0].last)
    #expect(d.resolvedMetric(raw: raw, layout: layout) == .primary)
}
@Test func malformedLayoutCannotInjectMetricArguments() {
    let layout = HUDLayout(lines: [["weekly:fake", "space:-4", "state", "icon"]]).normalized
    #expect(layout.lines == [["space:2", "icon"]])
    #expect(HUDLayout(lines: [["nothing"]]).normalized == .compact)
}
@Test func originalQuotaAndCostFormattingStayIndependent() {
    let d = HUDEntityData(primary: 46, weekly: 79, costToday: "≈1.20 USD", cost30d: "≥12.00 USD")
    #expect(d.text(.costToday, remaining: true) == "今日 ≈1.20 USD")
    #expect(d.text(.cost30d, remaining: true) == "30天 ≥12.00 USD")
    #expect(d.text(.usageBar, remaining: false) == "54%")
    #expect(d.text(.usageBar, remaining: true) == "46%")
}
