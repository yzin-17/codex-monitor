import Foundation

// 保留本项目的数据源。这里只借鉴 CodexBar 的布局控件，不接入新的供应商。
enum MonitorDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, notch, menuBar
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: "自动识别屏幕"; case .notch: "刘海屏 HUD"; case .menuBar: "非刘海屏 · 菜单栏浮窗" }
    }
    func usesCompactOverlay(hasNotch: Bool) -> Bool { self == .menuBar || (self == .automatic && !hasNotch) }
}
enum MonitorPanelAnimation: String, Codable, CaseIterable, Identifiable, Sendable {
    case anchoredReveal, instant
    var id: String { rawValue }
    var title: String { self == .anchoredReveal ? "从 HUD 展开 / 收回 HUD" : "立即展开 / 收起" }
}
enum HUDMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case icon, provider, account, state // state 仅用于旧配置迁移，运行状态不属于自定义区域。
    case fiveHour, primary, weekly, scopedWeekly, automatic, primaryLane, secondaryLane, tertiaryLane
    case primaryPace, weeklyPace, scopedPace, automaticPace, usageBar, tokensToday
    case resetCountdown, resetTime, primaryCountdown, weeklyCountdown, scopedCountdown
    case primaryResetTime, weeklyResetTime, scopedResetTime, runsOut, runsOutCompact
    case balance, costToday, cost30d, separatorDot, space, hidden, conditional
    var id: String { rawValue }
    static let palette = allCases.filter { $0 != .state && $0 != .hidden }
    static let groups = ["身份", "用量", "时间", "费用", "布局", "条件"]
    var title: String {
        switch self {
        case .icon: "图标"; case .provider: "来源名称"; case .account: "账户"; case .state: "运行状态（固定）"
        case .fiveHour: "5 小时额度 %"; case .primary: "会话 %"; case .weekly: "每周 %"; case .scopedWeekly: "范围每周 %"; case .automatic: "自动 %"
        case .primaryLane: "第一额度 %"; case .secondaryLane: "第二额度 %"; case .tertiaryLane: "第三额度 %"
        case .primaryPace: "会话节奏"; case .weeklyPace: "每周节奏"; case .scopedPace: "范围每周节奏"; case .automaticPace: "自动节奏"
        case .usageBar: "用量条"; case .tokensToday: "今日 Token"
        case .resetCountdown: "重置倒计时 · 自动"; case .resetTime: "重置时间 · 自动"
        case .primaryCountdown: "会话重置倒计时"; case .weeklyCountdown: "每周重置倒计时"; case .scopedCountdown: "范围每周倒计时"
        case .primaryResetTime: "会话重置时间"; case .weeklyResetTime: "每周重置时间"; case .scopedResetTime: "范围每周时间"
        case .runsOut: "预计用尽"; case .runsOutCompact: "预计用尽（紧凑）"
        case .balance: "余额"; case .costToday: "今日费用"; case .cost30d: "30 天费用"
        case .separatorDot: "分隔点"; case .space: "空格"; case .hidden: "隐藏"; case .conditional: "条件控件"
        }
    }
    var group: String {
        switch self {
        case .icon, .provider, .account, .state: "身份"
        case .fiveHour, .primary, .weekly, .scopedWeekly, .automatic, .primaryLane, .secondaryLane, .tertiaryLane,
             .primaryPace, .weeklyPace, .scopedPace, .automaticPace, .usageBar, .tokensToday: "用量"
        case .balance, .costToday, .cost30d: "费用"
        case .separatorDot, .space, .hidden: "布局"
        case .conditional: "条件"
        default: "时间"
        }
    }
    var symbol: String {
        switch self {
        case .icon: "scope"; case .provider: "textformat"; case .account: "person.crop.circle"; case .state: "circle.fill"
        case .usageBar: "chart.bar.fill"; case .tokensToday: "number"
        case .space: "arrow.left.and.right"; case .separatorDot: "circle.fill"; case .hidden: "eye.slash"; case .conditional: "arrow.triangle.branch"
        case .primaryPace, .weeklyPace, .scopedPace, .automaticPace: "gauge.with.dots.needle.50percent"
        case .resetCountdown, .primaryCountdown, .weeklyCountdown, .scopedCountdown: "timer"
        case .resetTime, .primaryResetTime, .weeklyResetTime, .scopedResetTime: "clock"
        case .runsOut, .runsOutCompact: "hourglass"
        case .balance: "creditcard"; case .costToday, .cost30d: "dollarsign.circle"
        default: "percent"
        }
    }
    var isQuota: Bool { [.fiveHour, .primary, .weekly, .scopedWeekly, .automatic, .primaryLane, .secondaryLane, .tertiaryLane, .usageBar].contains(self) }
    var isPace: Bool { [.primaryPace, .weeklyPace, .scopedPace, .automaticPace].contains(self) }
    var isCountdown: Bool { [.resetCountdown, .primaryCountdown, .weeklyCountdown, .scopedCountdown].contains(self) }
    var isAbsoluteReset: Bool { [.resetTime, .primaryResetTime, .weeklyResetTime, .scopedResetTime].contains(self) }
    var isNumeric: Bool { isQuota || isPace || isCountdown || [.runsOut, .runsOutCompact, .costToday, .cost30d].contains(self) }
    static func parse(_ raw: String) -> Self? { Self(rawValue: String(raw.split(separator: ":").first ?? "")) }
}

enum HUDComparison: String, Codable, CaseIterable, Identifiable, Sendable {
    case greater, atLeast, less, atMost
    var id: Self { self }
    var symbol: String { switch self { case .greater: ">"; case .atLeast: "≥"; case .less: "<"; case .atMost: "≤" } }
    func evaluate(_ value: Double, _ threshold: Double) -> Bool {
        switch self { case .greater: value > threshold; case .atLeast: value >= threshold; case .less: value < threshold; case .atMost: value <= threshold }
    }
}
struct HUDPredicate: Codable, Equatable, Sendable {
    var metric: HUDMetric = .primary
    var remaining = false
    var comparison: HUDComparison = .atLeast
    var threshold: Double = 80
}
struct HUDConditional: Codable, Equatable, Sendable {
    var name = "额度提醒"
    var predicates: [HUDPredicate] = [.init()]
    var matchAll = true
    var thenMetric: HUDMetric = .primary
    var elseMetric: HUDMetric = .hidden
    var normalized: Self {
        var v = self
        v.name = String(name.prefix(40))
        v.predicates = Array(predicates.prefix(8)).filter { $0.metric.isNumeric && $0.threshold.isFinite && abs($0.threshold) <= 1_000_000_000 }
        if v.predicates.isEmpty { v.predicates = [.init()] }
        if [.conditional, .state].contains(v.thenMetric) { v.thenMetric = .primary }
        if [.conditional, .state].contains(v.elseMetric) { v.elseMetric = .hidden }
        return v
    }
}
struct HUDLayoutPosition: Equatable, Sendable { var row: Int; var index: Int }

struct HUDLayout: Codable, Equatable, Sendable {
    // 继续读取 0.3.0 的字符串行配置；空格允许重复，条件控件通过 ID 引用本布局的规则。
    var lines: [[String]]
    var conditionals: [String: HUDConditional] = [:]
    static let maximumItemsPerLine = 12
    static let compact = HUDLayout(lines: [["primary", "weekly"]])
    static let detailed = HUDLayout(lines: [["primary", "weekly"], ["tokensToday", "resetCountdown"]])
    static let costs = HUDLayout(lines: [["provider", "balance"], ["costToday", "cost30d"]])
    init(lines: [[String]], conditionals: [String: HUDConditional] = [:]) { self.lines = lines; self.conditionals = conditionals }
    enum CodingKeys: String, CodingKey { case lines, conditionals }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lines = try c.decode([[String]].self, forKey: .lines)
        conditionals = (try? c.decodeIfPresent([String: HUDConditional].self, forKey: .conditionals)) ?? [:]
    }
    var metrics: [[HUDMetric]] { normalized.lines.map { $0.compactMap(HUDMetric.parse) } }
    var normalized: Self {
        var seen = Set<String>()
        let rules = conditionals.filter { UUID(uuidString: $0.key) != nil }.mapValues(\.normalized)
        var valid = 0
        let safe = lines.prefix(2).map { line in
            var row: [String] = []
            for raw in line where row.count < Self.maximumItemsPerLine {
                guard let kind = HUDMetric.parse(raw), kind != .state else { continue }
                if kind == .conditional {
                    guard let id = raw.split(separator: ":").last.map(String.init), rules[id] != nil else { continue }
                } else if kind != .space && kind.rawValue != raw { continue }
                let value = kind == .space ? "space:\(Self.spaceWidth(raw))" : raw
                if [.space, .separatorDot].contains(kind) || seen.insert(value).inserted { row.append(value); valid += 1 }
            }
            return row
        }
        // 显式清空右侧是允许的：固定运行状态不会被清空。损坏/未知配置仍回退安全预设。
        if safe.isEmpty || (valid == 0 && lines.joined().contains(where: { $0 != "state" })) { return .compact }
        let used = Set(safe.joined().compactMap { raw -> String? in raw.hasPrefix("conditional:") ? String(raw.dropFirst(12)) : nil })
        return .init(lines: safe, conditionals: rules.filter { used.contains($0.key) })
    }
    static func spaceWidth(_ raw: String) -> Int {
        let parts = raw.split(separator: ":")
        return min(48, max(2, parts.count == 2 ? Int(parts[1]) ?? 8 : 8))
    }
    func inserting(_ metric: HUDMetric, row: Int, before: HUDMetric? = nil) -> Self {
        guard metric != .state, metric != .conditional else { return normalized }
        var next = normalized
        if metric != .space && metric != .separatorDot { next.lines = next.lines.map { $0.filter { HUDMetric.parse($0) != metric } } }
        let row = min(1, max(0, row)); while next.lines.count <= row { next.lines.append([]) }
        guard next.lines[row].count < Self.maximumItemsPerLine else { return self }
        let index = before.flatMap { wanted in next.lines[row].firstIndex(where: { HUDMetric.parse($0) == wanted }) } ?? next.lines[row].count
        next.lines[row].insert(metric == .space ? "space:8" : metric.rawValue, at: index)
        return next.normalized
    }
    func removing(_ metric: HUDMetric) -> Self { .init(lines: normalized.lines.map { $0.filter { HUDMetric.parse($0) != metric } }, conditionals: conditionals).normalized }
    func removing(at p: HUDLayoutPosition) -> Self {
        var next = normalized; guard next.contains(p) else { return self }
        next.lines[p.row].remove(at: p.index); return next.normalized
    }
    func moving(from source: HUDLayoutPosition, toRow: Int, before: Int? = nil) -> Self {
        var next = normalized
        let target = min(1, max(0, toRow)); guard next.contains(source) else { return self }
        while next.lines.count <= target { next.lines.append([]) }
        if source.row != target && next.lines[target].count >= Self.maximumItemsPerLine { return self }
        var index = min(next.lines[target].count, max(0, before ?? next.lines[target].count))
        let raw = next.lines[source.row].remove(at: source.index)
        if source.row == target && source.index < index { index -= 1 }
        next.lines[target].insert(raw, at: index); return next.normalized
    }
    func settingSpace(_ width: Int, at p: HUDLayoutPosition) -> Self {
        var next = normalized; guard next.contains(p), HUDMetric.parse(next.lines[p.row][p.index]) == .space else { return self }
        next.lines[p.row][p.index] = "space:\(min(48, max(2, width)))"; return next.normalized
    }
    func addingConditional(_ rule: HUDConditional, id: String = UUID().uuidString) -> Self {
        var next = normalized; guard UUID(uuidString: id) != nil else { return self }
        let row = max(0, next.lines.count - 1)
        guard next.lines[row].count < Self.maximumItemsPerLine else { return self }
        next.conditionals[id] = rule.normalized; next.lines[row].append("conditional:" + id)
        return next.normalized
    }
    private func contains(_ p: HUDLayoutPosition) -> Bool { lines.indices.contains(p.row) && lines[p.row].indices.contains(p.index) }
}
