import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct TaskProgressButton: View {
    @ObservedObject var store: TaskProgressStore
    let threadID: String
    @StateObject private var presenter = TaskProgressPanelPresenter()

    var body: some View {
        let summary = store.summary(for: threadID)
        let scanning = store.discoveryState(for: threadID).isScanning
        Button { presenter.toggle(store: store, threadID: threadID) } label: {
            HStack(spacing: 5) {
                TaskProgressRing(fraction: summary.fraction, warning: summary.stale || summary.partial, size: 13)
                Text(summary.documentCount == 0 ? (scanning ? "扫描中" : "任务清单") : summary.label)
                    .font(.system(size: 10, weight: .medium)).monospacedDigit().lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(summary.stale || summary.partial ? MonitorTheme.warning : MonitorTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .background(TaskProgressAnchor(presenter: presenter))
        .help("查看任务文档进度、自动发现的清单与绑定范围")
        .accessibilityLabel("展开任务清单，" + (summary.documentCount == 0 ? "尚未发现清单" : summary.label))
        .onAppear { store.retain(threadID: threadID) }
        .onDisappear { store.release(threadID: threadID); presenter.closeIfUnpinned() }
    }
}

struct TaskProgressRing: View {
    let fraction: Double?
    var warning = false
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            Circle().stroke(MonitorTheme.progressTrack, lineWidth: 2)
            if let fraction {
                Circle().trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(warning ? MonitorTheme.warning : MonitorTheme.healthy,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

enum TaskProgressPanelTab: String, CaseIterable {
    case tasks = "清单", documents = "文档", settings = "设置"
}

@MainActor
struct TaskProgressPanel: View {
    @ObservedObject var store: TaskProgressStore
    let threadID: String
    @Binding var pinned: Bool
    let panelSize: NSSize
    let managesRetention: Bool
    let close: () -> Void
    @State private var selectedTab: TaskProgressPanelTab
    @StateObject private var documentDraft: TaskProgressDocumentDraftSession
    @State private var settingsMessage: String?

    init(store: TaskProgressStore, threadID: String, initialTab: TaskProgressPanelTab = .tasks,
         pinned: Binding<Bool> = .constant(false), panelSize: NSSize = NSSize(width: 460, height: 560),
         managesRetention: Bool = true, close: @escaping () -> Void) {
        self.store = store; self.threadID = threadID; self._pinned = pinned
        self.panelSize = panelSize; self.managesRetention = managesRetention; self.close = close
        _selectedTab = State(initialValue: initialTab)
        _documentDraft = StateObject(wrappedValue: TaskProgressDocumentDraftSession(store: store, threadID: threadID))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            if let error = store.storageError {
                warning(error).padding(.horizontal, 16).padding(.top, 10)
            }
            Group {
                switch selectedTab {
                case .tasks: checklist
                case .documents:
                    TaskProgressDocumentManager(store: store, session: documentDraft, threadID: threadID,
                        onFinished: { selectedTab = .tasks })
                case .settings: settings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(MonitorTheme.textPrimary)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.105, alpha: 1)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MonitorTheme.panelStroke, lineWidth: 0.7))
        .frame(width: panelSize.width, height: panelSize.height)
        .onAppear {
            if managesRetention { store.retainPanel(threadID: threadID) }
            store.discover(threadID: threadID)
            if selectedTab == .documents { documentDraft.loadIfNeeded() }
        }
        .onDisappear {
            documentDraft.stop()
            if managesRetention { store.releasePanel(threadID: threadID) }
        }
        .onChange(of: selectedTab) { _, tab in if tab == .documents { documentDraft.loadIfNeeded() } }
        .onChange(of: store.revision(for: threadID)) { _, _ in documentDraft.observeBindingRevision() }
        .onExitCommand(perform: close)
    }

    private var header: some View {
        let summary = store.summary(for: threadID)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).foregroundStyle(MonitorTheme.textTertiary)
                    Text("任务清单").font(.system(size: 14, weight: .semibold))
                    Text(summary.documentCount == 0 ? "尚未发现" : summary.label)
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(MonitorTheme.textSecondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24)
                .overlay(TaskProgressWindowDragHandle())
                Button { pinned.toggle() } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .foregroundStyle(pinned ? MonitorTheme.healthy : MonitorTheme.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).help(pinned ? "取消固定浮窗" : "固定浮窗，点击外部时保持显示")
                .accessibilityLabel(pinned ? "取消固定浮窗" : "固定浮窗")
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(MonitorTheme.textSecondary).help("关闭任务清单")
                    .accessibilityLabel("关闭任务清单")
            }
            HStack(spacing: 8) {
                Text(store.title(for: threadID)).lineLimit(1).truncationMode(.tail).help(store.title(for: threadID))
                Spacer(minLength: 4)
                Text(pinned ? "已固定 · 可拖动" : "本地只读").fixedSize()
            }.font(.system(size: 10)).foregroundStyle(MonitorTheme.textTertiary)
        }.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(TaskProgressPanelTab.allCases, id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    HStack(spacing: 4) {
                        Text(tab.rawValue)
                        if tab == .documents, !store.bindings(for: threadID).isEmpty {
                            Text("\(store.bindings(for: threadID).count)").font(.system(size: 10)).monospacedDigit()
                        }
                    }
                    .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .foregroundStyle(selectedTab == tab ? MonitorTheme.textPrimary : MonitorTheme.textSecondary)
                    .background(selectedTab == tab ? MonitorTheme.controlSelectedFill : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }.padding(.horizontal, 12).padding(.bottom, 10)
            .overlay(alignment: .bottom) { Divider() }
    }

    private var checklist: some View {
        let bindings = store.bindings(for: threadID)
        let scan = store.discoveryState(for: threadID)
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if bindings.isEmpty {
                        VStack(spacing: 12) {
                            if scan.isScanning { ProgressView().controlSize(.small) }
                            else { Image(systemName: "checklist").font(.system(size: 28)).foregroundStyle(MonitorTheme.textTertiary) }
                            Text(scan.isScanning ? "正在查找任务文档…" : "尚未发现可自动绑定的清单")
                                .font(.system(size: 13, weight: .semibold))
                            Text("会自动查找当前任务提到或更新的进度文档。也可以在“文档”中查看候选清单。")
                                .font(.system(size: 11)).foregroundStyle(MonitorTheme.textSecondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            Button("查看候选文档") { selectedTab = .documents }.controlSize(.small)
                        }.frame(maxWidth: .infinity).padding(.horizontal, 22).padding(.vertical, 38)
                        if let message = scan.message { warning(message) }
                    } else {
                        ForEach(bindings) { binding in
                            TaskProgressDocumentSection(store: store, binding: binding)
                            if binding.id != bindings.last?.id { Divider() }
                        }
                    }
                }.padding(16)
            }
            Divider()
            HStack {
                Text(bindings.isEmpty ? "进度来自 Markdown 任务清单" : "\(bindings.count) 份文档 · 自动同步")
                    .font(.system(size: 10)).foregroundStyle(MonitorTheme.textTertiary)
                Spacer()
                Button("管理文档") { selectedTab = .documents }.buttonStyle(.plain).font(.system(size: 11))
                Button { store.refresh(threadID: threadID); store.discover(threadID: threadID, force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.plain).help("重新读取文档并扫描任务线索")
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private var settings: some View {
        let value = store.settings(for: threadID)
        let ignored = store.ignoredPaths(for: threadID)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("发现与绑定").font(.system(size: 12, weight: .semibold))
                    Toggle("自动绑定明确关联的任务文档", isOn: Binding(get: { value.autoBind }, set: { enabled in
                        updateSettings(autoBind: enabled, scanWorkspace: value.scanWorkspace)
                    })).toggleStyle(.switch).controlSize(.small)
                    Text("任务中明确提到或更新的清单会尝试自动绑定；已移除的文档不会重新加入。")
                        .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)
                    Toggle("扫描项目内的常用任务目录", isOn: Binding(get: { value.scanWorkspace }, set: { enabled in
                        updateSettings(autoBind: value.autoBind, scanWorkspace: enabled)
                    })).toggleStyle(.switch).controlSize(.small)
                    Text("项目目录中找到的其他清单会列为候选，可在“文档”中选择。")
                        .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)
                }.font(.system(size: 11))
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("已忽略文档").font(.system(size: 12, weight: .semibold))
                        Text("\(ignored.count)").font(.system(size: 10)).foregroundStyle(MonitorTheme.textTertiary)
                    }
                    if ignored.isEmpty {
                        Text("没有已忽略的文档").font(.system(size: 11)).foregroundStyle(MonitorTheme.textSecondary)
                    }
                    ForEach(ignored, id: \.self) { path in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 11))
                                Text(path).font(.system(size: 9)).foregroundStyle(MonitorTheme.textTertiary)
                                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            }
                            Spacer(minLength: 4)
                            Button("恢复") {
                                do { try store.restoreIgnored(path: path, threadID: threadID); settingsMessage = nil }
                                catch { settingsMessage = error.localizedDescription }
                            }.controlSize(.small)
                        }
                    }
                }
                if let settingsMessage { warning(settingsMessage) }
            }.padding(16)
        }
    }

    private func updateSettings(autoBind: Bool, scanWorkspace: Bool) {
        do { try store.updateSettings(threadID: threadID, autoBind: autoBind, scanWorkspace: scanWorkspace); settingsMessage = nil }
        catch { settingsMessage = error.localizedDescription }
    }
    private func warning(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(MonitorTheme.warning).textSelection(.enabled)
    }
}

@MainActor
private struct TaskProgressDocumentSection: View {
    @ObservedObject var store: TaskProgressStore
    let binding: TaskProgressBinding
    var body: some View {
        let state = store.snapshots[binding.id]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text").foregroundStyle(MonitorTheme.textSecondary)
                Text(binding.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(binding.path)
                Spacer(minLength: 4)
                if let tasks = state?.tasks {
                    Text("\(tasks.completed)/\(tasks.total)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                Text(state?.status == .ready ? "已同步" : state?.cached == true ? "缓存" : "待读取")
                    .font(.system(size: 9)).foregroundStyle(state?.cached == true ? MonitorTheme.warning : MonitorTheme.textTertiary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(binding.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                HStack {
                    Text("范围：" + binding.scope.label).lineLimit(2)
                    Spacer(minLength: 4)
                    Text(binding.origin == .automatic ? "自动绑定" : "手动绑定").fixedSize()
                }
            }.font(.system(size: 9)).foregroundStyle(MonitorTheme.textTertiary)
            if let message = state?.message {
                Text((state?.cached == true ? "缓存 · " : "") + message)
                    .font(.system(size: 10)).foregroundStyle(MonitorTheme.warning)
            }
            if let tasks = state?.tasks {
                ForEach(tasks.diagnostics, id: \.self) { text in
                    Text(text).font(.system(size: 10)).foregroundStyle(MonitorTheme.warning)
                }
                TaskProgressItemGroup(title: "未完成", items: tasks.items.filter { !$0.checked }) { line in
                    store.openSource(binding, line: line)
                }
                TaskProgressItemGroup(title: "已完成", items: tasks.items.filter(\.checked)) { line in
                    store.openSource(binding, line: line)
                }
            } else if state?.status == .loading || state == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 12)
            }
        }
    }
}

private struct TaskProgressItemGroup: View {
    let title: String
    let items: [TaskProgressItem]
    let openSource: (Int) -> Void
    @State private var expanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { expanded.toggle() } label: {
                HStack {
                    Text("\(title) · \(items.count)").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: expanded ? "minus" : "plus").font(.system(size: 10))
                }.contentShape(Rectangle()).padding(.vertical, 5)
            }.buttonStyle(.plain).accessibilityLabel("\(title)，\(items.count) 项，" + (expanded ? "收起" : "展开"))
            if expanded {
                if items.isEmpty {
                    Text("暂无\(title)项").font(.system(size: 10)).foregroundStyle(MonitorTheme.textTertiary)
                        .padding(.vertical, 5)
                }
                ForEach(items) { item in TaskProgressItemRow(item: item, openSource: openSource) }
            }
        }
    }
}

private struct TaskProgressItemRow: View {
    let item: TaskProgressItem
    let openSource: (Int) -> Void
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.checked ? MonitorTheme.healthy : MonitorTheme.textTertiary)
                    VStack(alignment: .leading, spacing: 3) {
                        if let explicitID = item.explicitID {
                            Text(explicitID).font(.system(size: 9, design: .monospaced)).foregroundStyle(MonitorTheme.textTertiary)
                        }
                        Text(item.title).font(.system(size: 11)).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 3)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8)).foregroundStyle(MonitorTheme.textTertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if item.status != nil || item.conflict {
                HStack(spacing: 8) {
                    if let status = item.status { Text(Self.statusName(status)) }
                    if item.conflict { Label("文档状态冲突", systemImage: "exclamationmark.triangle") }
                }.font(.system(size: 9)).foregroundStyle(MonitorTheme.warning).padding(.leading, 21)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    if !item.groups.isEmpty { Text("分组：" + item.groups.joined(separator: " / ")) }
                    Text("源位置：第 \(item.line)" + ((item.endLine ?? item.line) > item.line ? "–\(item.endLine ?? item.line)" : "") + " 行")
                    if let status = item.status { Text("文档状态：" + Self.statusName(status)) }
                    if item.conflict { Text("文档状态与勾选状态冲突，当前计数保留文档的勾选结果。").foregroundStyle(MonitorTheme.warning) }
                    Text(item.rawText.isEmpty ? item.title : item.rawText)
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 5))
                    Button("打开第 \(item.line) 行的源文件") { openSource(item.line) }
                        .buttonStyle(.plain).foregroundStyle(MonitorTheme.radarBaseline)
                }.font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary).padding(.leading, 21)
            }
        }.padding(.vertical, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(MonitorTheme.separator).frame(height: 0.5) }
    }
    private static func statusName(_ status: String) -> String {
        switch status {
        case "in_progress": "进行中"
        case "validating": "验证中"
        case "blocked": "阻塞"
        default: status
        }
    }
}

struct TaskProgressDraftDocument: Identifiable {
    let id: UUID
    let path: String
    var scope: TaskProgressScope
    var origin: TaskProgressBindingOrigin = .manual
    var document: TaskProgressTasks? = nil
    var selected: TaskProgressTasks? = nil
    var loading = true
    var error: String? = nil
    var generation = 0
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var binding: TaskProgressBinding { .init(id: id, path: path, scope: scope, origin: origin) }
}

struct TaskProgressDraftChanges: Equatable {
    let added: Int
    let removed: Int
    let scopeChanged: Int
    var isDirty: Bool { added + removed + scopeChanged > 0 }
    var label: String {
        "新增 \(added) 份，移除 \(removed) 份" + (scopeChanged > 0 ? "，范围更改 \(scopeChanged) 份" : "")
    }
    static func compare(original: [TaskProgressBinding], current: [TaskProgressBinding]) -> Self {
        let previous = Dictionary(uniqueKeysWithValues: original.map { ($0.path, $0.scope) })
        let next = Dictionary(uniqueKeysWithValues: current.map { ($0.path, $0.scope) })
        return Self(added: next.keys.filter { previous[$0] == nil }.count,
                    removed: previous.keys.filter { next[$0] == nil }.count,
                    scopeChanged: next.filter { previous[$0.key] != nil && previous[$0.key] != $0.value }.count)
    }
}

@MainActor
final class TaskProgressDocumentDraftSession: ObservableObject {
    enum Page: String, CaseIterable { case add = "添加", manage = "管理" }
    @Published var rows: [TaskProgressDraftDocument] = []
    @Published var page = Page.add
    @Published var message: String?
    @Published var clearConsent = false
    @Published private(set) var original: [TaskProgressBinding] = []
    @Published private(set) var baseRevision = 0
    @Published private(set) var isSaving = false
    @Published private(set) var conflictingRevision = false
    private let store: TaskProgressStore
    private let threadID: String
    private var loaded = false
    private var epoch = UUID()
    private var workers: [UUID: Task<Void, Never>] = [:]
    var changes: TaskProgressDraftChanges { .compare(original: original, current: rows.map(\.binding)) }
    var busy: Bool { isSaving || rows.contains(where: \.loading) }
    var needsClearConsent: Bool { rows.isEmpty && !original.isEmpty }
    var canSave: Bool {
        changes.isDirty && !busy && !conflictingRevision && !rows.contains { $0.error != nil }
            && (!needsClearConsent || clearConsent) && store.storageError == nil
    }

    init(store: TaskProgressStore, threadID: String) { self.store = store; self.threadID = threadID }
    func loadIfNeeded() { if !loaded { reload() } }
    func reload() {
        stop(); epoch = UUID(); loaded = true
        original = store.bindings(for: threadID); baseRevision = store.revision(for: threadID)
        rows = original.map { .init(id: $0.id, path: $0.path, scope: $0.scope, origin: $0.origin) }
        message = nil; clearConsent = false; conflictingRevision = false
        for row in rows { preview(id: row.id) }
    }
    func observeBindingRevision() {
        guard loaded, store.revision(for: threadID) != baseRevision else { return }
        if changes.isDirty || isSaving {
            conflictingRevision = true
            message = "自动绑定或其他操作已更新清单。当前草稿已保留，请载入最新绑定后再编辑。"
        } else { reload() }
    }
    func stop() {
        epoch = UUID()
        workers.values.forEach { $0.cancel() }; workers.removeAll()
        isSaving = false
    }
    func cancel() { reload(); page = .add }
    func remove(id: UUID) {
        guard !isSaving else { return }
        workers.removeValue(forKey: id)?.cancel(); rows.removeAll { $0.id == id }; clearConsent = false
    }
    func clear() { guard !isSaving else { return }; stop(); rows.removeAll(); clearConsent = false }
    func setScope(_ scope: TaskProgressScope, id: UUID) {
        guard !isSaving, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].scope = scope; rows[index].origin = .manual
        preview(id: id)
    }
    func add(path: String, scope: TaskProgressScope = .document) {
        guard !isSaving else { return }
        loadIfNeeded()
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("file://"), let file = URL(string: expanded), file.isFileURL { url = file }
        else {
            guard expanded.hasPrefix("/") else { message = "请输入本地绝对路径。"; return }
            url = URL(fileURLWithPath: expanded)
        }
        let canonical = TaskProgressPath.canonical(url.path)
        guard ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()) else {
            message = "请选择 Markdown 文件。"; return
        }
        guard !rows.contains(where: { $0.path == canonical }) else { return }
        guard rows.count < TaskProgressParser.maximumDocuments else { message = "每个任务最多绑定 16 份文档。"; return }
        let row = TaskProgressDraftDocument(id: UUID(), path: canonical, scope: scope)
        rows.append(row); message = nil; clearConsent = false
        preview(id: row.id)
    }
    func importBindings(_ bindings: [TaskProgressBinding]) {
        guard !isSaving else { return }
        loadIfNeeded()
        stop(); epoch = UUID()
        rows = bindings.map { .init(id: $0.id, path: $0.path, scope: $0.scope) }
        clearConsent = false; message = "已载入导入预览，确认后替换当前任务的绑定。"
        for row in rows { preview(id: row.id) }
    }
    func preview(id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        workers.removeValue(forKey: id)?.cancel()
        rows[index].loading = true; rows[index].error = nil; rows[index].generation += 1
        let row = rows[index], currentEpoch = epoch
        workers[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let document = try await store.preview(path: row.path)
                let selected = row.scope == .document ? document : try await store.preview(path: row.path, scope: row.scope)
                guard !Task.isCancelled, epoch == currentEpoch,
                      let current = rows.firstIndex(where: { $0.id == id }), rows[current].generation == row.generation else { return }
                rows[current].document = document; rows[current].selected = selected; rows[current].loading = false
                if selected.total == 0 && !original.contains(where: { $0.path == row.path }) {
                    rows[current].error = "所选范围没有任务清单，请更换文档或章节。"
                }
            } catch {
                guard !Task.isCancelled, epoch == currentEpoch,
                      let current = rows.firstIndex(where: { $0.id == id }), rows[current].generation == row.generation else { return }
                rows[current].error = error.localizedDescription; rows[current].loading = false
            }
            workers.removeValue(forKey: id)
        }
    }
    func save(onSaved: @escaping () -> Void) {
        guard canSave else { return }
        isSaving = true; message = nil
        let requestedRows = rows, currentEpoch = epoch, expectedRevision = baseRevision
        let workerID = UUID()
        workers[workerID] = Task { [weak self] in
            guard let self else { return }
            defer { if epoch == currentEpoch { isSaving = false }; workers.removeValue(forKey: workerID) }
            do {
                var changed = false
                for row in requestedRows {
                    let document = try await store.preview(path: row.path)
                    let selected = row.scope == .document ? document : try await store.preview(path: row.path, scope: row.scope)
                    guard !Task.isCancelled, epoch == currentEpoch else { return }
                    if row.selected != selected || row.document?.sections != document.sections {
                        changed = true
                        if let index = rows.firstIndex(where: { $0.id == row.id }) {
                            rows[index].document = document; rows[index].selected = selected
                            if selected.total == 0 && !original.contains(where: { $0.path == row.path }) {
                                rows[index].error = "所选范围没有任务清单，请更换文档或章节。"
                            }
                        }
                    }
                }
                guard !Task.isCancelled, epoch == currentEpoch else { return }
                if changed { message = "文档在预览后发生变化，已刷新计数和范围，请核对后再次确认。"; return }
                try store.replaceBindings(threadID: threadID, with: requestedRows.map(\.binding), expectedRevision: expectedRevision)
                loaded = false; isSaving = false; onSaved()
            } catch {
                guard !Task.isCancelled, epoch == currentEpoch else { return }
                message = error.localizedDescription
                if store.revision(for: threadID) != baseRevision { conflictingRevision = true }
            }
        }
    }
}

@MainActor
private struct TaskProgressDocumentManager: View {
    @ObservedObject var store: TaskProgressStore
    @ObservedObject var session: TaskProgressDocumentDraftSession
    let threadID: String
    let onFinished: () -> Void
    @State private var pastedPaths = ""
    @State private var directoryMode = false
    @State private var importCandidates: [TaskProgressImportCandidate] = []
    @State private var importSource = ""
    @State private var confirmDiscard = false
    @State private var requestedRow: UUID?
    @State private var scrollRequest = UUID()

    var body: some View {
        VStack(spacing: 0) {
            selectedSummary
            ZStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        candidates
                        manualAdd
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                }
                .opacity(session.page == .add ? 1 : 0)
                .allowsHitTesting(session.page == .add)
                .accessibilityHidden(session.page != .add)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if session.rows.isEmpty {
                                Text("尚未选择文档，请返回添加。")
                                    .font(.system(size: 11)).foregroundStyle(MonitorTheme.textSecondary).padding(.vertical, 18)
                            }
                            ForEach(session.rows) { row in
                                draftRow(row).id(row.id)
                                if row.id != session.rows.last?.id { Divider() }
                            }
                        }.padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .onChange(of: scrollRequest) { _, _ in
                        if let requestedRow { proxy.scrollTo(requestedRow, anchor: .top) }
                    }
                }
                .opacity(session.page == .manage ? 1 : 0)
                .allowsHitTesting(session.page == .manage)
                .accessibilityHidden(session.page != .manage)
            }
            footer
        }
        .onAppear { session.loadIfNeeded(); store.discover(threadID: threadID) }
        .confirmationDialog("舍弃当前草稿并载入最新绑定？", isPresented: $confirmDiscard) {
            Button("舍弃草稿并载入") { session.reload() }
            Button("保留草稿", role: .cancel) {}
        }
    }

    private var selectedSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("已选 \(session.rows.count) 份").font(.system(size: 12, weight: .semibold))
                Text(session.changes.isDirty ? "有未确认更改" : session.rows.isEmpty ? "尚未添加" : "已绑定")
                    .font(.system(size: 9)).foregroundStyle(MonitorTheme.textTertiary)
                Spacer(minLength: 4)
                Button(session.page == .add ? "管理 ›" : "‹ 返回添加") {
                    session.page = session.page == .add ? .manage : .add
                }.buttonStyle(.plain).font(.system(size: 11))
            }
            HStack(spacing: 6) {
                ForEach(Array(session.rows.prefix(2))) { row in
                    HStack(spacing: 5) {
                        Button(row.name) { reveal(row.id) }
                            .buttonStyle(.plain).lineLimit(1).help(row.path)
                        Button { session.remove(id: row.id) } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                            .buttonStyle(.plain).disabled(session.isSaving).help("移出待确认清单")
                            .accessibilityLabel("移除已选 " + row.name)
                    }.font(.system(size: 10)).padding(.horizontal, 7).padding(.vertical, 5)
                        .background(MonitorTheme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                }
                if session.rows.count > 2 {
                    Button("+\(session.rows.count - 2)") { reveal(session.rows[2].id) }
                        .buttonStyle(.plain).font(.system(size: 10))
                }
                if session.rows.isEmpty {
                    Text("添加后在这里查看，确认后应用").font(.system(size: 10)).foregroundStyle(MonitorTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12).overlay(alignment: .bottom) { Divider() }
    }

    private var candidates: some View {
        let scan = store.discoveryState(for: threadID)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("可添加文档").font(.system(size: 12, weight: .semibold))
                Spacer()
                if scan.isScanning { ProgressView().controlSize(.mini) }
                Button(scan.isScanning ? "扫描中…" : "重新扫描") { store.discover(threadID: threadID, force: true) }
                    .buttonStyle(.plain).font(.system(size: 10)).disabled(scan.isScanning)
            }
            if let message = scan.message { notice(message) }
            if scan.hasMore { notice("还有文档待扫描，可继续扫描或选择更具体的目录。") }
            if scan.candidates.isEmpty && !scan.isScanning {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前任务还没有找到可添加的清单").font(.system(size: 11))
                    Text("可以扫描项目目录，或在下方选择文件、粘贴路径。")
                        .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)
                    Button("选择目录扫描…") { pickDirectory() }.controlSize(.small)
                }.padding(.vertical, 8)
            }
            ForEach(scan.candidates) { candidate in candidateRow(candidate) }
        }
    }

    private func candidateRow(_ candidate: TaskProgressCandidate) -> some View {
        let selected = session.rows.contains { $0.path == candidate.path }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(candidate.name).font(.system(size: 11, weight: .medium)).lineLimit(1).help(candidate.path)
                Spacer(minLength: 4)
                Text(candidate.tasks.map { "\($0.completed)/\($0.total)" } ?? "—")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(MonitorTheme.textSecondary)
                Button(selected ? "✓ 已选" : "添加") { session.add(path: candidate.path, scope: candidate.suggestedScope) }
                    .controlSize(.small).disabled(selected || !candidate.canBind || session.isSaving)
            }
            Text(candidate.path).font(.system(size: 9)).foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            HStack(alignment: .top, spacing: 6) {
                Text(candidate.reason).font(.system(size: 9)).foregroundStyle(MonitorTheme.textSecondary)
                Spacer(minLength: 2)
                if !selected {
                    Button("忽略") {
                        do { try store.ignoreCandidate(path: candidate.path, threadID: threadID) }
                        catch { session.message = error.localizedDescription }
                    }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(MonitorTheme.textTertiary)
                }
            }
            if let message = candidate.message { notice(message) }
        }.padding(.vertical, 7).overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private var manualAdd: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("手动添加").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("选择文件…") { pickFiles() }.controlSize(.small).disabled(session.isSaving)
                Button("选择目录…") { pickDirectory() }.controlSize(.small).disabled(session.isSaving)
            }
            Picker("路径类型", selection: $directoryMode) {
                Text("文件路径").tag(false)
                Text("目录路径").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            Text(directoryMode ? "目录的本地绝对路径" : "文件的本地绝对路径，每行一个")
                .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)
            TextEditor(text: $pastedPaths).font(.system(size: 10, design: .monospaced))
                .scrollContentBackground(.hidden).padding(6).frame(height: directoryMode ? 48 : 66)
                .background(MonitorTheme.controlFill, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(directoryMode ? "目录路径" : "文件路径")
            HStack {
                Button(directoryMode ? "查找文档" : "预览文件") {
                    if directoryMode {
                        let path = (pastedPaths.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
                        guard path.hasPrefix("/") else { session.message = "请输入目录的绝对路径。"; return }
                        Task { await store.scanDirectory(path: path, threadID: threadID) }
                    } else {
                        for path in pastedPaths.components(separatedBy: .newlines) where !path.trimmingCharacters(in: .whitespaces).isEmpty {
                            session.add(path: path)
                        }
                    }
                }.controlSize(.small).disabled(pastedPaths.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isSaving)
                Spacer()
                Button("导入 Task Lens…") { pickImport() }.buttonStyle(.plain).font(.system(size: 10)).disabled(session.isSaving)
            }
            if !importCandidates.isEmpty { importSelection }
        }.padding(.top, 4)
    }

    private var importSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            notice("找到相同任务 ID 的绑定，请选择对应的 Codex 来源。")
            Picker("Task Lens 来源", selection: $importSource) {
                ForEach(importCandidates) { candidate in
                    Text("\(candidate.sourceID) · \(candidate.bindings.count) 份").tag(candidate.id)
                }
            }.font(.system(size: 10))
            Button("预览该来源的绑定") {
                guard let candidate = importCandidates.first(where: { $0.id == importSource }) else { return }
                session.importBindings(candidate.bindings); importCandidates = []; session.page = .manage
            }.controlSize(.small)
        }
    }

    private func draftRow(_ row: TaskProgressDraftDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1).help(row.path)
                Spacer(minLength: 4)
                if let selected = row.selected {
                    Text("\(selected.completed)/\(selected.total)").font(.system(size: 10)).monospacedDigit()
                }
                Button { session.remove(id: row.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.system(size: 10)).disabled(session.isSaving).help("移除文档")
            }
            Text(row.path).font(.system(size: 9)).foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            HStack(spacing: 8) {
                Text("范围").font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)
                TaskProgressScopePicker(value: row.scope, sections: row.document?.sections ?? [], disabled: row.document == nil || session.isSaving) {
                    session.setScope($0, id: row.id)
                }
                Spacer(minLength: 0)
                Button("重新预览") { session.preview(id: row.id) }.buttonStyle(.plain).font(.system(size: 10)).disabled(row.loading || session.isSaving)
            }
            if row.loading { ProgressView().controlSize(.small) }
            if let error = row.error { notice(error) }
            else if let tasks = row.selected {
                ForEach(tasks.items.prefix(3)) { item in
                    Label(item.title, systemImage: item.checked ? "checkmark.circle" : "circle")
                        .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary).lineLimit(2)
                }
                if tasks.total > 3 {
                    Text("另有 \(tasks.total - 3) 项").font(.system(size: 9)).foregroundStyle(MonitorTheme.textTertiary)
                }
            }
        }.padding(.vertical, 4)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = session.message { notice(message) }
            if session.conflictingRevision {
                Button("舍弃草稿并载入最新绑定") { confirmDiscard = true }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(MonitorTheme.radarBaseline)
            }
            if session.needsClearConsent {
                Toggle("确认解除此任务的全部文档绑定", isOn: $session.clearConsent)
                    .toggleStyle(.checkbox).font(.system(size: 10))
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.changes.isDirty ? session.changes.label : "尚无更改")
                        .font(.system(size: 9)).foregroundStyle(MonitorTheme.textSecondary)
                    if !session.rows.isEmpty {
                        Button("清空已选") { session.clear() }.buttonStyle(.plain)
                            .font(.system(size: 9)).foregroundStyle(MonitorTheme.textTertiary).disabled(session.isSaving)
                    }
                }
                Spacer(minLength: 2)
                Button("取消") { session.cancel(); onFinished() }.controlSize(.small).disabled(session.isSaving)
                Button(session.isSaving ? "正在确认…" : session.needsClearConsent ? "确认解除" : "确认更改") {
                    session.save(onSaved: onFinished)
                }.buttonStyle(.borderedProminent).controlSize(.small).disabled(!session.canSave)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10).overlay(alignment: .top) { Divider() }
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(MonitorTheme.warning).fixedSize(horizontal: false, vertical: true)
    }
    private func reveal(_ id: UUID) {
        requestedRow = id; session.page = .manage; scrollRequest = UUID()
    }
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择任务文档"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { session.add(path: url.path) }
    }
    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择任务文档所在目录"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        if let workspace = store.discoveryState(for: threadID).workspacePath { panel.directoryURL = URL(fileURLWithPath: workspace) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.scanDirectory(path: url.path, threadID: threadID) }
    }
    private func pickImport() {
        let panel = NSOpenPanel()
        panel.title = "选择 Task Lens 的 state.json"; panel.canChooseDirectories = false; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
            importCandidates = try TaskProgressImport.candidates(data: data, threadID: threadID)
            importSource = importCandidates.first?.id ?? ""
            session.message = importCandidates.isEmpty ? "没有找到当前任务 ID 的绑定。" : nil
        } catch { session.message = error.localizedDescription }
    }
}

private struct TaskProgressScopePicker: View {
    let value: TaskProgressScope
    let sections: [TaskProgressSection]
    let disabled: Bool
    let choose: (TaskProgressScope) -> Void
    @State private var presented = false
    @State private var query = ""
    @State private var active = 0
    @FocusState private var searchFocused: Bool
    private var options: [TaskProgressScope] {
        let all = [TaskProgressScope.document] + sections.map(\.scope)
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? all : all.filter { $0.label.localizedStandardContains(text) }
    }
    var body: some View {
        Button {
            query = ""; active = 0; presented = true
        } label: {
            HStack(spacing: 5) {
                Text(value.label).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }.font(.system(size: 10)).padding(.horizontal, 7).padding(.vertical, 5)
                .background(MonitorTheme.controlFill, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).disabled(disabled).help(value.label)
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("搜索章节…", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
                        .font(.system(size: 11))
                        .onSubmit { selectActive() }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(options.enumerated()), id: \.element) { index, scope in
                                    Button { choose(scope); presented = false } label: {
                                        HStack(alignment: .top, spacing: 7) {
                                            Image(systemName: scope == value ? "checkmark" : "circle").font(.system(size: 9))
                                                .opacity(scope == value ? 1 : 0)
                                            Text(scope.label).font(.system(size: 11)).multilineTextAlignment(.leading)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 0)
                                        }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(index == active ? MonitorTheme.controlSelectedFill : .clear,
                                                        in: RoundedRectangle(cornerRadius: 5))
                                    }.buttonStyle(.plain).id(index).onHover { inside in if inside { active = index } }
                                }
                                if options.isEmpty { Text("未找到匹配章节").font(.system(size: 11)).foregroundStyle(.secondary).padding(8) }
                            }
                        }.frame(maxHeight: 230)
                            .onChange(of: active) { _, value in proxy.scrollTo(value) }
                    }
                }.padding(10).frame(width: 330)
                    .onAppear { searchFocused = true }
                    .onChange(of: query) { _, _ in active = 0 }
                    .onMoveCommand { direction in
                        if direction == .down { active = min(max(0, options.count - 1), active + 1) }
                        if direction == .up { active = max(0, active - 1) }
                    }
                    .onExitCommand { presented = false }
                    .preferredColorScheme(.dark)
            }
    }
    private func selectActive() {
        guard options.indices.contains(active) else { return }
        choose(options[active]); presented = false
    }
}
