import Foundation

/// 输出速率的来源、覆盖范围与新鲜度独立于额度和费用。
struct TokenRateSummary: Equatable, Sendable {
    var value: Double?
    var measuredAt: Date?
    var isEstimate = false
    var isStale = false
    var measuredCount = 0
    var activeCount = 0

    static let unavailable = Self(value: nil, measuredAt: nil)

    func hasMeasurement(at now: Date) -> Bool {
        guard let measuredAt, let value, value.isFinite, value > 0 else { return false }
        return measuredAt <= now
    }

    func isFresh(at now: Date) -> Bool {
        guard !isStale, hasMeasurement(at: now), let measuredAt else { return false }
        return (0..<OutputEstimate.freshnessInterval).contains(now.timeIntervalSince(measuredAt))
    }

    func formatted(at now: Date) -> String {
        guard hasMeasurement(at: now), let value else { return "— token/s" }
        return (isEstimate ? "≈" : "") + String(format: "%.1f token/s", value)
    }

    func explanation(at now: Date) -> String {
        guard value != nil, let measuredAt else {
            return "等待有效输出样本；只有配额或余额的数据源不能测速。"
        }
        let method = isEstimate ? "输出计数增量估算" : "最近一次请求的输出 token / 可观测请求耗时"
        let state = isFresh(at: now) ? "有效样本 \(measuredCount)/\(max(activeCount, measuredCount))" : "最近测量，等待工具或样本已过期"
        let time = measuredAt.formatted(date: .omitted, time: .standard)
        return "\(method)；\(state)；采样时间 \(time)。包含首 token 等待，排除可确认的阻塞工具等待；不计输入，推理 token 不重复相加。"
    }

    static func aggregate(_ samples: [TokenRateTaskSample], activeThreadIDs: Set<String>,
                          expectedActiveCount: Int, now: Date) -> Self {
        // 每个文件只报告自身输出；父会话的账单合计不参与测速。
        var unique: [String: TokenRateTaskSample] = [:]
        for sample in samples where !sample.isInternalReview && sample.value.isFinite && sample.value > 0
            && sample.measuredAt <= now {
            if unique[sample.threadID].map({ sample.measuredAt > $0.measuredAt }) ?? true {
                unique[sample.threadID] = sample
            }
        }
        let active = unique.values.filter { sample in
            var candidate: String? = sample.threadID
            var seen: Set<String> = []
            while let id = candidate, seen.count < 64, seen.insert(id).inserted {
                if activeThreadIDs.contains(id) { return true }
                candidate = unique[id]?.parentThreadID
            }
            return false
        }
        let fresh = active.filter {
            !$0.isWaiting && !$0.isFinished && (0..<OutputEstimate.freshnessInterval).contains(now.timeIntervalSince($0.measuredAt))
        }
        if !fresh.isEmpty {
            return Self(value: fresh.reduce(0) { $0 + $1.value }, measuredAt: fresh.map(\.measuredAt).min(),
                        isEstimate: fresh.contains(where: \.isEstimate), measuredCount: fresh.count,
                        activeCount: max(expectedActiveCount, fresh.count))
        }
        // 没有新鲜并发样本时，只展示最新单次测量，避免相加历史速率冒充当前总速率。
        guard let recent = active.max(by: { $0.measuredAt < $1.measuredAt }) else {
            return Self(value: nil, measuredAt: nil, activeCount: expectedActiveCount)
        }
        return Self(value: recent.value, measuredAt: recent.measuredAt, isEstimate: recent.isEstimate,
                    isStale: true, measuredCount: 1, activeCount: expectedActiveCount)
    }
}

struct TokenRateTaskSample: Equatable, Sendable {
    let threadID: String
    let parentThreadID: String?
    let value: Double
    let measuredAt: Date
    let isEstimate: Bool
    let isWaiting: Bool
    let isFinished: Bool
    let isInternalReview: Bool
}
