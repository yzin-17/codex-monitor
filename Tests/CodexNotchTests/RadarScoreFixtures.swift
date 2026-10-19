import Foundation

let radarScoreDate = ISO8601DateFormatter().date(from: "2026-10-20T01:00:00Z")!
let radarScoreSelection = "gpt-example"

func radarBindingFixture() -> Data {
    Data(#"{"enabled":true,"production_read_verified":true,"benchmark":"radar-bench-final64-20261004","catalog_version":"synthetic-catalog","total_tasks":64,"source_counts":{"deepswe":15,"pompeii":16,"tb4":14,"science":19},"model_efforts":[{"model":"gpt-example","effort":"max"},{"model":"gpt-second","effort":"high"}]}"#.utf8)
}

func radarSummaryFixture(model: String = "gpt-example", effort: String = "max", software: Double = 100) -> Data {
    Data("""
    {"schema":"radar-bench-public-summary-v6-150-details","score_version":"radar-bench-v2-150","score_max":150,
     "benchmark":"radar-bench-final64-20261004","catalog_version":"synthetic-catalog","model":"\(model)","effort":"\(effort)",
     "score":\(model == "gpt-example" ? 112.5 : 75),"coverage":64,"required_tasks":64,
     "source_scores":{"deepswe":{"score":\(software),"coverage":15,"required_tasks":15},
      "pompeii":{"score":150,"coverage":16,"required_tasks":16},"tb4":{"score":75,"coverage":14,"required_tasks":14},
      "science":{"score":50,"coverage":19,"required_tasks":19}},"detail_metrics":{"latest_graded_at":"2026-10-19T08:00:00Z"},
     "statistics":{"metrics":{"elapsed_ms":{"mean":60000,"missing_samples":0},"api_equivalent_usd":{"mean":null,"missing_samples":1}}}}
    """.utf8)
}

func radarCommunityFixture() -> Data {
    Data(#"{"ok":true,"window":"rolling_24h","window_hours":24,"updated_at":"2026-10-20T00:59:00Z","models":[{"id":"gpt-example-max","average":8.5,"count":12},{"id":"gpt-second-high","average":9.5,"count":2},{"id":"gpt-community-only-low","average":7,"count":3},{"id":"gpt-empty-max","average":null,"count":0}]}"#.utf8)
}

func radarFixtureResponse(_ request: URLRequest, software: Double = 100) -> Data {
    switch request.url?.path {
    case "/data/radar-bench-binding.json": return radarBindingFixture()
    case "/api/model-ratings": return radarCommunityFixture()
    case "/api/radar-bench-score":
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let model = items.first { $0.name == "model" }!.value!
        let effort = items.first { $0.name == "effort" }!.value!
        return radarSummaryFixture(model: model, effort: effort, software: software)
    case "/": return Data(#"<html data-radar-station="codex"><section class="site-announcement"><strong class="site-announcement-headline">合成新闻</strong></section></html>"#.utf8)
    default: return Data()
    }
}
