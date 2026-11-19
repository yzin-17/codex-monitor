import Foundation

/// 当前四项总榜独立于旧 64 题能力维度；轮次之间只替换完整快照，不拼接分数。
struct CodexRadarCurrentRound: Sendable {
    static let schema = "codex-four-task-results/1"
    static let scoringProtocol = "codex-four-weighted-150-v2"
    static let weights: [String: Double] = ["combined": 60, "pompeii": 45, "pelican": 22.5, "candy": 22.5]

    let roundID: String
    let updatedAt: Date
    let fetchedAt: Date
    let models: [CodexRadarModelScore]

    static func decode(_ data: Data, fetchedAt: Date) throws -> Self {
        guard data.count <= 4 * 1024 * 1024 else { throw CodexRadarClientError.invalidResponse }
        let dto = try JSONDecoder().decode(Response.self, from: data)
        guard dto.schema == schema, dto.protocol == scoringProtocol,
              dto.round_id.hasPrefix("codex-four-"), dto.round_id.count <= 128,
              dto.round_id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              dto.score_max == 150, dto.task_weights == weights,
              dto.version_boundary.scoring_protocol == scoringProtocol,
              dto.version_boundary.weights == weights,
              dto.all_graded, dto.publication_status == "complete",
              dto.publication_contract == "codex-four-accepted-complete/1",
              (1...128).contains(dto.configurations), dto.expected == dto.configurations * 4,
              dto.graded == dto.expected, dto.rows.count == dto.configurations,
              !dto.models.isEmpty, Set(dto.models).count == dto.models.count,
              Set(dto.model_efforts.keys) == Set(dto.models),
              let updatedAt = parseDate(dto.score_snapshot_at),
              updatedAt <= fetchedAt.addingTimeInterval(300) else {
            throw CodexRadarClientError.invalidResponse
        }
        let selections = dto.model_efforts.flatMap { model, efforts in
            efforts.map { CodexRadarSelection(model: model, effort: $0) }
        }
        guard selections.count == dto.configurations,
              selections.allSatisfy(\.isSupported), Set(selections).count == selections.count else {
            throw CodexRadarClientError.invalidResponse
        }
        var seen = Set<CodexRadarSelection>()
        let cards = try dto.rows.map { row -> CodexRadarModelScore in
            let selection = CodexRadarSelection(model: row.model, effort: row.effort)
            guard seen.insert(selection).inserted, selections.contains(selection),
                  row.combined.score.isFinite, (0...100).contains(row.combined.score),
                  row.pelican.score.isFinite, (0...100).contains(row.pelican.score),
                  row.pompeii.reward.isFinite, (0...1).contains(row.pompeii.reward),
                  row.pompeii.score100.map({ $0.isFinite && abs($0 - row.pompeii.reward * 100) < 0.000001 }) ?? true else {
                throw CodexRadarClientError.invalidResponse
            }
            let score = row.combined.score / 100 * 60 + row.pompeii.reward * 45
                + row.pelican.score / 100 * 22.5 + (row.candy.correct ? 22.5 : 0)
            let costs = [row.combined.cost_usd, row.pompeii.cost_usd, row.pelican.cost_usd, row.candy.cost_usd]
            let costKinds = [row.combined.cost_kind, row.pompeii.cost_kind, row.pelican.cost_kind, row.candy.cost_kind]
            let times = [row.combined.model_elapsed_seconds, row.pompeii.model_elapsed_seconds,
                         row.pelican.model_elapsed_seconds, row.candy.model_elapsed_seconds]
            let averageCost = costKinds.allSatisfy { $0 == "api_equivalent_estimate" } ? mean(costs) : nil
            let minutes = mean(times).map { $0 / 60 }
            return .init(id: selection.id, label: selection.label, score: score, status: nil,
                         passed: nil, tasks: 4, costUSD: averageCost,
                         wallTime: minutes.map { String(format: "均时 %.1f 分钟", $0) },
                         validTasks: 4, averageMinutes: minutes, sampleLabel: "四项完成 4/4")
        }
        guard seen == Set(selections) else { throw CodexRadarClientError.invalidResponse }
        return Self(roundID: dto.round_id, updatedAt: updatedAt, fetchedAt: fetchedAt,
                    models: cards.sorted { $0.id < $1.id })
    }

    func snapshot(cached: Bool = false, message: String? = nil) -> CodexRadarSnapshot {
        var result = CodexRadarSnapshot.loading
        result.dataSource = .publicCurrentRound
        result.status = "雷达总分"
        result.monitoredAt = updatedAt
        result.fetchedAt = fetchedAt
        result.attributionText = "\(CodexRadarSnapshot.attribution) · \(roundID)"
        result.models = models.map { model in
            .init(id: model.id, label: model.label, score: model.score, status: cached ? "缓存" : nil,
                  passed: model.passed, tasks: model.tasks, costUSD: model.costUSD, wallTime: model.wallTime,
                  validTasks: model.validTasks, averageMinutes: model.averageMinutes, sampleLabel: model.sampleLabel)
        }
        return result.withState(cached ? .stale : .ready, message: message)
    }

    private static func mean(_ values: [Double?]) -> Double? {
        let valid = values.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
        guard valid.count == values.count else { return nil }
        let result = valid.reduce(0, +) / Double(valid.count)
        return result.isFinite ? result : nil
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private struct Response: Decodable {
        let schema: String
        let `protocol`: String
        let round_id: String
        let score_snapshot_at: String
        let expected: Int
        let graded: Int
        let configurations: Int
        let models: [String]
        let model_efforts: [String: [String]]
        let task_weights: [String: Double]
        let score_max: Int
        let all_graded: Bool
        let publication_status: String
        let publication_contract: String
        let version_boundary: Boundary
        let rows: [Row]
        struct Boundary: Decodable { let scoring_protocol: String; let weights: [String: Double] }
        struct Row: Decodable {
            let model: String
            let effort: String
            let combined: VisualScore
            let pelican: VisualScore
            let pompeii: SpatialScore
            let candy: ReasoningScore
        }
        struct VisualScore: Decodable {
            let score: Double
            let cost_usd: Double?
            let cost_kind: String?
            let model_elapsed_seconds: Double?
        }
        struct SpatialScore: Decodable {
            let reward: Double
            let score100: Double?
            let cost_usd: Double?
            let cost_kind: String?
            let model_elapsed_seconds: Double?
        }
        struct ReasoningScore: Decodable {
            let correct: Bool
            let cost_usd: Double?
            let cost_kind: String?
            let model_elapsed_seconds: Double?
        }
    }
}

/// 保留原始公开 JSON，每次读盘重新验证协议和轮次身份，避免旧协议缓存被误当成新总榜。
struct CodexRadarCurrentRoundCache: Codable, Sendable {
    let schema: String
    let scoringProtocol: String
    let roundID: String
    let fetchedAt: Date
    let data: Data

    init(data: Data, round: CodexRadarCurrentRound) {
        schema = CodexRadarCurrentRound.schema
        scoringProtocol = CodexRadarCurrentRound.scoringProtocol
        roundID = round.roundID
        fetchedAt = round.fetchedAt
        self.data = data
    }

    func validatedRound() throws -> CodexRadarCurrentRound {
        guard schema == CodexRadarCurrentRound.schema, scoringProtocol == CodexRadarCurrentRound.scoringProtocol else {
            throw CodexRadarClientError.invalidResponse
        }
        let round = try CodexRadarCurrentRound.decode(data, fetchedAt: fetchedAt)
        guard roundID == round.roundID else { throw CodexRadarClientError.invalidResponse }
        return round
    }
}
