import Foundation
import CoreFoundation

// 公开服务状态、社区预测与个人额度严格分离；这些数据没有执行任务的权限。
enum PublicInsightSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAIStatus, observatory, willReset
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAIStatus: "OpenAI 服务状态"
        case .observatory: "Codex Reset Observatory"
        case .willReset: "Will Codex Reset"
        }
    }
    var endpoint: URL {
        switch self {
        case .openAIStatus: URL(string: "https://status.openai.com/api/v2/summary.json")!
        case .observatory: URL(string: "https://codex.gussuriworks.com/api/current?locale=zh")!
        case .willReset: URL(string: "https://www.willcodexquotareset.com/api/forecast")!
        }
    }
    var refreshInterval: TimeInterval { self == .openAIStatus ? 300 : 1800 }
    var website: URL {
        switch self {
        case .openAIStatus: URL(string: "https://status.openai.com/")!
        case .observatory: URL(string: "https://codex.gussuriworks.com/zh")!
        case .willReset: URL(string: "https://www.willcodexquotareset.com/")!
        }
    }
}
struct PublicStatusComponent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var state: String
    var groupID: String? = nil
    var isGroup: Bool? = nil
    var position: Int? = nil
    var affected: Bool { state != "operational" }
    var label: String {
        switch state {
        case "operational": "正常"
        case "degraded_performance": "性能降级"
        case "partial_outage": "部分故障"
        case "major_outage": "严重故障"
        case "under_maintenance": "维护中"
        default: "未知"
        }
    }
}
struct PublicInsightSnapshot: Codable, Equatable, Sendable {
    var source: PublicInsightSource
    var fetchedAt: Date
    var updatedAt: Date?
    var upstreamStale = false
    var summary: String
    var probabilities: [Int: Double] = [:] // 百分比；公开接口按各自协议转换，不能猜测单位。
    var components: [PublicStatusComponent] = []
    var incidents: [String] = []
    var overallIndicator: String?
    var announcement: String?
    var lastResetAt: Date?
    var latestTiboText: String? = nil
    var latestTiboAt: Date? = nil
    var latestTiboURL: URL? = nil
    var isForecast: Bool { source != .openAIStatus }
    func isStale(now: Date = Date()) -> Bool {
        upstreamStale || now.timeIntervalSince(fetchedAt) > max(source.refreshInterval * 3, 15 * 60) || fetchedAt > now.addingTimeInterval(60)
    }
}
enum PublicInsightError: Error, LocalizedError {
    case invalidResponse, tooLarge, http(Int), redirect, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "来源数据格式不兼容，未使用无效数值。"
        case .tooLarge: "公开数据超出读取上限。"
        case .http(let code): "公开来源返回 HTTP \(code)。"
        case .redirect: "公开来源发生重定向，已停止请求。"
        case .unavailable: "公开来源暂不可用。"
        }
    }
}
enum PublicInsightParser {
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    static func text(_ value: Any?, limit: Int = 500) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.filter { !$0.isASCII || ($0.asciiValue ?? 0) >= 32 }.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(limit))
    }
    static func parse(_ data: Data, source: PublicInsightSource, fetchedAt: Date = Date()) throws -> PublicInsightSnapshot {
        guard data.count <= 2 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PublicInsightError.invalidResponse
        }
        switch source {
        case .openAIStatus:
            guard let status = root["status"] as? [String: Any], let indicator = text(status["indicator"], limit: 40),
                  let raw = root["components"] as? [[String: Any]] else { throw PublicInsightError.invalidResponse }
            let parts = raw.prefix(300).compactMap { part -> PublicStatusComponent? in
                guard let id = text(part["id"], limit: 100), let name = text(part["name"], limit: 150),
                      let state = text(part["status"], limit: 60) else { return nil }
                return .init(id: id, name: name, state: state,
                    groupID: text(part["group_id"], limit: 100),
                    isGroup: part["group"] as? Bool,
                    position: (part["position"] as? NSNumber)?.intValue)
            }
            let incidents = (root["incidents"] as? [[String: Any]] ?? []).prefix(20).compactMap { text($0["name"]) }
            var snapshot = PublicInsightSnapshot(source: source, fetchedAt: fetchedAt,
                updatedAt: date((root["page"] as? [String: Any])?["updated_at"]),
                summary: text(status["description"]) ?? "官方总体状态", components: parts, incidents: incidents)
            snapshot.overallIndicator = indicator
            return snapshot
        case .observatory:
            guard let model = root["viewModel"] as? [String: Any] else { throw PublicInsightError.invalidResponse }
            var values: [Int: Double] = [:]
            for hours in [12, 24, 48, 72] {
                if let value = number(model["probability\(hours)h"]), (0...1).contains(value) { values[hours] = value * 100 }
            }
            guard !values.isEmpty, let checked = date(root["checkedAt"] ?? model["lastUpdated"]) else { throw PublicInsightError.invalidResponse }
            let health = root["dataHealth"] as? [String: Any]
            let window = model["activeWindow"] as? [String: Any]
            var snapshot = PublicInsightSnapshot(source: source, fetchedAt: fetchedAt, updatedAt: checked,
                upstreamStale: (health?["stale"] as? Bool == true) || checked < fetchedAt.addingTimeInterval(-1800)
                    || checked > fetchedAt.addingTimeInterval(60),
                summary: text(model["displayReasoningSummary"]) ?? "社区概率估计，仅供参考。", probabilities: values)
            snapshot.announcement = text(window?["summary"])
            snapshot.lastResetAt = date(root["lastRandomResetAt"])
            if let activity = root["latestTiboActivity"] as? [String: Any] {
                snapshot.latestTiboText = text(activity["text"], limit: 500)
                snapshot.latestTiboAt = date(activity["createdAt"])
                if let raw = text(activity["sourceUrl"], limit: 300),
                   let url = URL(string: raw), url.scheme == "https", url.host == "x.com",
                   url.path.hasPrefix("/thsottiaux/status/") { snapshot.latestTiboURL = url }
            }
            return snapshot
        case .willReset:
            guard let forecast = root["forecast"] as? [String: Any],
                  number(forecast["horizonHours"]) == 48,
                  let score = number(forecast["score"]), (0...100).contains(score),
                  let checked = date(root["fetchedAt"]) else { throw PublicInsightError.invalidResponse }
            let errors = root["sourceErrors"] as? [String: Any] ?? [:]
            let partial = errors.values.contains { value in
                if let flag = value as? Bool { return flag }
                if let value = value as? String { return !value.isEmpty }
                return !(value is NSNull)
            }
            let breakdown = (forecast["breakdown"] as? [[String: Any]] ?? []).prefix(5).compactMap { text($0["label"], limit: 120) }
            var snapshot = PublicInsightSnapshot(source: source, fetchedAt: fetchedAt, updatedAt: checked,
                upstreamStale: partial || checked < fetchedAt.addingTimeInterval(-1800) || checked > fetchedAt.addingTimeInterval(60),
                summary: (forecast["calibrated"] as? Bool == false ? "未校准的社区评分，不代表可靠发生率。 " : "社区预测，仅供参考。 ") + (breakdown.isEmpty ? "不代表此账号已恢复额度。" : breakdown.joined(separator: " · ")),
                probabilities: [48: score])
            snapshot.lastResetAt = date(forecast["latestResetAt"])
            if forecast["resetAnnounced"] as? Bool == true { snapshot.announcement = "该站报告存在重置预告；请以个人官方额度为准。" }
            return snapshot
        }
    }
}
