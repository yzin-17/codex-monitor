import Foundation

struct HUDQuotaSample: Equatable, Sendable {
    var remaining: Double?
    var resetsAt: Date?
    var duration: TimeInterval?
    var label: String
}
enum HUDTone: Equatable { case primary, secondary, tertiary, healthy, warning, critical }
struct HUDDisplayValue: Equatable {
    var label = ""
    var value: String
    var tone: HUDTone = .primary
    var text: String { label.isEmpty ? value : label + " " + value }
}
struct HUDEntityData: Equatable {
    var providerID = "codex"
    var provider = "Codex"
    var account = "本机"
    var planType: String?
    var state = "IDLE" // 数据源状态，仅用于说明；HUD 左侧运行状态始终取自本机 UsageSnapshot。
    var primary: Double?
    var weekly: Double?
    var resetsAt: Date?
    var balance: String?
    var todayTokens: String?
    var costToday: String?
    var cost30d: String?
    var warning: String?
    var primaryLabel = "5h"
    var primaryWindow: HUDQuotaSample?
    var weeklyWindow: HUDQuotaSample?
    var scopedWindow: HUDQuotaSample?
    var lanes: [HUDQuotaSample] = []
    var capturedAt: Date?
    var costTodayUSD: Double?
    var cost30dUSD: Double?
    var automatic: Double? { [primary, weekly].compactMap(validPercent).min() }
    private func validPercent(_ number: Double?) -> Double? {
        guard let number, number.isFinite, (0...100).contains(number) else { return nil }; return number
    }
    private var automaticWindow: HUDQuotaSample? {
        [primaryWindow, weeklyWindow].compactMap { $0 }.filter { validPercent($0.remaining) != nil }
            .min { ($0.remaining ?? 100) < ($1.remaining ?? 100) }
    }
    private var hasFiveHourQuota: Bool {
        if let lane = lanes.first(where: {
            $0.label.lowercased().replacingOccurrences(of: " ", with: "") == "5h"
        }), validPercent(lane.remaining) != nil {
            return true
        }
        if let primaryWindow, validPercent(primaryWindow.remaining) != nil {
            return true
        }
        return validPercent(primary) != nil
    }
    private var hidesFiveHourQuota: Bool {
        CodexPlanKind(planType: planType) == .pro || !hasFiveHourQuota
    }
    private func isFiveHourMetric(_ metric: HUDMetric) -> Bool {
        [.fiveHour, .primary, .primaryPace, .primaryCountdown, .primaryResetTime].contains(metric)
    }
    func window(for metric: HUDMetric) -> HUDQuotaSample? {
        switch metric {
        case .fiveHour: return lanes.first(where: { $0.label.lowercased().replacingOccurrences(of: " ", with: "") == "5h" }) ?? primaryWindow
        case .primary, .primaryPace, .primaryCountdown, .primaryResetTime: return primaryWindow ?? .init(remaining: primary, label: primaryLabel)
        case .weekly, .weeklyPace, .weeklyCountdown, .weeklyResetTime: return weeklyWindow ?? .init(remaining: weekly, label: "7d")
        case .scopedWeekly, .scopedPace, .scopedCountdown, .scopedResetTime: return scopedWindow
        case .primaryLane: return lanes.first
        case .secondaryLane: return lanes.count > 1 ? lanes[1] : nil
        case .tertiaryLane: return lanes.count > 2 ? lanes[2] : nil
        default: return automaticWindow ?? .init(remaining: automatic, resetsAt: resetsAt, label: "自动")
        }
    }
    func tone(for percent: Double?) -> HUDTone {
        guard let p = validPercent(percent) else { return .tertiary }
        return p <= 20 ? .critical : p <= 40 ? .warning : .healthy
    }
    // 与 CodexBar 一样区分“窗口内匀速进度差”和“按当前窗口平均速度的预计用尽”。
    // 缺窗口长度/重置时间、过期、刚开窗或刷新报错时不给出虚构推算。
    private func elapsed(_ w: HUDQuotaSample?, now: Date) -> TimeInterval? {
        guard warning == nil, let w, let duration = w.duration, duration.isFinite, duration > 60,
              let reset = w.resetsAt, let capturedAt, now.timeIntervalSince(capturedAt) >= -60,
              now.timeIntervalSince(capturedAt) <= 600 else { return nil }
        let left = reset.timeIntervalSince(now), elapsed = duration - left
        guard left > 0, left <= duration, elapsed >= 60 else { return nil }
        return elapsed
    }
    func numeric(_ metric: HUDMetric, remaining: Bool = false, now: Date = Date()) -> Double? {
        let w = window(for: metric)
        if metric.isQuota { return validPercent(w?.remaining).map { remaining ? $0 : 100 - $0 } }
        if metric.isPace {
            guard let elapsed = elapsed(w, now: now), let duration = w?.duration, let p = validPercent(w?.remaining) else { return nil }
            return 100 - p - elapsed / duration * 100
        }
        if metric.isCountdown { return w?.resetsAt.map { max(0, $0.timeIntervalSince(now)) / 3600 } }
        if [.runsOut, .runsOutCompact].contains(metric) {
            guard let elapsed = elapsed(w, now: now), let p = validPercent(w?.remaining), p < 100 else { return nil }
            return p * elapsed / (100 - p) / 3600
        }
        if metric == .costToday { return costTodayUSD }
        if metric == .cost30d { return cost30dUSD }
        return nil
    }
    func resolvedMetric(raw: String, layout: HUDLayout, now: Date = Date()) -> HUDMetric? {
        guard let kind = HUDMetric.parse(raw) else { return nil }
        if kind != .conditional {
            return hidesFiveHourQuota && isFiveHourMetric(kind) ? nil : kind
        }
        guard let id = HUDLayoutToken.conditionalID(raw), let stored = layout.conditionals[id], warning == nil else { return nil }
        if let capturedAt, now.timeIntervalSince(capturedAt) > 600 { return nil }
        let rule = stored.normalized
        var results: [Bool] = []
        for p in rule.normalized.predicates {
            guard let value = numeric(p.metric, remaining: p.remaining, now: now) else { return nil }
            results.append(p.comparison.evaluate(value, p.threshold))
        }
        let resolved = (rule.matchAll ? results.allSatisfy { $0 } : results.contains(true)) ? rule.thenMetric : rule.elseMetric
        return hidesFiveHourQuota && isFiveHourMetric(resolved) ? nil : resolved
    }
    func display(_ metric: HUDMetric, remaining: Bool, now: Date = Date()) -> HUDDisplayValue {
        if metric.isQuota && metric != .usageBar {
            let w = window(for: metric), percent = validPercent(w?.remaining)
            let label: String = switch metric {
            case .fiveHour: w?.label ?? "5h"
            case .primary: primaryLabel
            case .weekly: "7d"
            case .scopedWeekly: w?.label ?? "范围"
            case .automatic: w?.label ?? "自动"
            default: w?.label ?? (metric == .primaryLane ? "第一" : metric == .secondaryLane ? "第二" : "第三")
            }
            return .init(label: label, value: percent.map { "\(Int((remaining ? $0 : 100 - $0).rounded()))%" } ?? "—", tone: tone(for: percent))
        }
        if metric.isPace {
            let n = numeric(metric, now: now)
            return .init(label: metric == .primaryPace ? "5h" : metric == .weeklyPace ? "7d" : metric == .scopedPace ? "范围" : "节奏",
                         value: n.map { String(format: "%+.0f%%", $0) } ?? "—", tone: n.map { $0 > 20 ? .critical : $0 > 0 ? .warning : .healthy } ?? .tertiary)
        }
        if metric.isCountdown || metric.isAbsoluteReset {
            guard let reset = window(for: metric)?.resetsAt else { return .init(value: "重置 —", tone: .tertiary) }
            let seconds = reset.timeIntervalSince(now)
            guard seconds > 0 else { return .init(value: "待刷新", tone: .tertiary) }
            if metric.isAbsoluteReset {
                let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return .init(value: f.string(from: reset))
            }
            return .init(value: Self.duration(seconds))
        }
        if [.runsOut, .runsOutCompact].contains(metric) {
            guard let hours = numeric(metric, now: now) else { return .init(label: "预计", value: "—", tone: .tertiary) }
            let seconds = hours * 3600
            if let reset = automaticWindow?.resetsAt, seconds >= reset.timeIntervalSince(now) {
                return .init(value: metric == .runsOutCompact ? "≈充足" : "重置前充足（估算）", tone: .healthy)
            }
            return .init(label: metric == .runsOut ? "预计用尽" : "", value: "≈" + Self.duration(seconds), tone: .warning)
        }
        switch metric {
        case .icon: return .init(value: "◉")
        case .provider: return .init(value: provider)
        case .account: return .init(value: account)
        case .state: return .init(value: state)
        case .usageBar: return .init(value: automatic.map { "\(Int((remaining ? $0 : 100 - $0).rounded()))%" } ?? "—", tone: tone(for: automatic))
        case .tokensToday: return .init(label: "Today", value: todayTokens ?? "—", tone: todayTokens == nil ? .tertiary : .primary)
        case .balance: return .init(value: balance ?? "余额 —", tone: balance == nil ? .tertiary : .primary)
        case .costToday: return .init(label: "今日", value: costToday ?? "—", tone: costToday == nil ? .tertiary : .primary)
        case .cost30d: return .init(label: "30天", value: cost30d ?? "—", tone: cost30d == nil ? .tertiary : .primary)
        case .separatorDot: return .init(value: "·", tone: .secondary)
        case .space: return .init(value: " ")
        case .hidden: return .init(value: "")
        default: return .init(value: "—", tone: .tertiary)
        }
    }
    func text(_ metric: HUDMetric, remaining: Bool, now: Date = Date()) -> String { display(metric, remaining: remaining, now: now).text }
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= 31_536_000_000 else { return "—" }
        if seconds >= 86400 { return "\(Int(seconds / 86400))d \(Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600))h" }
        return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m"
    }
}
