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
        Group { presentationSection; sourceSection; layoutSection }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                hasNotch = (NSScreen.main?.safeAreaInsets.top ?? 0) > 0
            }
            .sheet(item: $ruleDraft) { draft in
                HUDConditionalEditor(initial: draft.rule, onSave: { rule in
                    var next = layout
                    if draft.existing { next.conditionals[draft.id] = rule.normalized; save(next) }
                    else { save(next.addingConditional(rule, id: draft.id)) }
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
                Text("覆盖菜单栏的浮窗，无刘海占位；高度不超过菜单栏。左侧运行状态固定保留，右侧空间不足时仅裁剪自定义内容。")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("浮窗最大宽度：\(Int(preferences.value.maximumWidth)) pt", value: $preferences.value.maximumWidth, in: 90...360, step: 10)
                HStack { Text("浮窗横向位置"); Slider(value: $preferences.value.horizontalPosition, in: 0...1) }
            } else {
                Picker("刘海两侧布局", selection: notchDisplaySize) {
                    ForEach(NotchDisplaySize.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Stepper("物理刘海微调：\(Int(notchAdjustment.wrappedValue)) pt", value: notchAdjustment,
                        in: -NotchPointAdjustment(IslandMetrics.notchAdjustmentLimit)...NotchPointAdjustment(IslandMetrics.notchAdjustmentLimit), step: 1)
                Text("物理遮挡区自动识别；仅在识别偏差时微调。左侧保留状态，右侧按自定义内容分配空间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack { Text("HUD 背景浓度"); Slider(value: $preferences.value.hudOpacity, in: 0...1); Text("\(Int(preferences.value.hudOpacity * 100))%") }
            HStack { Text("下拉面板背景浓度"); Slider(value: $preferences.value.panelOpacity, in: 0.35...1); Text("\(Int(preferences.value.panelOpacity * 100))%") }
            Button("恢复原版黑色背景") { preferences.value.hudOpacity = 0.985; preferences.value.panelOpacity = 0.985 }
            Picker("面板动画", selection: Binding(get: { preferences.value.animation }, set: { preferences.value.animation = $0 })) {
                ForEach(MonitorPanelAnimation.allCases) { Text($0.title).tag($0) }
            }
            Text("以上设置即时生效。面板维持 680 × 720 目标尺寸，原字号不缩放；背景不使用壁纸染色材质，降低浓度时仍会透出背后的实际内容。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("显示模式与刘海几何") }
    }
    private var sourceSection: some View {
        Section {
            Picker("右侧展示账户", selection: $preferences.value.sourceID) {
                Text("本机 Codex").tag("local")
                Text("沿用旧版来源选择 / 自动提醒").tag("legacy")
                ForEach(accounts.accounts) { Text("Codex · \($0.label)").tag($0.hudID) }
                ForEach(remote.snapshot.accounts) { Text("网关 · \($0.displayName)").tag("remote:\($0.id)") }
                ForEach(newAPI.snapshot.accounts) { Text("NewAPI · \($0.displayName)").tag("newapi:\($0.id)") }
                ForEach(subAPI.snapshot.accounts) { Text("Sub2API · \($0.displayName)").tag("subapi:\($0.id)") }
            }
            if preferences.value.sourceID == "legacy" {
                Picker("兼容来源", selection: legacySource) {
                    ForEach(NotchDisplaySource.allCases) { Text($0.label).tag($0) }
                }
            }
            Toggle("百分比显示剩余（关闭后显示已用）", isOn: $preferences.value.showRemaining)
            Text("账户选择只改变右侧指标；左侧状态灯与 RUN / IDLE 始终反映本机 Codex。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("右侧数据来源") }
    }
    private var layoutSection: some View {
        Section {
            HStack {
                Picker("布局作用域", selection: $scope) {
                    Text("所有来源（默认）").tag("all"); Text("Codex").tag("codex")
                    Text("网关账户").tag("gateway"); Text("NewAPI").tag("newapi:"); Text("Sub2API").tag("subapi:")
                }
                Menu("使用预设") {
                    Button("紧凑额度") { save(.compact) }; Button("用量和重置") { save(.detailed) }
                    Button("余额和费用") { save(.costs) }
                    Button("仅保留左侧运行状态") { save(.init(lines: [[]])) }
                    if scope != "all" { Button("恢复跟随默认") { preferences.value.providerLayouts[scope] = nil } }
                }
            }
            Text("左侧为固定区域，不参与拖动。下面只编辑右侧，每行最多 12 个控件、最多 2 行；空格和分隔点可以重复添加。")
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
                .background(Color.black.opacity(0.985), in: RoundedRectangle(cornerRadius: 5))
            HStack {
                Label("固定运行状态", systemImage: "lock.fill").font(.caption)
                Spacer(); Text("右侧为自定义内容").font(.caption)
            }.foregroundStyle(.secondary)
        }
    }
    private func add(_ metric: HUDMetric) {
        if metric == .conditional { ruleDraft = .init() }
        else { save(layout.inserting(metric, row: layout.lines.count - 1)) }
    }
    private func chipLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 11)).lineLimit(2)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
    }
    private func placedChip(_ raw: String, at p: HUDLayoutPosition, count: Int) -> some View {
        let metric = HUDMetric.parse(raw) ?? .hidden
        let id = String(raw.dropFirst(12))
        let title = metric == .space ? "空格 \(HUDLayout.spaceWidth(raw)) pt" : metric == .conditional ? layout.conditionals[id]?.name ?? "条件" : metric.title
        return Button { save(layout.removing(at: p)) } label: { chipLabel(title, symbol: metric.symbol) }
            .buttonStyle(.plain).draggable("hud-slot:\(p.row):\(p.index)")
            .contextMenu {
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
        var next = layout.inserting(metric, row: row)
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
