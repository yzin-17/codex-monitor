import Foundation

struct CodexRadarSelection: Codable, Hashable, Sendable {
    let model: String
    let effort: String
    var id: String { "\(model)|\(effort)" }
    var label: String { "\(model) \(effort)" }
    var isSupported: Bool {
        model.hasPrefix("gpt-") && model.count <= 80
            && model.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
            && ["low", "medium", "high", "xhigh", "max", "ultra"].contains(effort)
    }
}

struct CodexRadarBenchBinding: Decodable, Sendable {
    let enabled: Bool
    let production_read_verified: Bool
    let benchmark: String
    let catalog_version: String
    let total_tasks: Int
    let source_counts: [String: Int]
    let model_efforts: [CodexRadarSelection]

    func validate() throws {
        guard enabled, production_read_verified, benchmark == "radar-bench-final64-20261004",
              !catalog_version.isEmpty, total_tasks == 64,
              source_counts == ["deepswe": 15, "pompeii": 16, "tb4": 14, "science": 19],
              !model_efforts.isEmpty, model_efforts.count <= 64,
              model_efforts.allSatisfy(\.isSupported), Set(model_efforts).count == model_efforts.count else {
            throw CodexRadarClientError.invalidResponse
        }
    }
}

struct CodexRadarBenchEntry: Codable, Sendable {
    struct Score: Codable, Sendable {
        let score: Double?
        let coverage: Int
        let required_tasks: Int

        func validate(required: Int) throws {
            guard required_tasks == required, (0...required).contains(coverage),
                  score == nil || (coverage > 0 && score!.isFinite && (0...150).contains(score!)) else {
                throw CodexRadarClientError.invalidResponse
            }
        }
    }

    let selection: CodexRadarSelection
    let benchmark: String
    let catalogVersion: String
    let total: Score
    let sources: [String: Score]
    let updatedAt: Date?
    let fetchedAt: Date
    let costUSD: Double?
    let averageMinutes: Double?

    static func decode(_ data: Data, binding: CodexRadarBenchBinding,
                       selection: CodexRadarSelection, fetchedAt: Date) throws -> Self {
        let dto = try JSONDecoder().decode(Summary.self, from: data)
        guard dto.schema == "radar-bench-public-summary-v6-150-details",
              dto.score_version == "radar-bench-v2-150", dto.score_max == 150,
              dto.benchmark == binding.benchmark, dto.catalog_version == binding.catalog_version,
              dto.model == selection.model, dto.effort == selection.effort,
              Set(dto.source_scores.keys) == Set(binding.source_counts.keys) else {
            throw CodexRadarClientError.invalidResponse
        }
        let total = Score(score: dto.score, coverage: dto.coverage, required_tasks: dto.required_tasks)
        try total.validate(required: binding.total_tasks)
        for (key, required) in binding.source_counts {
            try dto.source_scores[key]!.validate(required: required)
        }
        guard dto.source_scores.values.reduce(0, { $0 + $1.coverage }) == total.coverage else {
            throw CodexRadarClientError.invalidResponse
        }
        func mean(_ key: String) -> Double? {
            guard let metric = dto.statistics?.metrics[key], metric.missing_samples == 0,
                  let value = metric.mean, value.isFinite, value >= 0 else { return nil }
            return value
        }
        return Self(selection: selection, benchmark: dto.benchmark, catalogVersion: dto.catalog_version,
                    total: total, sources: dto.source_scores,
                    updatedAt: dto.detail_metrics?.latest_graded_at.flatMap(CodexRadarScoreDate.parse),
                    fetchedAt: fetchedAt, costUSD: mean("api_equivalent_usd"),
                    averageMinutes: mean("elapsed_ms").map { $0 / 60000 })
    }

    func card(for dimension: CodexRadarDimension, cached: Bool = false) -> CodexRadarModelScore {
        let value = dimension.benchSource.flatMap { sources[$0] } ?? total
        return .init(id: selection.id, label: selection.label, score: value.score,
                     status: cached ? "缓存" : (value.score == nil ? "待评分" : nil),
                     passed: nil, tasks: value.required_tasks, costUSD: dimension == .comprehensive ? costUSD : nil,
                     wallTime: dimension == .comprehensive ? averageMinutes.map { String(format: "均时 %.1f 分钟", $0) } : nil,
                     validTasks: Double(value.coverage), averageMinutes: dimension == .comprehensive ? averageMinutes : nil,
                     sampleLabel: "覆盖 \(value.coverage)/\(value.required_tasks) 题")
    }

    private struct Summary: Decodable {
        let schema: String
        let score_version: String
        let score_max: Int
        let benchmark: String
        let catalog_version: String
        let model: String
        let effort: String
        let score: Double?
        let coverage: Int
        let required_tasks: Int
        let source_scores: [String: Score]
        let detail_metrics: Details?
        let statistics: Statistics?
        struct Details: Decodable { let latest_graded_at: String? }
        struct Statistics: Decodable {
            let metrics: [String: Metric]
            struct Metric: Decodable { let mean: Double?; let missing_samples: Int }
        }
    }
}

struct CodexRadarBenchRead: Sendable {
    let binding: CodexRadarBenchBinding
    let entries: [CodexRadarBenchEntry]
    let errors: [String: String]
}

struct CodexRadarBenchBatch: Sendable {
    let binding: CodexRadarBenchBinding
    let results: [CodexRadarSelection: Result<Data, Error>]

    func decode(fetchedAt: Date) -> CodexRadarBenchRead {
        var entries: [CodexRadarBenchEntry] = []
        var errors: [String: String] = [:]
        for selection in binding.model_efforts {
            do {
                guard let result = results[selection] else { throw CodexRadarClientError.emptyResponse }
                entries.append(try .decode(result.get(), binding: binding, selection: selection, fetchedAt: fetchedAt))
            } catch {
                errors[selection.id] = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).redactedForDisplay
            }
        }
        return CodexRadarBenchRead(binding: binding, entries: entries, errors: errors)
    }
}

struct CodexRadarBenchCache: Codable, Sendable {
    var entries: [CodexRadarBenchEntry]
    var checkedAt: Date
    var errors: [String: String]

    static func merging(_ read: CodexRadarBenchRead, previous: Self?, checkedAt: Date) -> Self {
        let selections = Set(read.binding.model_efforts)
        var entries = (previous?.entries ?? []).filter {
            selections.contains($0.selection) && $0.benchmark == read.binding.benchmark
                && $0.catalogVersion == read.binding.catalog_version
        }
        for entry in read.entries {
            entries.removeAll { $0.selection == entry.selection }
            entries.append(entry)
        }
        return Self(entries: entries.sorted { $0.selection.id < $1.selection.id },
                    checkedAt: checkedAt, errors: read.errors)
    }

    func snapshot(for dimension: CodexRadarDimension, failure: String?) -> CodexRadarSnapshot {
        var result = CodexRadarSnapshot.loading
        result.dataSource = .publicBench
        result.status = dimension.title
        result.models = entries.map { $0.card(for: dimension, cached: errors[$0.selection.id] != nil || errors["雷达接口"] != nil) }
        result.monitoredAt = entries.compactMap(\.updatedAt).min()
        result.fetchedAt = entries.map(\.fetchedAt).min()
        var messages = errors.sorted { $0.key < $1.key }.map { "\($0.key.replacingOccurrences(of: "|", with: " "))：\($0.value)" }
        if let failure { messages.insert(failure, at: 0) }
        let failed = !messages.isEmpty
        if failed { messages.append("雷达分未全部更新，保留已有缓存；5 分钟后自动重试，可手动重试") }
        return result.withState(entries.isEmpty ? .error : (failed ? .stale : .ready),
                                message: messages.isEmpty ? nil : messages.joined(separator: "\n"))
    }
}

struct CodexRadarCommunitySnapshot: Codable, Sendable {
    struct Rating: Codable, Equatable, Sendable {
        let selection: CodexRadarSelection
        let average: Double?
        let count: Int
    }
    let ratings: [Rating]
    let updatedAt: Date
    let fetchedAt: Date

    static func decode(_ data: Data, fetchedAt: Date) throws -> Self {
        let dto = try JSONDecoder().decode(Response.self, from: data)
        guard dto.ok, dto.window == "rolling_24h", dto.window_hours == 24,
              let updatedAt = CodexRadarScoreDate.parse(dto.updated_at),
              updatedAt <= fetchedAt.addingTimeInterval(300) else { throw CodexRadarClientError.invalidResponse }
        var seen = Set<String>()
        let ratings = dto.models.compactMap { item -> Rating? in
            guard let split = item.id.lastIndex(of: "-") else { return nil }
            let selection = CodexRadarSelection(model: String(item.id[..<split]), effort: String(item.id[item.id.index(after: split)...]))
            guard selection.isSupported, item.count >= 0, seen.insert(selection.id).inserted else { return nil }
            let valid = item.average.flatMap { $0.isFinite && (0...10).contains($0) && item.count > 0 ? $0 : nil }
            return Rating(selection: selection, average: valid, count: item.count)
        }
        return Self(ratings: ratings, updatedAt: updatedAt, fetchedAt: fetchedAt)
    }

    private struct Response: Decodable {
        let ok: Bool
        let window: String
        let window_hours: Int
        let updated_at: String
        let models: [Model]
        struct Model: Decodable { let id: String; let average: Double?; let count: Int }
    }
}

enum CodexRadarScoreSort: String, CaseIterable, Sendable {
    case radar, community
    var title: String { self == .radar ? "雷达分" : "社区体感分" }
}

struct CodexRadarCombinedScore: Identifiable, Sendable {
    let radar: CodexRadarModelScore
    let community: CodexRadarCommunitySnapshot.Rating?
    var id: String { radar.id }

    static func combine(_ radar: [CodexRadarModelScore], community: CodexRadarCommunitySnapshot?,
                        sort: CodexRadarScoreSort) -> [Self] {
        let ratings = Dictionary((community?.ratings ?? []).map { ($0.selection.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = radar.map { Self(radar: $0, community: ratings[$0.id]) }
        let ids = Set(radar.map(\.id))
        for rating in ratings.values where !ids.contains(rating.selection.id) && rating.average != nil {
            rows.append(Self(radar: .init(id: rating.selection.id, label: rating.selection.label,
                                         score: nil, status: nil, passed: nil, tasks: nil, costUSD: nil, wallTime: nil),
                             community: rating))
        }
        return rows.sorted {
            let left = sort == .radar ? $0.radar.score : $0.community?.average
            let right = sort == .radar ? $1.radar.score : $1.community?.average
            if left == right { return $0.id < $1.id }
            if let left, let right { return left > right }
            return left != nil
        }
    }
}

private enum CodexRadarScoreDate {
    static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
