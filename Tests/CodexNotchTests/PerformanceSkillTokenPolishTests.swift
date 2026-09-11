import Foundation
import Testing
@testable import CodexNotch

@Test func performanceSamplerDoesNotUseTheOldTwoSecondProcessDeadline() {
    #expect(PerformanceSampler.processListTimeout >= 5)
    #expect(PerformanceSampler.memoryPressureTimeout >= 3)
}

@Test func tokenUsageSummaryBreaksEstimatedCostDownByModel() throws {
    var summary = TokenUsageSummary.zero
    summary.add(
        TokenUsageBreakdown(
            inputTokens: 100_000,
            cachedInputTokens: 20_000,
            outputTokens: 10_000,
            reasoningOutputTokens: 2_000,
            totalTokens: 110_000
        ),
        model: "gpt-5.6-sol"
    )
    summary.add(
        TokenUsageBreakdown(
            inputTokens: 80_000,
            cachedInputTokens: 10_000,
            outputTokens: 5_000,
            reasoningOutputTokens: 1_000,
            totalTokens: 85_000
        ),
        model: "gpt-5.6-luna"
    )

    let rows = summary.modelCostRows
    #expect(rows.count == 2)
    #expect(Set(rows.map(\.model)) == Set(["gpt-5.6-sol", "gpt-5.6-luna"]))
    #expect(rows.allSatisfy { $0.costUSD != nil && $0.costSharePercent != nil && $0.isComplete })

    let rowCost = rows.compactMap(\.costUSD).reduce(0, +)
    #expect(abs(rowCost - summary.estimatedCostUSD) < 0.000_001)
    let share = rows.compactMap(\.costSharePercent).reduce(0, +)
    #expect(abs(share - 100) < 0.000_001)
}

@Test func tokenUsageSummaryKeepsUnpricedModelVisibleWithoutInventingCostShare() throws {
    var summary = TokenUsageSummary.zero
    summary.addUnpricedTokens(42_000, model: "future-model")

    let row = try #require(summary.modelCostRows.first)
    #expect(row.model == "future-model")
    #expect(row.tokens == 42_000)
    #expect(row.costUSD == nil)
    #expect(row.costSharePercent == nil)
    #expect(!row.isComplete)
}
