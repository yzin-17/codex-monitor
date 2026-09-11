import Combine
import Foundation

struct HUDLayoutProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var layout: HUDLayout

    init(id: String = UUID().uuidString, name: String, layout: HUDLayout) {
        self.id = id
        self.name = name
        self.layout = layout
    }

    var normalized: Self {
        var copy = self
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = trimmed.isEmpty ? "布局" : String(trimmed.prefix(32))
        copy.layout = layout.normalized
        if copy.id.isEmpty || copy.id.count > 80 { copy.id = UUID().uuidString }
        return copy
    }
}

struct HUDConfiguration: Codable, Equatable, Sendable {
    var mode: MonitorDisplayMode = .automatic
    var maximumWidth: Double = 220
    var horizontalPosition: Double = 0.5
    var hudOpacity: Double = 0.90
    var panelOpacity: Double = 0.90
    var hudCornerRadius: Double? = 10
    var animation: MonitorPanelAnimation = .anchoredReveal

    /// 仅作为布局编辑器“新增控件绑定到”的记忆值；不会切换 HUD 的整套数据来源。
    var sourceID = "local"
    var showRemaining = true

    /// 兼容 0.4.3 及更早配置。运行时不再按来源选择这些布局。
    var layout = HUDLayout.compact
    var providerLayouts: [String: HUDLayout] = [:]

    /// 0.4.4 起布局与账号彻底解耦：布局保存排列，控件 token 自己保存 sourceID。
    var layoutProfiles: [HUDLayoutProfile] = [
        HUDLayoutProfile(id: "default", name: "默认布局", layout: .compact)
    ]
    var activeLayoutID = "default"

    init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, maximumWidth, horizontalPosition, hudOpacity, panelOpacity, hudCornerRadius, animation
        case sourceID, showRemaining, layout, providerLayouts, layoutProfiles, activeLayoutID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(MonitorDisplayMode.self, forKey: .mode) ?? .automatic
        maximumWidth = try c.decodeIfPresent(Double.self, forKey: .maximumWidth) ?? 220
        horizontalPosition = try c.decodeIfPresent(Double.self, forKey: .horizontalPosition) ?? 0.5
        hudOpacity = try c.decodeIfPresent(Double.self, forKey: .hudOpacity) ?? 0.90
        panelOpacity = try c.decodeIfPresent(Double.self, forKey: .panelOpacity) ?? 0.90
        hudCornerRadius = try c.decodeIfPresent(Double.self, forKey: .hudCornerRadius) ?? 10
        animation = try c.decodeIfPresent(MonitorPanelAnimation.self, forKey: .animation) ?? .anchoredReveal
        sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID) ?? "local"
        showRemaining = try c.decodeIfPresent(Bool.self, forKey: .showRemaining) ?? true
        layout = try c.decodeIfPresent(HUDLayout.self, forKey: .layout) ?? .compact
        providerLayouts = try c.decodeIfPresent([String: HUDLayout].self, forKey: .providerLayouts) ?? [:]

        if let decodedProfiles = try c.decodeIfPresent([HUDLayoutProfile].self, forKey: .layoutProfiles),
           !decodedProfiles.isEmpty {
            layoutProfiles = decodedProfiles
            activeLayoutID = try c.decodeIfPresent(String.self, forKey: .activeLayoutID) ?? decodedProfiles[0].id
        } else {
            // 旧版可能正在使用账号专属布局。迁移时只选择当前来源实际会显示的那一套，
            // 并把未绑定控件固定到当时的来源，避免升级后因编辑器下拉框变化而偷偷换账号。
            let legacyLayout = providerLayouts[sourceID] ?? layout
            layoutProfiles = [
                HUDLayoutProfile(
                    id: "default",
                    name: "默认布局",
                    layout: Self.bindingUnboundWidgets(in: legacyLayout, to: sourceID)
                )
            ]
            activeLayoutID = "default"
        }
        self = normalized
    }

    func encode(to encoder: Encoder) throws {
        let value = normalized
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value.mode, forKey: .mode)
        try c.encode(value.maximumWidth, forKey: .maximumWidth)
        try c.encode(value.horizontalPosition, forKey: .horizontalPosition)
        try c.encode(value.hudOpacity, forKey: .hudOpacity)
        try c.encode(value.panelOpacity, forKey: .panelOpacity)
        try c.encode(value.hudCornerRadius, forKey: .hudCornerRadius)
        try c.encode(value.animation, forKey: .animation)
        try c.encode(value.sourceID, forKey: .sourceID)
        try c.encode(value.showRemaining, forKey: .showRemaining)
        try c.encode(value.layout, forKey: .layout)
        try c.encode(value.providerLayouts, forKey: .providerLayouts)
        try c.encode(value.layoutProfiles, forKey: .layoutProfiles)
        try c.encode(value.activeLayoutID, forKey: .activeLayoutID)
    }

    var hudTransparency: Double {
        get { 1 - normalized.hudOpacity }
        set { hudOpacity = 1 - min(1, max(0, newValue.isFinite ? newValue : 0)) }
    }

    var panelTransparency: Double {
        get { 1 - normalized.panelOpacity }
        set { panelOpacity = 1 - min(0.65, max(0, newValue.isFinite ? newValue : 0)) }
    }

    var cornerRadius: Double {
        get {
            let value = hudCornerRadius ?? 10
            return value.isFinite ? min(24, max(0, value)) : 10
        }
        set { hudCornerRadius = newValue.isFinite ? min(24, max(0, newValue)) : 10 }
    }

    var activeProfile: HUDLayoutProfile {
        layoutProfiles.first(where: { $0.id == activeLayoutID }) ?? layoutProfiles.first
            ?? HUDLayoutProfile(id: "default", name: "默认布局", layout: .compact)
    }

    var activeLayout: HUDLayout { activeProfile.layout.normalized }

    var normalized: Self {
        var copy = self
        copy.maximumWidth = maximumWidth.isFinite ? min(360, max(90, maximumWidth)) : 220
        copy.horizontalPosition = horizontalPosition.isFinite ? min(1, max(0, horizontalPosition)) : 0.5
        copy.hudOpacity = hudOpacity.isFinite ? min(1, max(0, hudOpacity)) : 0.90
        copy.panelOpacity = panelOpacity.isFinite ? min(1, max(0.35, panelOpacity)) : 0.90
        copy.hudCornerRadius = cornerRadius
        copy.layout = layout.normalized
        copy.providerLayouts = providerLayouts.mapValues(\.normalized)
        if copy.sourceID.count > 150 { copy.sourceID = "local" }

        var seen = Set<String>()
        copy.layoutProfiles = layoutProfiles.prefix(20).compactMap { raw in
            var profile = raw.normalized
            guard seen.insert(profile.id).inserted else { return nil }
            profile.layout = Self.bindingUnboundWidgets(in: profile.layout, to: "local")
            return profile
        }
        if copy.layoutProfiles.isEmpty {
            copy.layoutProfiles = [HUDLayoutProfile(id: "default", name: "默认布局", layout: .compact)]
        }
        if !copy.layoutProfiles.contains(where: { $0.id == copy.activeLayoutID }) {
            copy.activeLayoutID = copy.layoutProfiles[0].id
        }
        return copy
    }

    /// 旧调用继续保持兼容；新 HUD 运行时直接使用 activeLayout，不再按来源自动换布局。
    func layout(for provider: String) -> HUDLayout {
        (providerLayouts[provider] ?? activeLayout).normalized
    }

    mutating func selectLayout(_ id: String) {
        guard layoutProfiles.contains(where: { $0.id == id }) else { return }
        activeLayoutID = id
        layout = activeLayout
    }

    mutating func updateActiveLayout(_ next: HUDLayout) {
        guard let index = layoutProfiles.firstIndex(where: { $0.id == activeLayoutID }) else { return }
        layoutProfiles[index].layout = Self.bindingUnboundWidgets(in: next, to: "local")
        layout = layoutProfiles[index].layout
    }

    @discardableResult
    mutating func addLayout(copyCurrent: Bool) -> String {
        let id = UUID().uuidString
        let base = copyCurrent ? activeLayout : HUDLayout.compact
        let usedNames = Set(layoutProfiles.map(\.name))
        var n = 1
        var name = "布局 \(n)"
        while usedNames.contains(name) { n += 1; name = "布局 \(n)" }
        layoutProfiles.append(.init(id: id, name: name, layout: base))
        activeLayoutID = id
        layout = base
        return id
    }

    @discardableResult
    mutating func duplicateActiveLayout() -> String {
        let id = UUID().uuidString
        let source = activeProfile
        let usedNames = Set(layoutProfiles.map(\.name))
        var n = 2
        var name = "\(source.name) 副本"
        while usedNames.contains(name) { name = "\(source.name) 副本 \(n)"; n += 1 }
        layoutProfiles.append(.init(id: id, name: name, layout: source.layout))
        activeLayoutID = id
        layout = source.layout
        return id
    }

    mutating func renameActiveLayout(_ newName: String) {
        guard let index = layoutProfiles.firstIndex(where: { $0.id == activeLayoutID }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        layoutProfiles[index].name = String(trimmed.prefix(32))
    }

    mutating func deleteActiveLayout() {
        guard layoutProfiles.count > 1,
              let index = layoutProfiles.firstIndex(where: { $0.id == activeLayoutID }) else { return }
        layoutProfiles.remove(at: index)
        activeLayoutID = layoutProfiles[min(index, layoutProfiles.count - 1)].id
        layout = activeLayout
    }

    private static func bindingUnboundWidgets(in layout: HUDLayout, to sourceID: String) -> HUDLayout {
        var next = layout.normalized
        for row in next.lines.indices {
            for index in next.lines[row].indices {
                let raw = next.lines[row][index]
                guard HUDLayoutToken.sourceID(raw) == nil,
                      let metric = HUDMetric.parse(raw),
                      ![.space, .separatorDot, .hidden].contains(metric)
                else { continue }
                next = next.settingSource(sourceID, at: .init(row: row, index: index))
            }
        }
        return next.normalized
    }
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
        if defaults.data(forKey: Self.key) == nil,
           let old = defaults.string(forKey: "notchDisplaySource"), old != "codex" {
            value.sourceID = "legacy"
        }

        if defaults.integer(forKey: "hudNeutralPaletteVersion") < 1 {
            var migrated = value
            if abs(migrated.hudOpacity - 0.30) < 0.0001 { migrated.hudOpacity = 0.985 }
            if abs(migrated.panelOpacity - 0.78) < 0.0001 { migrated.panelOpacity = 0.985 }
            value = migrated.normalized
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
            defaults.set(2, forKey: "hudAppearanceDefaultsVersion")
            defaults.set(1, forKey: "hudNeutralPaletteVersion")
        }

        if defaults.integer(forKey: "hudAppearanceDefaultsVersion") < 2 {
            var migrated = value
            if abs(migrated.hudOpacity - 0.985) < 0.0001 { migrated.hudOpacity = 0.90 }
            if abs(migrated.panelOpacity - 0.985) < 0.0001 { migrated.panelOpacity = 0.90 }
            if migrated.hudCornerRadius == nil { migrated.hudCornerRadius = 10 }
            value = migrated.normalized
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
            defaults.set(2, forKey: "hudAppearanceDefaultsVersion")
        }
    }
}
