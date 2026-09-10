import XCTest
@testable import CodexMonitorCore

final class MonitorPresentationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_789_034_400)
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }
    func session(_ id: String, tokens: Int64 = 100, status: String = "已完成", age: TimeInterval = 10, parent: String? = nil) -> Session {
        Session(id: id, parentID: parent, isSubagent: parent != nil,
                samples: [UsageSample(id: id, date: now.addingTimeInterval(-10), turnID: "t", model: "demo", tokens: Tokens(input: tokens))],
                status: status, lastActivity: now.addingTimeInterval(-age))
    }
    func testFreshRunningFirstRegardlessOfTokenRank() {
        let data = MonitorDashboard(sessions: [session("big", tokens: 10000), session("active", status: "日志显示运行中")], now: now, calendar: calendar)
        XCTAssertEqual(data.rows.first?.id, "active")
        XCTAssertEqual(data.runningTasks, 1)
    }
    func testStaleRunningNeverCountsAsLive() {
        let data = MonitorDashboard(sessions: [session("old", status: "日志显示运行中", age: 601)], now: now, calendar: calendar)
        XCTAssertEqual(data.rows.first?.activity, .stale)
        XCTAssertEqual(data.runningTasks, 0)
    }
    func testMissingTimestampAndFutureTimestampAreUnknown() {
        var noDate = session("none", status: "日志显示运行中"); noDate.lastActivity = nil
        XCTAssertEqual(MonitorActivity.resolve(noDate, now: now), .unknown)
        XCTAssertEqual(MonitorActivity.resolve(session("future", status: "日志显示运行中", age: -120), now: now), .unknown)
    }
    func testEmptyDataIsUnknownNotIdle() {
        let data = MonitorDashboard(sessions: [], now: now)
        XCTAssertEqual(data.activity, .unknown)
        XCTAssertEqual(data.runningTasks, 0)
    }
    func testChildActivityAndTodayReconcile() {
        let data = MonitorDashboard(sessions: [session("root"), session("child", tokens: 300, status: "日志显示运行中", parent: "root"), session("other", tokens: 600)], now: now, calendar: calendar)
        XCTAssertEqual(data.rows.first?.id, "root")
        XCTAssertEqual(data.rows.first?.today.total, 400)
        XCTAssertEqual(data.rows.first?.share, 0.4)
        XCTAssertEqual(data.runningAgents, 1)
        XCTAssertEqual(data.today.total, data.rows.reduce(0) { $0 + $1.today.total })
        XCTAssertEqual(data.rows.first?.task.total.total, 400)
    }
    func testZeroDenominatorHasNoInventedShare() {
        let data = MonitorDashboard(sessions: [session("empty", tokens: 0)], now: now)
        XCTAssertNil(data.rows.first?.share)
    }
    func testNaturalDayDoesNotCountYesterdayOrUnknownBaseline() {
        let boundary = calendar.startOfDay(for: now)
        var value = session("local")
        value.samples = [
            UsageSample(id: "a", date: boundary.addingTimeInterval(-1), turnID: "a", model: "demo", tokens: Tokens(input: 100)),
            UsageSample(id: "b", date: boundary, turnID: "b", model: "demo", tokens: Tokens(input: 200)),
            UsageSample(id: "c", date: nil, turnID: "c", model: "unknown", tokens: Tokens(input: 300), isBaseline: true)
        ]
        let data = MonitorDashboard(sessions: [value], now: now, calendar: calendar)
        XCTAssertEqual(data.today.total, 200)
        XCTAssertEqual(data.week.total, 300)
        XCTAssertEqual(data.rows.first?.task.total.total, 600)
    }
    func testQuotaDoesNotMixSparkIntoGeneralQuota() {
        let spark = QuotaWindow(id: "spark:primary", minutes: 300, usedPercent: 10, resetsAt: now.addingTimeInterval(100), observedAt: now)
        let normal = QuotaWindow(id: "codex:primary", minutes: 300, usedPercent: 54, resetsAt: now.addingTimeInterval(100), observedAt: now)
        XCTAssertEqual(MonitorQuota.generalWindow([spark, normal], minutes: 300)?.id, normal.id)
        XCTAssertNil(MonitorQuota.generalWindow([spark], minutes: 300))
        XCTAssertEqual(MonitorQuota.percentage(normal, now: now), "46%")
    }
    func testExpiredQuotaIsUnknownNotResetToFull() {
        let expired = QuotaWindow(id: "codex:primary", minutes: 300, usedPercent: 90, resetsAt: now.addingTimeInterval(-1), observedAt: now.addingTimeInterval(-200))
        XCTAssertEqual(MonitorQuota.percentage(expired, now: now), "—")
        XCTAssertEqual(expired.remainingPercent, 10)
    }
    func testMissingQuotaObservationIsNotTrusted() {
        let quota = QuotaWindow(id: "codex:primary", minutes: 300, usedPercent: 10, resetsAt: nil, observedAt: nil)
        XCTAssertEqual(MonitorQuota.percentage(quota, now: now), "—")
        XCTAssertEqual(MonitorQuota.percentage(nil, now: now), "—")
    }
}
