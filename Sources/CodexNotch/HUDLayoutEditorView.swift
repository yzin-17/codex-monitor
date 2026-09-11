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

    @State private var draftLayout: HUDLayout?
    @State private var ruleDraft: HUDRuleDraft?
    @State private var renamePresented = false
    @State private var renameText = ""
    @State private var hasNotch = (NSScreen.main?.safeAreaInsets.top ?? 0) > 0

    private var activeLayout: HUDLayout { preferences.value.activeLayout.normalized }
    private var layout: HUDLayout { (draftLayout ?? activeLayout).normalized }
    private var isDirty: Bool { draftLayout?.normalized != nil && draftLayout?.normalized != activeLayout }
    private var compactOverlay: Bool { preferences.value.mode.usesCompactOverlay(hasNotch: hasNotch) }

    var body: some View {
        Group { presentationSection; layoutSection }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                hasNotch = (NSScreen.main?.safeAreaInsets.top ?? 0) > 0
            }
            .sheet(item: $ruleDraft) { draft in
                HUDConditionalEditor(initial: draft.rule, onSave: { rule in
                    var next = layout
                    if draft.existing {
                        next.conditionals[draft.id] = rule.normalized
                        edit(next)
                    } else {
                        edit(next.addingConditional(rule, id: draft.id, sourceID: preferences.value.sourceID))
                    }
                    ruleDraft = nil
                }, onCancel: { ruleDraft = nil })
            }
            .alert("重命名布局", isPresented: $renamePresented) {
                TextField("布局名称", text: $renameText)
                Button("取消", role: .cancel) {}
                Button("保存") { renameActiveLayout() }
            } message: {
                Text("仅修改布局名称，不会改变控件的数据来源绑定。")
            }
    }

    private var presentationSection: some View {
        Section {
            Picker("屏幕外观", selection: $preferences.value.mode) {
                ForEach(MonitorDisplayMode.allCases) { Text($0.title).tag($0) }
            }
            if compactOverlay {
                Text("覆盖菜单栏的浮窗，无刘海占位；高度填满当前屏幕菜单栏。左侧运行状态固定保留，右侧按实际内容自适应宽度。")
                    .font(.caption).foregroundStyle(.secondary)
                appearanceSlider("HUD 横向位置", value: $preferences.value.horizontalPosition, range: 0...1)
            } else {
                Picker("刘海两侧布局", selection: notchDisplaySize) {
                    ForEach(NotchDisplaySize.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Stepper(
                    "物理刘海微调：\(Int(notchAdjustment.wrappedValue)) pt",
                    value: notchAdjustment,
                    in: -NotchPointAdjustment(IslandMetrics.notchAdjustmentLimit)...NotchPointAdjustment(IslandMetrics.notchAdjustmentLimit),
                    step: 1
                )
                Text("物理遮挡区自动识别；仅在识别偏差时微调。左侧保留状态，右侧按自定义内容分配空间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            appearanceSlider("HUD 背景透明度", value: $preferences.value.hudTransparency, range: 0...1)
            numberField(
                "HUD 圆角",
                value: Binding(get: { preferences.value.cornerRadius }, set: { preferences.value.cornerRadius = $0 }),
                range: 0...24,
                suffix: "pt"
            )
            appearanceSlider("下拉面板背景透明度", value: $preferences.value.panelTransparency, range: 0...0.65)
            Button("恢复外观默认设定", action: resetAppearanceDefaults)
                .help("恢复显示模式、刘海/浮窗几何、HUD/面板透明度和展开动画；不会改动布局或控件账户绑定。")
            Picker("面板动画", selection: Binding(
                get: { preferences.value.animation },
                set: { preferences.value.animation = $0 }
            )) {
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
            TextField(
                "",
                value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) }
                ),
                format: .number.precision(.fractionLength(0))
            )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 7)
            .frame(width: 72, height: 24)
            .background(
                Color.primary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 1)
            )
            Text(suffix).foregroundStyle(.secondary)
        }
    }

    private var layoutSection: some View {
        Section {
            layoutToolbar
            Text("选择“当前布局”会立即应用到 HUD；下面对控件排列或账号绑定的编辑先进入草稿，点“保存布局”后才替换当前 HUD。布局只负责排列，数据来源保存在每个数据控件自身；图标仅作标识，不绑定账号。")
                .font(.caption).foregroundStyle(.secondary)

            preview

            ForEach(Array(layout.lines.enumerated()), id: \.offset) { row, values in
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(Array(values.enumerated()), id: \.offset) { index, raw in
                            placedChip(raw, at: .init(row: row, index: index), count: values.count)
                        }
                        Color.clear.frame(width: 22, height: 26)
                    }
                    .padding(8)
                    .frame(minWidth: 450, alignment: .leading)
                }
                .frame(height: 58)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                )
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in drop(items, row: row) }
                .accessibilityLabel("自定义区域第 \(row + 1) 行")
            }

            HStack {
                Button(layout.lines.count == 1 ? "添加换行" : "移除换行") {
                    var next = layout
                    next.lines = layout.lines.count == 1
                        ? [layout.lines[0], []]
                        : [Array(layout.lines.joined()).prefix(HUDLayout.maximumItemsPerLine).map { $0 }]
                    edit(next)
                }
                Spacer()
                Label("拖到此处移除", systemImage: "trash")
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .dropDestination(for: String.self) { items, _ in
                        guard let p = position(items.first) else { return false }
                        edit(layout.removing(at: p))
                        return true
                    }
            }

            HStack {
                Spacer()
                Button("取消修改") { draftLayout = nil }.disabled(!isDirty)
                Button("保存布局", action: commitDraft)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
            }

            Picker("新增控件绑定到", selection: $preferences.value.sourceID) {
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
            Text("额度百分比固定显示剩余。这里仅决定接下来新增的数据控件绑定哪个账号；切换它不会切换 HUD 布局，也不会改变已经放置的控件。已放置的数据控件绑定会直接显示在控件名称下方，并可右键重新选择；图标不绑定账号。左侧 RUN / IDLE 始终只反映本机 Codex。")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(HUDMetric.groups, id: \.self) { group in
                Text(group).font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 6)], alignment: .leading, spacing: 7) {
                    ForEach(HUDMetric.palette.filter { $0.group == group }) { metric in
                        Button { add(metric) } label: { chipLabel(metric.title, metric: metric) }
                            .buttonStyle(.plain)
                            .draggable("metric:" + metric.rawValue)
                            .help(metric == .space
                                  ? "点击添加一个 8 pt 空格；右键已放置的空格可调整宽度。"
                                  : metric == .icon
                                  ? "点击添加完整 ChatGPT 图标；图标只作标识，不绑定数据源"
                                  : "点击添加或拖到布局；新控件会绑定到上方选中的数据源")
                    }
                }
            }

            Text("每行最多 12 个控件、最多 2 行。空格和分隔点可以重复添加。第一/第二/第三额度属于旧版同一数据源的顺序窗口，已从新建控件中移除；旧布局仍可兼容读取。节奏及预计用尽是窗口内平均速度估算；来源不提供数据时显示 —，不会自动改绑到其他账号。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("右侧自定义布局") }
    }

    private var layoutToolbar: some View {
        HStack(spacing: 8) {
            Picker("当前布局", selection: Binding(
                get: { preferences.value.activeLayoutID },
                set: { selectLayout($0) }
            )) {
                ForEach(preferences.value.layoutProfiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .frame(maxWidth: 250)

            Button {
                var config = preferences.value
                _ = config.addLayout(copyCurrent: false)
                preferences.value = config.normalized
                draftLayout = nil
            } label: { Label("新建", systemImage: "plus") }

            Button {
                var config = preferences.value
                _ = config.duplicateActiveLayout()
                preferences.value = config.normalized
                draftLayout = nil
            } label: { Label("复制", systemImage: "square.on.square") }

            Button("重命名") {
                renameText = preferences.value.activeProfile.name
                renamePresented = true
            }

            Button("删除", role: .destructive) {
                var config = preferences.value
                config.deleteActiveLayout()
                preferences.value = config.normalized
                draftLayout = nil
            }
            .disabled(preferences.value.layoutProfiles.count <= 1)

            Spacer(minLength: 4)

            Menu("使用预设") {
                Button("紧凑额度") { edit(boundPreset(.compact)) }
                Button("用量和重置") { edit(boundPreset(.detailed)) }
                Button("余额和费用") { edit(boundPreset(.costs)) }
                Button("仅保留左侧运行状态") { edit(.init(lines: [[]])) }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("布局预览 · 合成数据").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 9) {
                HUDRuntimeStatus(isRunning: true, compact: true)
                    .frame(width: HUDRuntimeStatus.reservedWidth, alignment: .leading)
                HUDMetricStrip(
                    layout: layout,
                    data: previewData,
                    remaining: true,
                    menuBar: true,
                    dataForRaw: { raw in previewData(for: HUDLayoutToken.sourceID(raw) ?? "local") }
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                Color.black.opacity(preferences.value.normalized.hudOpacity),
                in: RoundedRectangle(cornerRadius: CGFloat(preferences.value.cornerRadius), style: .continuous)
            )
            HStack {
                Label("固定运行状态", systemImage: "lock.fill").font(.caption)
                Spacer()
                Text("右侧控件各自绑定账号").font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var previewData: HUDEntityData {
        HUDEntityData(
            providerID: "local",
            provider: "Codex",
            account: "本机 Codex",
            state: "RUN",
            primary: 46,
            weekly: 79,
            resetsAt: Date().addingTimeInterval(3600),
            balance: "12.34 credits",
            todayTokens: "473.7M",
            costToday: "≈1.20 USD",
            cost30d: "≈12.30 USD"
        )
    }

    private func previewData(for source: String) -> HUDEntityData {
        var value = previewData
        value.account = sourceLabel(source)
        if source.hasPrefix("remote:") { value.providerID = "gateway"; value.provider = "网关" }
        else if source.hasPrefix("newapi:") { value.providerID = "newapi"; value.provider = "NewAPI" }
        else if source.hasPrefix("subapi:") { value.providerID = "subapi"; value.provider = "Sub2API" }
        else { value.providerID = "codex"; value.provider = "Codex" }
        return value
    }

    private var bindableSources: [HUDBindableSource] {
        var values: [HUDBindableSource] = [
            .init(id: "local", label: "本机 Codex"),
            .init(id: "legacy", label: "旧版自动来源（兼容）")
        ]
        values += accounts.accounts.map { .init(id: $0.hudID, label: "Codex · " + $0.label) }
        values += remote.snapshot.accounts.map { .init(id: "remote:\($0.id)", label: "网关 · " + $0.displayName) }
        values += newAPI.snapshot.accounts.map { .init(id: "newapi:\($0.id)", label: "NewAPI · " + $0.displayName) }
        values += subAPI.snapshot.accounts.map { .init(id: "subapi:\($0.id)", label: "Sub2API · " + $0.displayName) }
        return values
    }

    private func sourceLabel(_ id: String) -> String {
        bindableSources.first(where: { $0.id == id })?.label ?? "已移除的数据源"
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
        preferences.value.horizontalPosition = 0.5
        preferences.value.hudOpacity = 0.90
        preferences.value.panelOpacity = 0.90
        preferences.value.cornerRadius = 10
        preferences.value.animation = .anchoredReveal
        notchDisplaySize.wrappedValue = .standard
        notchAdjustment.wrappedValue = 0
        pulseEnabled.wrappedValue = true
    }

    private func selectLayout(_ id: String) {
        var config = preferences.value
        config.selectLayout(id)
        preferences.value = config.normalized
        draftLayout = nil
    }

    private func renameActiveLayout() {
        var config = preferences.value
        config.renameActiveLayout(renameText)
        preferences.value = config.normalized
    }

    private func commitDraft() {
        guard let draftLayout else { return }
        var config = preferences.value
        config.updateActiveLayout(draftLayout)
        preferences.value = config.normalized
        self.draftLayout = nil
    }

    private func edit(_ next: HUDLayout) {
        draftLayout = next.normalized
    }

    private func add(_ metric: HUDMetric) {
        if metric == .conditional {
            ruleDraft = .init()
        } else {
            edit(layout.inserting(metric, row: layout.lines.count - 1, sourceID: preferences.value.sourceID))
        }
    }

    @ViewBuilder
    private func chipLabel(_ title: String, metric: HUDMetric, source: String? = nil) -> some View {
        if metric == .icon {
            OpenAIKnotIcon(size: 16)
                .foregroundStyle(.primary)
                .frame(width: 36, height: 28, alignment: .center)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            HStack(spacing: 6) {
                Image(systemName: metric.symbol)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let source {
                        Text(source).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
    }

    private func placedChip(_ raw: String, at p: HUDLayoutPosition, count: Int) -> some View {
        let metric = HUDMetric.parse(raw) ?? .hidden
        let id = HUDLayoutToken.conditionalID(raw) ?? ""
        let baseTitle: String
        if metric == .space { baseTitle = "空格 \(HUDLayout.spaceWidth(raw)) pt" }
        else if metric == .conditional { baseTitle = layout.conditionals[id]?.name ?? "条件" }
        else { baseTitle = metric.title }
        let canBindSource = ![HUDMetric.icon, .space, .separatorDot, .hidden].contains(metric)
        let source = canBindSource ? sourceLabel(HUDLayoutToken.sourceID(raw) ?? "local") : nil

        return Button { edit(layout.removing(at: p)) } label: {
            chipLabel(baseTitle, metric: metric, source: source)
        }
        .buttonStyle(.plain)
        .draggable("hud-slot:\(p.row):\(p.index)")
        .contextMenu {
            if canBindSource {
                Menu("绑定数据源") {
                    ForEach(bindableSources) { source in
                        Button(source.label) { edit(layout.settingSource(source.id, at: p)) }
                    }
                }
            }
            if metric == .space {
                ForEach([4, 8, 12, 16, 24, 32, 48], id: \.self) { width in
                    Button("空格宽度 \(width) pt") { edit(layout.settingSpace(width, at: p)) }
                }
            }
            if metric == .conditional, let rule = layout.conditionals[id] {
                Button("编辑条件") { ruleDraft = .init(id: id, rule: rule, existing: true) }
            }
            Button("左移") { edit(layout.moving(from: p, toRow: p.row, before: p.index - 1)) }
                .disabled(p.index == 0)
            Button("右移") { edit(layout.moving(from: p, toRow: p.row, before: p.index + 2)) }
                .disabled(p.index == count - 1)
            Button(p.row == 0 ? "移到第二行" : "移到第一行") {
                edit(layout.moving(from: p, toRow: 1 - p.row))
            }
            Button("移除") { edit(layout.removing(at: p)) }
        }
        .dropDestination(for: String.self) { items, _ in drop(items, row: p.row, before: p.index) }
        .accessibilityLabel(metric == .icon
                            ? "ChatGPT 图标，点击移除，拖动排序"
                            : baseTitle + "，绑定 " + (source ?? "无数据来源") + "，点击移除，拖动排序，右键设置")
    }

    private func position(_ payload: String?) -> HUDLayoutPosition? {
        guard let payload else { return nil }
        let parts = payload.split(separator: ":")
        guard parts.count == 3, parts[0] == "hud-slot", let r = Int(parts[1]), let i = Int(parts[2]) else {
            return nil
        }
        return .init(row: r, index: i)
    }

    private func drop(_ items: [String], row: Int, before: Int? = nil) -> Bool {
        if let p = position(items.first) {
            edit(layout.moving(from: p, toRow: row, before: before))
            return true
        }
        guard let raw = items.first,
              raw.hasPrefix("metric:"),
              let metric = HUDMetric(rawValue: String(raw.dropFirst(7))),
              metric != .state else { return false }
        if metric == .conditional {
            ruleDraft = .init()
            return true
        }
        if row < layout.lines.count,
           layout.lines[row].count >= HUDLayout.maximumItemsPerLine,
           !layout.lines[row].contains(metric.rawValue) { return false }
        var next = layout.inserting(metric, row: row, sourceID: preferences.value.sourceID)
        if let before, let last = next.lines[row].indices.last {
            next = next.moving(from: .init(row: row, index: last), toRow: row, before: before)
        }
        edit(next)
        return true
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
        _rule = State(initialValue: initial)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("条件控件").font(.headline)
            TextField("控件名称", text: $rule.name)
            Picker("条件组合", selection: $rule.matchAll) {
                Text("全部满足（AND）").tag(true)
                Text("任一满足（OR）").tag(false)
            }
            ForEach(rule.predicates.indices, id: \.self) { i in
                HStack {
                    Picker("指标", selection: $rule.predicates[i].metric) {
                        ForEach(HUDMetric.allCases.filter { $0.isNumeric && !$0.isOrdinalLane }) { Text($0.title).tag($0) }
                    }
                    .frame(width: 150)
                    if rule.predicates[i].metric.isQuota {
                        Picker("方向", selection: $rule.predicates[i].remaining) {
                            Text("已用").tag(false)
                            Text("剩余").tag(true)
                        }
                        .frame(width: 85)
                    }
                    Picker("比较", selection: $rule.predicates[i].comparison) {
                        ForEach(HUDComparison.allCases) { Text($0.symbol).tag($0) }
                    }
                    .frame(width: 62)
                    TextField("阈值", value: $rule.predicates[i].threshold, format: .number).frame(width: 64)
                    Text(rule.predicates[i].metric.isQuota || rule.predicates[i].metric.isPace
                         ? "%"
                         : rule.predicates[i].metric.group == "费用" ? "USD" : "小时")
                        .font(.caption)
                    Button { rule.predicates.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .disabled(rule.predicates.count == 1)
                }
            }
            Button("添加条件") { rule.predicates.append(.init()) }.disabled(rule.predicates.count >= 8)
            branch("满足时显示", selection: $rule.thenMetric)
            branch("否则显示", selection: $rule.elseMetric)
            Text("阈值时间单位为小时；费用单位为 USD。数据缺失或过期时显示 —，不会误判为不满足。可选择“隐藏”让条件不成立时不占位置。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("保存") { onSave(rule.normalized) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func branch(_ title: String, selection: Binding<HUDMetric>) -> some View {
        Picker(title, selection: selection) {
            ForEach(HUDMetric.allCases.filter { $0 != .conditional && $0 != .state && !$0.isOrdinalLane }) {
                Text($0.title).tag($0)
            }
        }
    }
}

private struct HUDBindableSource: Identifiable {
    let id: String
    let label: String
}
