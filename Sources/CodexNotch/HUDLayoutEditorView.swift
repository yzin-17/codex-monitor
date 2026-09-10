import SwiftUI

struct HUDLayoutEditorView: View {
    @ObservedObject var preferences: HUDPreferences
    @ObservedObject var accounts: CodexAccountsStore
    @ObservedObject var remote: RemoteMonitorViewModel
    @ObservedObject var newAPI: BalanceMonitorViewModel
    @ObservedObject var subAPI: BalanceMonitorViewModel
    @State private var scope = "all"
    private var layout: HUDLayout { scope == "all" ? preferences.value.layout : preferences.value.providerLayouts[scope] ?? preferences.value.layout }
    private func save(_ layout: HUDLayout) {
        if scope == "all" { preferences.value.layout = layout.normalized }
        else { preferences.value.providerLayouts[scope] = layout.normalized }
    }
    @ViewBuilder var body: some View {
        presentationSection
        sourceSection
        layoutSection
    }
    private var presentationSection: some View {
        Section {

            Picker("屏幕外观", selection: $preferences.value.mode) {
                ForEach(MonitorDisplayMode.allCases) { Text($0.title).tag($0) }
            }
            Text("非刘海模式仍为覆盖菜单栏的浮窗（不是系统菜单栏图标）；无刘海占位，宽度按内容收紧，高度限制在菜单栏内。可调整位置以避开其他项目。")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("HUD 最大宽度：\(Int(preferences.value.maximumWidth)) pt", value: $preferences.value.maximumWidth, in: 90...360, step: 10)
            HStack { Text("浮窗横向位置"); Slider(value: $preferences.value.horizontalPosition, in: 0...1) }
            HStack { Text("HUD 背景浓度"); Slider(value: $preferences.value.hudOpacity, in: 0...1); Text("\(Int(preferences.value.hudOpacity * 100))%") }
            HStack { Text("下拉面板背景浓度"); Slider(value: $preferences.value.panelOpacity, in: 0.35...1); Text("\(Int(preferences.value.panelOpacity * 100))%") }
            Picker("面板动画", selection: Binding(get: { preferences.value.animation }, set: { preferences.value.animation = $0 })) {
                ForEach(MonitorPanelAnimation.allCases) { Text($0.title).tag($0) }
            }
            Text("只改变背景，不降低文字透明度；遵循系统“减少动态效果”和“降低透明度”。面板保持 680 × 720 目标尺寸，字体不再缩放。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("显示模式 · 即时生效") }
    }
    private var sourceSection: some View {
        Section {
            Picker("展示账户", selection: $preferences.value.sourceID) {
                Text("本机 Codex").tag("local")
                Text("沿用旧版来源选择 / 自动提醒").tag("legacy")
                ForEach(accounts.accounts) { Text("Codex · \($0.label)").tag($0.hudID) }
                ForEach(remote.snapshot.accounts) { Text("网关 · \($0.displayName)").tag("remote:\($0.id)") }
                ForEach(newAPI.snapshot.accounts) { Text("NewAPI · \($0.displayName)").tag("newapi:\($0.id)") }
                ForEach(subAPI.snapshot.accounts) { Text("Sub2API · \($0.displayName)").tag("subapi:\($0.id)") }
            }
            Toggle("百分比显示剩余（关闭后显示已用）", isOn: $preferences.value.showRemaining)
        } header: { Text("HUD 数据来源 · 即时生效") }
    }
    private var layoutSection: some View {
        Section {
            HStack {
                Picker("布局作用域", selection: $scope) {
                    Text("所有来源（默认）").tag("all")
                    Text("Codex").tag("codex")
                    Text("网关账户").tag("gateway")
                    Text("NewAPI").tag("newapi:"); Text("Sub2API").tag("subapi:")
                }
                Menu("使用预设") {
                    Button("紧凑额度") { save(.compact) }
                    Button("用量和重置") { save(.detailed) }
                    Button("余额和费用") { save(.costs) }
                    if scope != "all" { Button("恢复跟随默认") { preferences.value.providerLayouts[scope] = nil } }
                }
            }
            Text(scope != "all" && preferences.value.providerLayouts[scope] == nil ? "当前继承默认布局，修改后为此来源单独保存。" : "每行最多 6 项、最多 2 行；账户绑定只影响展示，不自动启用或切换登录。")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                Text("布局预览 · 示例数据，不是真实账户").font(.caption).foregroundStyle(.secondary)
                HUDMetricStrip(layout: layout, data: HUDEntityData(primary: 46, weekly: 79,
                    resetsAt: Date().addingTimeInterval(3600), balance: "12.34 USD", todayTokens: "473.7M",
                    costToday: "≈1.20 USD", cost30d: "≈12.30 USD"), remaining: preferences.value.showRemaining, menuBar: true)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(Array(layout.normalized.lines.enumerated()), id: \.offset) { row, values in
                HStack(spacing: 5) {
                    ForEach(values, id: \.self) { raw in
                        if let metric = HUDMetric(rawValue: raw) {
                            chip(metric) { save(layout.removing(metric)) }
                                .contextMenu {
                                    Button("左移") {
                                        guard let index = values.firstIndex(of: raw), index > 0,
                                              let previous = HUDMetric(rawValue: values[index - 1]) else { return }
                                        save(layout.inserting(metric, row: row, before: previous))
                                    }
                                    Button(row == 0 ? "移到第二行" : "移到第一行") { save(layout.inserting(metric, row: 1 - row)) }
                                    Button("移除") { save(layout.removing(metric)) }
                                }
                                .dropDestination(for: String.self) { items, _ in drop(items, row: row, before: metric) }
                        }
                    }
                    Spacer(minLength: 12)
                }
                .padding(8).frame(minHeight: 40).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4])))
                .contentShape(Rectangle()).dropDestination(for: String.self) { items, _ in drop(items, row: row) }
            }
            HStack {
                Button(layout.normalized.lines.count == 1 ? "添加换行" : "移除换行") {
                    if layout.normalized.lines.count == 1 { save(.init(lines: [layout.lines[0], []])) }
                    else { save(.init(lines: [Array(layout.lines.joined()).prefix(6).map { $0 }])) }
                }
                Spacer()
                Label("拖到此处移除", systemImage: "trash").padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .dropDestination(for: String.self) { items, _ in
                        guard let metric = items.first.flatMap(HUDMetric.init(rawValue:)) else { return false }
                        save(layout.removing(metric)); return true
                    }
            }
            ForEach(["身份", "用量", "时间", "费用"], id: \.self) { group in
                Text(group).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 7) {
                    ForEach(HUDMetric.allCases.filter { $0.group == group }) { metric in
                        chip(metric) { save(layout.inserting(metric, row: layout.normalized.lines.count - 1)) }
                    }
                }
            }
            Text("— 表示数据源不支持或尚未读取。API 自然月支出不会当作滚动 30 天；不具备可靠历史的来源不提供“预计用尽”等推算。菜单栏过窄会截断，可调整宽度或减少指标；原始完整值可悬停查看。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("布局 · 拖动排序 / 点击添加") }
    }
    private func chip(_ metric: HUDMetric, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(metric.title, systemImage: metric.symbol).font(.system(size: 11)).padding(.horizontal, 7).padding(.vertical, 5) }
            .buttonStyle(.plain).background(.quaternary, in: Capsule()).draggable(metric.rawValue)
            .accessibilityLabel("\(metric.title)，点击添加或移除，拖动排序")
    }
    private func drop(_ items: [String], row: Int, before: HUDMetric? = nil) -> Bool {
        guard let metric = items.first.flatMap(HUDMetric.init(rawValue:)) else { return false }
        save(layout.inserting(metric, row: row, before: before)); return true
    }
}
