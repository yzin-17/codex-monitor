import Foundation
import Combine

// 参考 CodexBar 的“布局 → 行 → 指标”模型，独立适配本项目的数据源。
enum MonitorDisplayMode: String, Codable, CaseIterable, Identifiable {
    case automatic, notch, menuBar
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: "自动识别屏幕"; case .notch: "刘海屏 HUD"; case .menuBar: "非刘海屏 · 菜单栏浮窗" }
    }
    func usesCompactOverlay(hasNotch: Bool) -> Bool { self == .menuBar || (self == .automatic && !hasNotch) }
}
enum MonitorPanelAnimation: String, Codable, CaseIterable, Identifiable {
    case anchoredReveal, instant
    var id: String { rawValue }
    var title: String { self == .anchoredReveal ? "从 HUD 展开 / 收回 HUD" : "立即展开 / 收起" }
}
enum HUDMetric: String, Codable, CaseIterable, Identifiable {
    case icon, provider, account, state
    case primary, weekly, automatic, usageBar, tokensToday
    case resetCountdown, resetTime
    case balance, costToday, cost30d
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icon: "图标"; case .provider: "来源名称"; case .account: "账户"; case .state: "运行状态"
        case .primary: "会话 %"; case .weekly: "每周 %"; case .automatic: "自动 %"; case .usageBar: "用量条"
        case .tokensToday: "今日 Token"; case .resetCountdown: "重置倒计时"; case .resetTime: "重置时间"
        case .balance: "余额"; case .costToday: "今日费用"; case .cost30d: "30 天费用"
        }
    }
    var group: String {
        switch self {
        case .icon, .provider, .account, .state: "身份"
        case .primary, .weekly, .automatic, .usageBar, .tokensToday: "用量"
        case .resetCountdown, .resetTime: "时间"
        case .balance, .costToday, .cost30d: "费用"
        }
    }
    var symbol: String {
        switch self {
        case .icon: "scope"; case .provider: "textformat"; case .account: "person.crop.circle"; case .state: "circle.fill"
        case .usageBar: "chart.bar.fill"; case .tokensToday: "number"; case .resetCountdown: "timer"
        case .resetTime: "clock"; case .balance: "creditcard"; case .costToday, .cost30d: "dollarsign.circle"
        default: "percent"
        }
    }
}
struct HUDLayout: Codable, Equatable, Sendable {
    var lines: [[String]]
    static let compact = HUDLayout(lines: [["icon", "primary", "weekly"]])
    static let detailed = HUDLayout(lines: [["state", "primary", "weekly"], ["tokensToday", "resetCountdown"]])
    static let costs = HUDLayout(lines: [["provider", "balance"], ["costToday", "cost30d"]])
    var metrics: [[HUDMetric]] { normalized.lines.map { $0.compactMap(HUDMetric.init(rawValue:)) } }
    var normalized: Self {
        var seen = Set<String>()
        let safe = lines.prefix(2).map { line in
            var row: [String] = []
            for raw in line where row.count < 6 {
                if HUDMetric(rawValue: raw) != nil && seen.insert(raw).inserted { row.append(raw) }
            }
            return row
        }
        return safe.joined().isEmpty ? .compact : .init(lines: safe.isEmpty ? Self.compact.lines : safe)
    }
    func inserting(_ metric: HUDMetric, row: Int, before: HUDMetric? = nil) -> Self {
        var next = normalized.lines.map { $0.filter { $0 != metric.rawValue } }
        let row = min(1, max(0, row))
        while next.count <= row { next.append([]) }
        guard next[row].count < 6 else { return self }
        let index = before.flatMap { next[row].firstIndex(of: $0.rawValue) } ?? next[row].count
        next[row].insert(metric.rawValue, at: index)
        return Self(lines: next).normalized
    }
    func removing(_ metric: HUDMetric) -> Self {
        Self(lines: normalized.lines.map { $0.filter { $0 != metric.rawValue } }).normalized
    }
}
struct HUDConfiguration: Codable, Equatable, Sendable {
    var mode: MonitorDisplayMode = .automatic
    var maximumWidth: Double = 220
    var horizontalPosition: Double = 0.5
    var hudOpacity: Double = 0.30
    var panelOpacity: Double = 0.78
    var animation: MonitorPanelAnimation = .anchoredReveal
    var sourceID = "local"
    var showRemaining = true
    var layout = HUDLayout.compact
    var providerLayouts: [String: HUDLayout] = [:]
    var normalized: Self {
        var copy = self
        copy.maximumWidth = maximumWidth.isFinite ? min(360, max(90, maximumWidth)) : 220
        copy.horizontalPosition = horizontalPosition.isFinite ? min(1, max(0, horizontalPosition)) : 0.5
        copy.hudOpacity = hudOpacity.isFinite ? min(1, max(0, hudOpacity)) : 0.30
        copy.panelOpacity = panelOpacity.isFinite ? min(1, max(0.35, panelOpacity)) : 0.78
        copy.layout = layout.normalized
        copy.providerLayouts = providerLayouts.mapValues(\.normalized)
        if copy.sourceID.count > 150 { copy.sourceID = "local" }
        return copy
    }
    func layout(for provider: String) -> HUDLayout { (providerLayouts[provider] ?? layout).normalized }
}
@MainActor final class HUDPreferences: ObservableObject {
    @Published var value: HUDConfiguration {
        didSet { if let data = try? JSONEncoder().encode(value.normalized) { defaults.set(data, forKey: Self.key) } }
    }
    static let key = "hudConfiguration.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(HUDConfiguration.self, from: $0) }?.normalized ?? .init()
        if defaults.data(forKey: Self.key) == nil, let old = defaults.string(forKey: "notchDisplaySource"), old != "codex" { value.sourceID = "legacy" }
    }
}
