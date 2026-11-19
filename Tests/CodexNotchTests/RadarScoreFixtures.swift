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
    case "/data/codex-four-task-results.json": return radarCurrentRoundFixture()
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

func radarCurrentRoundFixture(roundID: String = "codex-four-synthetic-1") -> Data {
    Data("""
    {"schema":"codex-four-task-results/1","protocol":"codex-four-weighted-150-v2",
     "round_id":"\(roundID)","score_snapshot_at":"2026-10-19T08:00:00Z",
     "expected":8,"graded":8,"configurations":2,"models":["gpt-example","gpt-second"],
     "model_efforts":{"gpt-example":["max"],"gpt-second":["high"]},
     "task_weights":{"combined":60,"pompeii":45,"pelican":22.5,"candy":22.5},"score_max":150,
     "all_graded":true,"publication_status":"complete","publication_contract":"codex-four-accepted-complete/1",
     "version_boundary":{"scoring_protocol":"codex-four-weighted-150-v2",
       "weights":{"combined":60,"pompeii":45,"pelican":22.5,"candy":22.5}},
     "rows":[
       {"model":"gpt-example","effort":"max",
        "combined":{"score":75,"cost_usd":1,"cost_kind":"api_equivalent_estimate","model_elapsed_seconds":60},
        "pompeii":{"reward":1,"score100":100,"cost_usd":2,"cost_kind":"api_equivalent_estimate","model_elapsed_seconds":120},
        "pelican":{"score":100,"cost_usd":3,"cost_kind":"api_equivalent_estimate","model_elapsed_seconds":180},
        "candy":{"correct":false,"cost_usd":4,"cost_kind":"api_equivalent_estimate","model_elapsed_seconds":240}},
       {"model":"gpt-second","effort":"high","combined":{"score":50},"pompeii":{"reward":0.5},
        "pelican":{"score":100},"candy":{"correct":false}}]}
    """.utf8)
}
