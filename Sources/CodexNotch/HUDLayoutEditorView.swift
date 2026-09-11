import AppKit
import SwiftUI

struct HUDLayoutEditorView: View {
    @ObservedObject var preferences: HUDPreferences
    @ObservedObject var accounts: CodexAccountsStore
    @ObservedObject var remote: RemoteMonitorViewModel
    @ObservedObject var newAPI: BalanceMonitorViewModel
    @ObservedObject var subAPI: BalanceMonitorViewModel
    var notchDisplaySize: Binding<NotchDisplaySize> = .constant(.standard)
    var notchAdjustment: Binding<NotchPointAdjustment> = .constant(0)
    var legacySource: Binding<NotchDisplaySource> = .constant(.codex)
    var pulseEnabled: Binding<Bool> = .constant(true)
    @State private var scope = "all"
    @State private var ruleDraft: HUDRuleDraft?
    @State private var hasNotch = (NSScreen.main?.safeAreaInsets.top ?? 0) > 0
    private var layout: HUDLayout { (scope == "all" ? preferences.value.layout : preferences.value.providerLayouts[scope] ?? preferences.value.layout).normalized }
    private var compactOverlay: Bool { preferences.value.mode.usesCompactOverlay(hasNotch: hasNotch) }
    private func save(_ layout: HUDLayout) {
        if scope == "all" { preferences.value.layout = layout.normalized }
        else { preferences.value.providerLayouts[scope] = layout.normalized }
    }
    var body: some View {
        Group { presentationSection; layoutSection }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                hasNotch = (NSScreen.main?.safeAreaInsets.top ?? 0) > 0
            }
            .sheet(item: $ruleDraft) { draft in
                HUDConditionalEditor(initial: draft.rule, onSave: { rule in
                    var next = layout
                    if draft.existing { next.conditionals[draft.id] = rule.normalized; save(next) }
                    else { save(next.addingConditional(rule, id: draft.id, sourceID: preferences.value.sourceID)) }
                    ruleDraft = nil
                }, onCancel: { ruleDraft = nil })
            }
    }
    private var presentationSection: some View {
        Section {
            Picker("屏幕外观", selection: $preferences.value.mode) {
                ForEach(MonitorDisplayMode.allCases) { Text($0.title).tag($0) }
            }
            if compactOverlay {
                Text("覆盖菜单栏的浮窗，无刘海占位；高度填满当前屏幕菜单栏。左侧运行状态固定保留，右侧空间不足时仅裁剪自定义内容。")
                    .font(.caption).foregroundStyle(.secondary)
                numberField("浮窗最大宽度", value: $preferences.value.maximumWidth, range: 90...360, suffix: "pt")
                appearanceSlider("浮窗横向位置", value: $preferences.value.horizontalPosition, range: 0...1)
            } else {
                Picker("刘海两侧布局", selection: notchDisplaySize) {
                    ForEach(NotchDisplaySize.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Stepper("物理刘海微调：\(Int(notchAdjustment.wrappedValue)) pt", value: notchAdjustment,
                        in: -NotchPointAdjustment(IslandMetrics.notchAdjustmentLimit)...NotchPointAdjustment(IslandMetrics.notchAdjustmentLimit), step: 1)
                Text("物理遮挡区自动识别；仅在识别偏差时微调。左侧保留状态，右侧按自定义内容分配空间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            appearanceSlider("HUD 背景透明度", value: $preferences.value.hudTransparency, range: 0...1)
            appearanceSlider("下拉面板背景透明度", value: $preferences.value.panelTransparency, range: 0...0.65)
            numberField("HUD 圆角", value: Binding(get: { preferences.value.cornerRadius }, set: { preferences.value.cornerRadius = $0 }), range: 0...24, suffix: "pt")
            Button("恢复外观默认设定", action: resetAppearanceDefaults)
                .help("恢复显示模式、刘海/浮窗几何、HUD/面板透明度和展开动画；不会改动右侧数据源或自定义布局。")
            Picker("面板动画", selection: Binding(get: { preferences.value.animation }, set: { preferences.value.animation = $0 })) {
                ForEach(MonitorPanelAnimation.allCases) { Text($0.title).tag($0) }
            }
            Text("以上设置即时生效。面板维持 680 × 720 目标尺寸，原字号不缩放；背景不使用壁纸染色材质，透明度越高越透，0% 为不透明。面板上限 65% 以保证文字可读；文字本身不会变透明。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("显示模式与刘海几何") }
    }
    private func appearanceSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 150, alignment: .leading)
            Slider(value: value, in: range).accessibilityLabel(title)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
    private func numberField(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            TextField("", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }), format: .number.precision(.fractionLength(0)))
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
            Text(suffix).foregroundStyle(.secondary)
        }
    }
    private var layoutSection: some View {
        Section {
            Picker("当前数据源（新增控件绑定）", selection: $preferences.value.sourceID) {
                ForEach(bindableSources) { source in Text(source.label).tag(source.id) }
                if !bindableSources.contains(where: { $0.id == preferences.value.sourceID }) {
                    Text("已移除的数据源").tag(preferences.value.sourceID)
                }
            }
            if preferences.value.sourceID == "legacy" {
                Picker("兼容来源", selection: legacySource) {
                    ForEach(NotchDisplaySource.allCases) { Text($0.label).tag($0) }
                }
            }
            Toggle("百分比显示剩余（关闭后显示已用）", isOn: $preferences.value.showRemaining)
            Text("点击或拖入的新控件会直接绑定到当前数据源；以后切换这里的来源不会改掉已绑定控件。已放置控件仍可右键重新绑定。左侧 RUN / IDLE 始终只反映本机 Codex。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Picker("布局作用域", selection: $scope) {
                    Text("全部来源 · 默认布局").tag("all")
                    Text("本机 Codex · 独立布局").tag("local")
                    Text("Codex 账号 · 类型默认").tag("codex")
                    ForEach(accounts.accounts) { account in Text("Codex · \(account.label)").tag(account.hudID) }
                    Text("网关 · 类型默认").tag("gateway")
                    ForEach(remote.snapshot.accounts) { account in Text("网关 · \(account.displayName)").tag("remote:\(account.id)") }
                    Text("NewAPI · 类型默认").tag("newapi:")
                    ForEach(newAPI.snapshot.accounts) { account in Text("NewAPI · \(account.displayName)").tag("newapi:\(account.id)") }
                    Text("Sub2API · 类型默认").tag("subapi:")
                    ForEach(subAPI.snapshot.accounts) { account in Text("Sub2API · \(account.displayName)").tag("subapi:\(account.id)") }
                }
                Menu("使用预设") {
                    Button("紧凑额度") { save(boundPreset(.compact)) }; Button("用量和重置") { save(boundPreset(.detailed)) }
                    Button("余额和费用") { save(boundPreset(.costs)) }
                    Button("仅保留左侧运行状态") { save(.init(lines: [[]])) }
                    if scope != "all" { Button("恢复跟随默认") { preferences.value.providerLayouts[scope] = nil } }
                }
            }
            Text(scopeHelp)
                .font(.caption).foregroundStyle(.secondary)
            Text("布局作用域只决定使用哪套控件排列；控件自己的数据源由绑定决定。每行最多 12 个控件、最多 2 行，空格和分隔点可以重复添加。")
                .font(.caption).foregroundStyle(.secondary)
            preview
            ForEach(Array(layout.lines.enumerated()), id: \.offset) { row, values in
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(Array(values.enumerated()), id: \.offset) { index, raw in
                            placedChip(raw, at: .init(row: row, index: index), count: values.count)
                        }
                        Color.clear.frame(width: 22, height: 26)
                    }.padding(8).frame(minWidth: 450, alignment: .leading)
                }
                .frame(height: 52).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4])))
                .contentShape(Rectangle()).dropDestination(for: String.self) { items, _ in drop(items, row: row) }
                .accessibilityLabel("自定义区域第 \(row + 1) 行")
            }
            HStack {
                Button(layout.lines.count == 1 ? "添加换行" : "移除换行") {
                    var next = layout
                    next.lines = layout.lines.count == 1 ? [layout.lines[0], []] : [Array(layout.lines.joined()).prefix(HUDLayout.maximumItemsPerLine).map { $0 }]
                    save(next)
                }
                Spacer()
                Label("拖到此处移除", systemImage: "trash").padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .dropDestination(for: String.self) { items, _ in
                        guard let p = position(items.first) else { return false }; save(layout.removing(at: p)); return true
                    }
            }
            ForEach(HUDMetric.groups, id: \.self) { group in
                Text(group).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 6)], alignment: .leading, spacing: 7) {
                    ForEach(HUDMetric.palette.filter { $0.group == group }) { metric in
                        Button { add(metric) } label: { chipLabel(metric.title, symbol: metric.symbol) }
                            .buttonStyle(.plain).draggable("metric:" + metric.rawValue)
                            .help(metric == .space ? "点击添加一个 8 pt 空格；右键已放置的空格可调整宽度。" : "点击添加或拖到右侧布局")
                    }
                }
            }
            Text("保留 CodexBar 的控件类型：百分比/额度栏、节奏、重置窗口、预计用尽、费用、空格/分隔点和条件显示。— 表示所选 Codex/网关来源不提供该数据或数据不足；不会为控件新增其他供应商。节奏及预计用尽是窗口内平均速度估算，不代表保证。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("右侧自定义布局") }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("布局预览 · 合成数据").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 9) {
                HUDRuntimeStatus(isRunning: true, compact: true)
                    .frame(width: HUDRuntimeStatus.reservedWidth, alignment: .leading)
                HUDMetricStrip(layout: layout, data: HUDEntityData(primary: 46, weekly: 79,
                    resetsAt: Date().addingTimeInterval(3600), balance: "12.34 credits", todayTokens: "473.7M",
                    costToday: "≈1.20 USD", cost30d: "≈12.30 USD"), remaining: preferences.value.showRemaining, menuBar: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).frame(height: 22)
                .background(Color.black.opacity(preferences.value.normalized.hudOpacity), in: RoundedRectangle(cornerRadius: CGFloat(preferences.value.cornerRadius), style: .continuous))
            HStack {
                Label("固定运行状态", systemImage: "lock.fill").font(.caption)
                Spacer(); Text("右侧为自定义内容").font(.caption)
            }.foregroundStyle(.secondary)
        }
    }
    private var bindableSources: [HUDBindableSource] {
        var values: [HUDBindableSource] = [.init(id: "local", label: "本机 Codex"), .init(id: "legacy", label: "旧版自动来源")]
        values += accounts.accounts.map { .init(id: $0.hudID, label: "Codex · " + $0.label) }
        values += remote.snapshot.accounts.map { .init(id: "remote:\($0.id)", label: "网关 · " + $0.displayName) }
        values += newAPI.snapshot.accounts.map { .init(id: "newapi:\($0.id)", label: "NewAPI · " + $0.displayName) }
        values += subAPI.snapshot.accounts.map { .init(id: "subapi:\($0.id)", label: "Sub2API · " + $0.displayName) }
        return values
    }
    private func sourceLabel(_ id: String) -> String {
        bindableSources.first(where: { $0.id == id })?.label ?? "已移除的数据源"
    }
    private var scopeHelp: String {
        if scope == "all" { return "默认布局：当前数据源没有更具体的布局时使用。多账号混排最适合在这里编辑。" }
        if scope == "local" { return "本机 Codex 独立布局：当前数据源为本机 Codex 时优先于默认布局。" }
        if scope == "codex" { return "Codex 类型默认：远程 Codex 账号没有账号专属布局时使用。" }
        if scope == "gateway" { return "网关类型默认：当前数据源为任意网关账号、且没有该账号专属布局时使用。" }
        if scope == "newapi:" { return "NewAPI 类型默认：当前数据源为任意 NewAPI 账号、且没有该账号专属布局时使用。" }
        if scope == "subapi:" { return "Sub2API 类型默认：当前数据源为任意 Sub2API 账号、且没有该账号专属布局时使用。" }
        return "账号专属布局：仅当当前数据源为「\(sourceLabel(scope))」时优先使用。"
    }
    private func boundPreset(_ preset: HUDLayout) -> HUDLayout {
        var next = preset.normalized
        for row in next.lines.indices {
            for index in next.lines[row].indices {
                next = next.settingSource(preferences.value.sourceID, at: .init(row: row, index: index))
            }
        }
        return next.normalized
    }
    private func resetAppearanceDefaults() {
        preferences.value.mode = .automatic
        preferences.value.maximumWidth = 220
        preferences.value.horizontalPosition = 0.5
        preferences.value.hudOpacity = 0.90
        preferences.value.panelOpacity = 0.90
        preferences.value.cornerRadius = 10
        preferences.value.animation = .anchoredReveal
        notchDisplaySize.wrappedValue = .standard
        notchAdjustment.wrappedValue = 0
        pulseEnabled.wrappedValue = true
    }

    private func add(_ metric: HUDMetric) {
        if metric == .conditional { ruleDraft = .init() }
        else { save(layout.inserting(metric, row: layout.lines.count - 1, sourceID: preferences.value.sourceID)) }
    }
    private func chipLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 11)).lineLimit(2)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
    }
    private func placedChip(_ raw: String, at p: HUDLayoutPosition, count: Int) -> some View {
        let metric = HUDMetric.parse(raw) ?? .hidden
        let id = HUDLayoutToken.conditionalID(raw) ?? ""
        let baseTitle = metric == .space ? "空格 \(HUDLayout.spaceWidth(raw)) pt" : metric == .conditional ? layout.conditionals[id]?.name ?? "条件" : metric.title
        let title = HUDLayoutToken.sourceID(raw).map { baseTitle + " · " + sourceLabel($0) } ?? baseTitle
        return Button { save(layout.removing(at: p)) } label: { chipLabel(title, symbol: metric.symbol) }
            .buttonStyle(.plain).draggable("hud-slot:\(p.row):\(p.index)")
            .contextMenu {
                if ![HUDMetric.space, .separatorDot, .hidden].contains(metric) {
                    Menu("绑定数据源") {
                        Button("解除绑定（跟随当前数据源）") { save(layout.settingSource(nil, at: p)) }
                        Divider()
                        ForEach(bindableSources) { source in
                            Button(source.label) { save(layout.settingSource(source.id, at: p)) }
                        }
                    }
                }
                if metric == .space {
                    ForEach([4, 8, 12, 16, 24, 32, 48], id: \.self) { width in
                        Button("空格宽度 \(width) pt") { save(layout.settingSpace(width, at: p)) }
                    }
                }
                if metric == .conditional, let rule = layout.conditionals[id] {
                    Button("编辑条件") { ruleDraft = .init(id: id, rule: rule, existing: true) }
                }
                Button("左移") { save(layout.moving(from: p, toRow: p.row, before: p.index - 1)) }.disabled(p.index == 0)
                Button("右移") { save(layout.moving(from: p, toRow: p.row, before: p.index + 2)) }.disabled(p.index == count - 1)
                Button(p.row == 0 ? "移到第二行" : "移到第一行") { save(layout.moving(from: p, toRow: 1 - p.row)) }
                Button("移除") { save(layout.removing(at: p)) }
            }
            .dropDestination(for: String.self) { items, _ in drop(items, row: p.row, before: p.index) }
            .accessibilityLabel(title + "，点击移除，拖动排序，右键设置")
    }
    private func position(_ payload: String?) -> HUDLayoutPosition? {
        guard let payload else { return nil }
        let parts = payload.split(separator: ":")
        guard parts.count == 3, parts[0] == "hud-slot", let r = Int(parts[1]), let i = Int(parts[2]) else { return nil }
        return .init(row: r, index: i)
    }
    private func drop(_ items: [String], row: Int, before: Int? = nil) -> Bool {
        if let p = position(items.first) { save(layout.moving(from: p, toRow: row, before: before)); return true }
        guard let raw = items.first, raw.hasPrefix("metric:"), let metric = HUDMetric(rawValue: String(raw.dropFirst(7))), metric != .state else { return false }
        if metric == .conditional { ruleDraft = .init(); return true }
        // 调色板中的空格是新增项；从布局拖动的空格是移动现有项，两者不会相互误判。
        if row < layout.lines.count && layout.lines[row].count >= HUDLayout.maximumItemsPerLine && !layout.lines[row].contains(metric.rawValue) { return false }
        var next = layout.inserting(metric, row: row, sourceID: preferences.value.sourceID)
        if let before, let last = next.lines[row].indices.last { next = next.moving(from: .init(row: row, index: last), toRow: row, before: before) }
        save(next); return true
    }
}
private struct HUDRuleDraft: Identifiable {
    var id = UUID().uuidString
    var rule = HUDConditional()
    var existing = false
}
private struct HUDConditionalEditor: View {
    @State private var rule: HUDConditional
    let onSave: (HUDConditional) -> Void
    let onCancel: () -> Void
    init(initial: HUDConditional, onSave: @escaping (HUDConditional) -> Void, onCancel: @escaping () -> Void) {
        _rule = State(initialValue: initial); self.onSave = onSave; self.onCancel = onCancel
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("条件控件").font(.headline)
            TextField("控件名称", text: $rule.name)
            Picker("条件组合", selection: $rule.matchAll) { Text("全部满足（AND）").tag(true); Text("任一满足（OR）").tag(false) }
            ForEach(rule.predicates.indices, id: \.self) { i in
                HStack {
                    Picker("指标", selection: $rule.predicates[i].metric) {
                        ForEach(HUDMetric.allCases.filter(\.isNumeric)) { Text($0.title).tag($0) }
                    }.frame(width: 150)
                    if rule.predicates[i].metric.isQuota {
                        Picker("方向", selection: $rule.predicates[i].remaining) { Text("已用").tag(false); Text("剩余").tag(true) }.frame(width: 85)
                    }
                    Picker("比较", selection: $rule.predicates[i].comparison) { ForEach(HUDComparison.allCases) { Text($0.symbol).tag($0) } }.frame(width: 62)
                    TextField("阈值", value: $rule.predicates[i].threshold, format: .number).frame(width: 64)
                    Text(rule.predicates[i].metric.isQuota || rule.predicates[i].metric.isPace ? "%" : rule.predicates[i].metric.group == "费用" ? "USD" : "小时").font(.caption)
                    Button { rule.predicates.remove(at: i) } label: { Image(systemName: "minus.circle") }.disabled(rule.predicates.count == 1)
                }
            }
            Button("添加条件") { rule.predicates.append(.init()) }.disabled(rule.predicates.count >= 8)
            branch("满足时显示", selection: $rule.thenMetric)
            branch("否则显示", selection: $rule.elseMetric)
            Text("阈值时间单位为小时；费用单位为 USD。数据缺失或过期时显示 —，不会误判为不满足。可选择“隐藏”让条件不成立时不占位置。")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消", action: onCancel); Button("保存") { onSave(rule.normalized) }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 640)
    }
    private func branch(_ title: String, selection: Binding<HUDMetric>) -> some View {
        Picker(title, selection: selection) {
            ForEach(HUDMetric.allCases.filter { $0 != .conditional && $0 != .state }) { Text($0.title).tag($0) }
        }
    }
}

private struct HUDBindableSource: Identifiable {
    let id: String
    let label: String
}
