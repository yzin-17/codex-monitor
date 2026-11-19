import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct TaskProgressButton: View {
    @ObservedObject var store: TaskProgressStore
    let threadID: String
    @State private var presented = false

    var body: some View {
        let summary = store.summary(for: threadID)
        Button { presented = true } label: {
            Label(summary.label, systemImage: "checklist")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(summary.stale || summary.partial ? MonitorTheme.warning : MonitorTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(summary.documentCount == 0 ? "为此会话绑定 Markdown 任务清单" : "任务文档进度；点击查看清单和管理绑定。清单完成与会话运行状态分别显示。")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            TaskProgressPanel(store: store, threadID: threadID) { presented = false }
                .preferredColorScheme(.dark)
        }
        .onAppear { store.retain(threadID: threadID) }
        .onDisappear { store.release(threadID: threadID) }
    }
}

private struct TaskProgressDraft: Identifiable {
    let id: UUID
    let path: String
    var scope: TaskProgressScope
    var document: TaskProgressTasks? = nil
    var selected: TaskProgressTasks? = nil
    var loading = true
    var error: String? = nil
    var generation = 0
}

@MainActor
struct TaskProgressPanel: View {
    @ObservedObject var store: TaskProgressStore
    let threadID: String
    let close: () -> Void
    @State private var managing = false
    @State private var drafts: [TaskProgressDraft] = []
    @State private var message: String?
    @State private var onlyIncomplete = false
    @State private var importCandidates: [TaskProgressImportCandidate] = []
    @State private var importSource = ""
    @State private var importNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(managing ? "绑定任务清单" : "任务进度").font(.system(size: 14, weight: .semibold))
                Spacer()
                if !managing {
                    Button("管理绑定") { beginManaging() }.controlSize(.small)
                    Button { store.refresh(threadID: threadID) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("重新读取任务文档")
                }
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭")
            }
            if let error = store.storageError { Text(error).font(.caption).foregroundStyle(MonitorTheme.warning).textSelection(.enabled) }
            if let message { Text(message).font(.caption).foregroundStyle(MonitorTheme.warning) }
            if managing { editor } else { progress }
        }
        .padding(16)
        .frame(width: 460)
        .foregroundStyle(MonitorTheme.textPrimary)
        .onAppear {
            store.retain(threadID: threadID)
            if store.bindings(for: threadID).isEmpty { beginManaging() }
        }
        .onDisappear { store.release(threadID: threadID) }
    }

    private var progress: some View {
        let summary = store.summary(for: threadID)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.label).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                if let fraction = summary.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 12)).foregroundStyle(MonitorTheme.textSecondary)
                }
                Spacer()
                Toggle("仅未完成", isOn: $onlyIncomplete).toggleStyle(.checkbox).font(.system(size: 11))
            }
            if let fraction = summary.fraction { ProgressView(value: fraction).tint(MonitorTheme.healthy) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.bindings(for: threadID)) { binding in
                        document(binding)
                        Divider()
                    }
                }
            }.frame(maxHeight: 390)
            Text("按任务文档的叶子复选框统计；文档完成不代表会话已经停止。")
                .font(.system(size: 10)).foregroundStyle(MonitorTheme.textTertiary)
        }
    }

    @ViewBuilder private func document(_ binding: TaskProgressBinding) -> some View {
        let snapshot = store.snapshots[binding.id]
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(binding.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(binding.path)
                Spacer()
                Button("打开文件") { store.openSource(binding) }.controlSize(.mini)
            }
            if binding.scope != .document { Text(binding.scope.label).font(.caption).foregroundStyle(MonitorTheme.textSecondary) }
            if let error = snapshot?.message {
                Text((snapshot?.cached == true ? "缓存 · " : "") + error).font(.caption).foregroundStyle(MonitorTheme.warning)
            }
            if let tasks = snapshot?.tasks {
                let items = tasks.items.filter { !onlyIncomplete || !$0.checked }
                if items.isEmpty {
                    Text(tasks.total == 0 ? "所选范围没有复选框任务" : "所有任务均已勾选完成")
                        .font(.system(size: 11)).foregroundStyle(MonitorTheme.textSecondary)
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.checked ? MonitorTheme.healthy : MonitorTheme.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 11)).textSelection(.enabled)
                            if !item.groups.isEmpty { Text(item.groups.joined(separator: " / ")).font(.system(size: 9)).foregroundStyle(MonitorTheme.textTertiary) }
                        }
                        Spacer(minLength: 4)
                        if let status = item.status { Text(status).font(.system(size: 9)).foregroundStyle(MonitorTheme.warning).fixedSize() }
                        if item.conflict { Image(systemName: "exclamationmark.triangle").foregroundStyle(MonitorTheme.warning).help("任务勾选状态与显式状态冲突") }
                    }
                }
                ForEach(tasks.diagnostics, id: \.self) { Text($0).font(.caption).foregroundStyle(MonitorTheme.warning) }
            } else if snapshot?.status == .loading || snapshot == nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择此会话的 Markdown 清单，可限定章节；最多 16 个文档。")
                .font(.system(size: 11)).foregroundStyle(MonitorTheme.textSecondary)
            HStack {
                Button("选择 Markdown 文件") { pickDocuments() }.controlSize(.small)
                Button("导入 Task Lens 绑定") { pickImport() }.controlSize(.small)
            }
            if !importCandidates.isEmpty { importSelection }
            if let importNote { Text(importNote).font(.caption).foregroundStyle(MonitorTheme.textSecondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if drafts.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.badge.plus").font(.system(size: 24))
                            Text("尚未选择任务清单").font(.system(size: 12))
                            Text("选择文件后可以预览完成数和章节范围。")
                                .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                    ForEach(drafts) { draft in
                        draftEditor(draft)
                        Divider()
                    }
                }
            }.frame(maxHeight: 350)
            HStack {
                Text("\(drafts.count)/16 个文档").font(.caption).foregroundStyle(MonitorTheme.textSecondary)
                Spacer()
                Button("取消") { managing = false; message = nil; if store.bindings(for: threadID).isEmpty { close() } }
                    .controlSize(.small)
                Button(drafts.isEmpty ? "解除全部绑定" : "保存绑定") { save() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(drafts.contains { $0.loading || $0.error != nil } || store.storageError != nil)
            }
        }
    }

    private var importSelection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("找到相同会话 ID 的绑定，请确认它属于当前 Codex 来源。")
                .font(.caption).foregroundStyle(MonitorTheme.warning)
            Picker("Task Lens 来源", selection: $importSource) {
                ForEach(importCandidates) { candidate in
                    Text("\(candidate.sourceID) · \(candidate.bindings.count) 个文档").tag(candidate.id)
                }
            }.font(.system(size: 11))
            Button("预览此来源的绑定") {
                guard let candidate = importCandidates.first(where: { $0.id == importSource }) else { return }
                drafts = candidate.bindings.map { .init(id: $0.id, path: $0.path, scope: $0.scope) }
                importNote = "导入自 \(candidate.sourceID)。保存后替换本会话的绑定，由 Monitor 独立维护。"
                importCandidates = []
                for draft in drafts { loadPreview(id: draft.id) }
            }.controlSize(.small)
        }
    }

    @ViewBuilder private func draftEditor(_ draft: TaskProgressDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(URL(fileURLWithPath: draft.path).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).help(draft.path)
                Spacer()
                Button { drafts.removeAll { $0.id == draft.id } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain).help("移除此绑定")
            }
            Text(draft.path).font(.system(size: 9)).foregroundStyle(MonitorTheme.textTertiary).lineLimit(1).truncationMode(.middle)
            if let parsed = draft.document {
                Picker("范围", selection: Binding<TaskProgressScope>(get: {
                    drafts.first(where: { $0.id == draft.id })?.scope ?? .document
                }, set: { scope in
                    guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
                    drafts[index].scope = scope
                    loadPreview(id: draft.id)
                })) {
                    Text("整篇文档").tag(TaskProgressScope.document)
                    ForEach(parsed.sections) { section in Text(section.scope.label).tag(section.scope) }
                }.font(.system(size: 11))
            }
            if draft.loading { ProgressView().controlSize(.small) }
            else if let error = draft.error { Text(error).font(.caption).foregroundStyle(MonitorTheme.warning) }
            else if let tasks = draft.selected {
                Text("已完成 \(tasks.completed) / \(tasks.total)").font(.system(size: 11)).monospacedDigit()
                ForEach(tasks.items.prefix(3)) { item in
                    Label(item.title, systemImage: item.checked ? "checkmark.circle" : "circle")
                        .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary).lineLimit(1)
                }
                if tasks.total > 3 { Text("另有 \(tasks.total - 3) 项，保存后可查看完整清单").font(.system(size: 9)).foregroundStyle(MonitorTheme.textTertiary) }
            }
        }
    }

    private func beginManaging() {
        message = nil; importNote = nil; importCandidates = []
        drafts = store.bindings(for: threadID).map { .init(id: $0.id, path: $0.path, scope: $0.scope) }
        managing = true
        for draft in drafts { loadPreview(id: draft.id) }
    }

    private func pickDocuments() {
        let panel = NSOpenPanel()
        panel.title = "选择任务清单"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        guard panel.runModal() == .OK else { return }
        message = nil
        for url in panel.urls {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()) else {
                message = "请选择 Markdown 文档。"; continue
            }
            guard !drafts.contains(where: { $0.path == path }) else { continue }
            guard drafts.count < TaskProgressParser.maximumDocuments else { message = "每个会话最多绑定 16 个文档。"; break }
            let draft = TaskProgressDraft(id: UUID(), path: path, scope: .document)
            drafts.append(draft)
            loadPreview(id: draft.id)
        }
    }

    private func pickImport() {
        let panel = NSOpenPanel()
        panel.title = "选择 Task Lens 的 state.json"
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
            importCandidates = try TaskProgressImport.candidates(data: data, threadID: threadID)
            importSource = importCandidates.first?.id ?? ""
            message = importCandidates.isEmpty ? "未找到与当前会话 ID 完全匹配的绑定。可直接选择任务文件。" : nil
        } catch { message = error.localizedDescription }
    }

    private func loadPreview(id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].loading = true; drafts[index].error = nil; drafts[index].generation += 1
        let draft = drafts[index]
        Task { @MainActor in
            do {
                let document = try await store.preview(path: draft.path)
                guard let current = drafts.firstIndex(where: { $0.id == id }), drafts[current].generation == draft.generation else { return }
                drafts[current].document = document
                let selected = draft.scope == .document ? document : try await store.preview(path: draft.path, scope: draft.scope)
                guard let current = drafts.firstIndex(where: { $0.id == id }), drafts[current].generation == draft.generation else { return }
                drafts[current].selected = selected; drafts[current].loading = false
            } catch {
                guard let current = drafts.firstIndex(where: { $0.id == id }), drafts[current].generation == draft.generation else { return }
                drafts[current].error = error.localizedDescription; drafts[current].loading = false
            }
        }
    }

    private func save() {
        do {
            try store.replaceBindings(threadID: threadID, with: drafts.map { .init(id: $0.id, path: $0.path, scope: $0.scope) })
            managing = false; message = nil
            if drafts.isEmpty { close() }
        } catch { message = error.localizedDescription }
    }
}
