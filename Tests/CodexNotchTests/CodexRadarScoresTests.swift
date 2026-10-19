import Foundation
import Testing
@testable import CodexNotch

@Test func radarBenchPreservesOfficialTotalAndDoesNotInventMissingCosts() throws {
    let binding = try JSONDecoder().decode(CodexRadarBenchBinding.self, from: radarBindingFixture())
    try binding.validate()
    let entry = try CodexRadarBenchEntry.decode(radarSummaryFixture(), binding: binding,
        selection: .init(model: "gpt-example", effort: "max"), fetchedAt: radarScoreDate)
    #expect(entry.card(for: .comprehensive).score == 112.5)
    #expect(entry.card(for: .software).score == 100)
    #expect(entry.card(for: .visual).score == 150)
    #expect(entry.card(for: .terminal).score == 75)
    #expect(entry.card(for: .science).score == 50)
    #expect(entry.card(for: .science).sampleLabel == "覆盖 19/19 题")
    #expect(entry.averageMinutes == 1)
    #expect(entry.costUSD == nil)
    #expect(entry.updatedAt != entry.fetchedAt)
    let source = String(decoding: radarSummaryFixture(), as: UTF8.self)
    for invalid in [source.replacingOccurrences(of: "\"score_max\":150", with: "\"score_max\":100"),
                    source.replacingOccurrences(of: "\"score\":112.5", with: "\"score\":151"),
                    source.replacingOccurrences(of: "\"coverage\":64", with: "\"coverage\":0"),
                    source.replacingOccurrences(of: "synthetic-catalog", with: "other-catalog")] {
        #expect(throws: (any Error).self) {
            try CodexRadarBenchEntry.decode(Data(invalid.utf8), binding: binding,
                selection: .init(model: "gpt-example", effort: "max"), fetchedAt: radarScoreDate)
        }
    }
}

@Test func radarCommunityMapsExactEffortAndKeepsMissingRatingsUnknown() throws {
    let snapshot = try CodexRadarCommunitySnapshot.decode(radarCommunityFixture(), fetchedAt: radarScoreDate)
    #expect(snapshot.ratings.first?.selection.id == "gpt-example|max")
    #expect(snapshot.ratings.first?.average == 8.5)
    #expect(snapshot.ratings.first?.count == 12)
    #expect(snapshot.ratings.last?.average == nil)
    let invalid = String(decoding: radarCommunityFixture(), as: UTF8.self)
        .replacingOccurrences(of: "\"average\":8.5", with: "\"average\":12")
    let invalidSnapshot = try CodexRadarCommunitySnapshot.decode(Data(invalid.utf8), fetchedAt: radarScoreDate)
    #expect(invalidSnapshot.ratings.first?.average == nil)
    #expect(throws: (any Error).self) {
        try CodexRadarCommunitySnapshot.decode(Data("{}".utf8), fetchedAt: radarScoreDate)
    }
}

@Test func radarCombinedScoresKeepScalesSeparateAndSortMissingLast() throws {
    let binding = try JSONDecoder().decode(CodexRadarBenchBinding.self, from: radarBindingFixture())
    let radar = try binding.model_efforts.map {
        try CodexRadarBenchEntry.decode(radarSummaryFixture(model: $0.model, effort: $0.effort),
            binding: binding, selection: $0, fetchedAt: radarScoreDate).card(for: .comprehensive)
    }
    let community = try CodexRadarCommunitySnapshot.decode(radarCommunityFixture(), fetchedAt: radarScoreDate)
    let byRadar = CodexRadarCombinedScore.combine(radar, community: community, sort: .radar)
    #expect(byRadar.map(\.id) == ["gpt-example|max", "gpt-second|high", "gpt-community-only|low"])
    #expect(byRadar.first?.radar.score == 112.5)
    #expect(byRadar.first?.community?.average == 8.5)
    let byCommunity = CodexRadarCombinedScore.combine(radar, community: community, sort: .community)
    #expect(byCommunity.first?.id == "gpt-second|high")
    #expect(CodexRadarCombinedScore.combine(radar, community: nil, sort: .community).map(\.id) == radar.map(\.id).sorted())
}

@Test func radarCurrentEndpointsArePublicAndBounded() async throws {
    let client = CodexRadarClient { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!request.httpShouldHandleCookies)
        #expect(request.httpMethod == "GET")
        return (radarFixtureResponse(request), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let read = try await client.fetchBench().decode(fetchedAt: radarScoreDate)
    #expect(read.entries.count == 2)
    #expect(read.errors.isEmpty)
    #expect(try await client.fetchCommunity() == radarCommunityFixture())
    for url in ["https://codexradar.com/api/radar-bench-score?model=gpt-example&effort=max&view=detail",
                "https://other.example/api/model-ratings", "https://codexradar.com/api/model-ratings?token=bad",
                "https://codexradar.com/api/radar-bench-score?model=gpt-example&effort=max&view=summary&effort=low"] {
        #expect(!CodexRadarClient.isAllowed(URL(string: url)!, authorized: false))
    }
}
