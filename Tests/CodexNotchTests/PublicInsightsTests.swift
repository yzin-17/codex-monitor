import Foundation
import Testing
@testable import CodexNotch

private func publicJSON(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
private let insightNow = Date(timeIntervalSince1970: 1_800_000_000)
private var insightISO: String { ISO8601DateFormatter().string(from: insightNow) }
@Test func publicSourcesHaveFixedHTTPSReadOnlyEndpointsAndNoMailTransport() {
    #expect(PublicInsightSource.allCases.count == 3)
    for source in PublicInsightSource.allCases {
        #expect(source.endpoint.scheme == "https")
        #expect(source.endpoint.user == nil && source.endpoint.password == nil)
        #expect(!source.endpoint.absoluteString.contains("subscribe"))
    }
    #expect(PublicInsightSource.willReset.website.absoluteString == "https://www.willcodexquotareset.com/")
}
@Test func officialStatusFiltersCodexComponentsWithoutInventingIndividualAvailability() throws {
    let data = try publicJSON(["status": ["indicator": "minor", "description": "Partial degradation"],
        "page": ["updated_at": "2020-01-01T00:00:00Z"], "components": [
            ["id":"codex", "name":"Codex API", "status":"operational"],
            ["id":"images", "name":"Images", "status":"major_outage"],
            ["id":"login", "name":"Login", "status":"degraded_performance"]]])
    let value = try PublicInsightParser.parse(data, source: .openAIStatus, fetchedAt: insightNow)
    #expect(value.components.count == 2)
    #expect(value.components[0].label == "正常")
    #expect(value.overallIndicator == "minor")
    #expect(!value.isStale(now: insightNow)) // 状态最后变更时间较早不等于本次读取失败。
    #expect(value.probabilities.isEmpty)
}
@Test func observatoryConvertsOnlyDocumentedFractionProbabilities() throws {
    let data = try publicJSON(["checkedAt": insightISO, "dataHealth": ["stale": false], "viewModel": [
        "probability12h": 0.2, "probability24h": 0.4, "probability48h": 0.7, "probability72h": 0.9]])
    let value = try PublicInsightParser.parse(data, source: .observatory, fetchedAt: insightNow)
    #expect(value.probabilities == [12:20, 24:40, 48:70, 72:90])
}
@Test func observatoryInvalidNumbersAndBooleansAreNotProbabilities() throws {
    let data = try publicJSON(["checkedAt": insightISO, "viewModel": ["probability12h":true, "probability24h": -0.2, "probability48h":70]])
    #expect(throws: Error.self) { try PublicInsightParser.parse(data, source: .observatory, fetchedAt: insightNow) }
}
@Test func forecastStalenessAndFailureDoNotBecomeZeroProbability() throws {
    let data = try publicJSON(["checkedAt": insightISO, "dataHealth": ["stale": true], "viewModel": ["probability48h":0.7]])
    let value = try PublicInsightParser.parse(data, source: .observatory, fetchedAt: insightNow)
    #expect(value.isStale(now: insightNow))
    #expect(value.probabilities[48] == 70)
    #expect(throws: Error.self) { try PublicInsightParser.parse(Data("{}".utf8), source: .observatory) }
}
@Test func willForecastIsIndependent48HourUncalibratedScore() throws {
    let data = try publicJSON(["fetchedAt": insightISO, "sourceErrors": [:], "forecast": ["horizonHours":48, "score":23, "calibrated":false]])
    let value = try PublicInsightParser.parse(data, source: .willReset, fetchedAt: insightNow)
    #expect(value.probabilities == [48:23])
    #expect(value.summary.contains("未校准"))
    #expect(!value.upstreamStale)
}
@Test func willForecastRejectsChangedHorizonAndMarksPartialFailure() throws {
    let bad = try publicJSON(["fetchedAt": insightISO, "forecast": ["horizonHours":24, "score":23]])
    #expect(throws: Error.self) { try PublicInsightParser.parse(bad, source: .willReset) }
    let partial = try publicJSON(["fetchedAt": insightISO, "sourceErrors": ["status":"unavailable"], "forecast": ["horizonHours":48, "score":23]])
    #expect(try PublicInsightParser.parse(partial, source: .willReset, fetchedAt: insightNow).upstreamStale)
}
@Test func publicCacheFutureOrAgedSnapshotIsStale() {
    let value = PublicInsightSnapshot(source: .willReset, fetchedAt: insightNow, summary: "test")
    #expect(value.isStale(now: insightNow.addingTimeInterval(901)))
    #expect(value.isStale(now: insightNow.addingTimeInterval(-61)))
}

@Test @MainActor func publicSourcesDefaultOffAndRemainIndependent() async throws {
    let suite = "public-insights-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PublicInsightsStore(defaults: defaults, automatic: false, fetcher: { source in
        PublicInsightSnapshot(source: source, fetchedAt: Date(), summary: "fixture")
    })
    #expect(store.enabled.isEmpty)
    store.setEnabled(.observatory, true)
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while store.snapshots[.observatory] == nil && ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.snapshots[.observatory]?.summary == "fixture")
    #expect(store.snapshots[.openAIStatus] == nil && store.snapshots[.willReset] == nil)
    store.stop()
}
@Test @MainActor func disablingSourceCancelsLatePublication() async throws {
    let suite = "public-cancel-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PublicInsightsStore(defaults: defaults, automatic: false, fetcher: { source in
        try? await Task.sleep(for: .milliseconds(100))
        return PublicInsightSnapshot(source: source, fetchedAt: Date(), summary: "late")
    })
    store.setEnabled(.observatory, true); store.setEnabled(.observatory, false)
    try await Task.sleep(for: .milliseconds(150))
    #expect(store.snapshots[.observatory] == nil)
    #expect(store.refreshing.isEmpty)
    store.stop()
}
