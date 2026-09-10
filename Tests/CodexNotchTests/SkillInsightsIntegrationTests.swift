import CodexMonitorCore
import Foundation
import Testing
@testable import CodexNotch

@MainActor
struct SkillInsightsIntegrationTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "skills-tests-\(UUID().uuidString)")!
    }

    @Test func startsWithoutScanningOrLoggingIn() {
        let model = SkillInsightsViewModel(defaults: defaults())
        #expect(model.snapshot == nil)
        #expect(!model.isAnalyzing)
        #expect(model.status == "待分析")
        #expect(model.rows.isEmpty)
    }

    @Test func disabledFeatureDoesNotStartAnalysis() {
        let store = defaults()
        store.set(false, forKey: "skills.enabled")
        let model = SkillInsightsViewModel(defaults: store)
        model.analyze()
        #expect(!model.isAnalyzing)
        #expect(model.snapshot == nil)
        #expect(model.status == "已关闭")
    }

    @Test func cancelledResultCannotReappear() async throws {
        let model = SkillInsightsViewModel(defaults: defaults(), loader: { _ in
            try? await Task.sleep(nanoseconds: 10_000_000)
            return Demo.snapshot()
        })
        model.analyze()
        model.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(!model.isAnalyzing)
        #expect(model.snapshot == nil)
    }

    @Test func scanResultPopulatesSkillsOnly() async throws {
        let model = SkillInsightsViewModel(defaults: defaults(), loader: { _ in Demo.snapshot() })
        model.analyze()
        for _ in 0..<100 where model.isAnalyzing { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(model.snapshot != nil)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.count(.fileRead) == 1)
    }

    @Test func reportExcludesPathsSessionIDsAndDescriptions() throws {
        let snapshot = Demo.snapshot()
        let rows = LedgerMath.skillRows(snapshot.skills, sessions: snapshot.sessions, since: nil)
        let object = SkillInsightsViewModel.report(rows, days: 7, date: snapshot.createdAt, partial: true)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        #expect(!encoded.contains("/demo"))
        #expect(!encoded.contains(snapshot.sessions[0].id))
        #expect(!encoded.contains(snapshot.skills[0].description))
        #expect(encoded.contains("UNAVAILABLE"))
        #expect(object["quality"] as? String == "PARTIAL")
    }
}
