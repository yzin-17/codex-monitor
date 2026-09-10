import Foundation
import Combine

struct HUDConfiguration: Codable, Equatable, Sendable {
    var mode: MonitorDisplayMode = .automatic
    var maximumWidth: Double = 220
    var horizontalPosition: Double = 0.5
    var hudOpacity: Double = 0.985
    var panelOpacity: Double = 0.985
    var animation: MonitorPanelAnimation = .anchoredReveal
    var sourceID = "local"
    var showRemaining = true
    var layout = HUDLayout.compact
    var providerLayouts: [String: HUDLayout] = [:]
    var normalized: Self {
        var copy = self
        copy.maximumWidth = maximumWidth.isFinite ? min(360, max(90, maximumWidth)) : 220
        copy.horizontalPosition = horizontalPosition.isFinite ? min(1, max(0, horizontalPosition)) : 0.5
        copy.hudOpacity = hudOpacity.isFinite ? min(1, max(0, hudOpacity)) : 0.985
        copy.panelOpacity = panelOpacity.isFinite ? min(1, max(0.35, panelOpacity)) : 0.985
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
        // 仅迁移上一版的默认背景浓度；保留用户主动调整过的其他透明度。
        if defaults.integer(forKey: "hudNeutralPaletteVersion") < 1 {
            var migrated = value
            if abs(migrated.hudOpacity - 0.30) < 0.0001 { migrated.hudOpacity = 0.985 }
            if abs(migrated.panelOpacity - 0.78) < 0.0001 { migrated.panelOpacity = 0.985 }
            value = migrated.normalized
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.key) }
            defaults.set(1, forKey: "hudNeutralPaletteVersion")
        }
    }
}
