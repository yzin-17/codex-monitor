import AppKit
import Combine
import CryptoKit
import Darwin
import Dispatch
import Foundation

@MainActor
final class TaskProgressStore: ObservableObject {
    @Published private(set) var bindingsByThread: [String: [TaskProgressBinding]] = [:]
    @Published private(set) var snapshots: [UUID: TaskProgressDocumentState] = [:]
    @Published private(set) var discoveryByThread: [String: TaskProgressScanState] = [:]
    @Published private(set) var ignoredByThread: [String: [String]] = [:]
    @Published private(set) var settingsByThread: [String: TaskProgressThreadSettings] = [:]
    @Published private(set) var storageError: String?
    let sourceID: String
    let storageURL: URL

    private struct StoredState: Codable {
        let version: Int
        let sourceID: String
        let threads: [String: [TaskProgressBinding]]
        var ignored: [String: [String]]? = nil
        var preferences: [String: TaskProgressThreadSettings]? = nil
        var revisions: [String: Int]? = nil
    }
    private let automatic: Bool
    private let reader: TaskProgressReader
    private let discovery: TaskProgressDiscoveryService
    private var presentationVisible = true
    private var visibleThreads: [String: Int] = [:]
    private var panelThreads: [String: Int] = [:]
    private var contexts: [String: CodexTask] = [:]
    private var revisions: [String: Int] = [:]
    private var extraHints: [String: [TaskProgressDiscoveryHint]] = [:]
    private var acceptedHints: [String: [TaskProgressDiscoveryHint]] = [:]
    private var scannedPaths: [String: Set<String>] = [:]
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var pollTimer: Timer?
    private var debounce: Task<Void, Never>?
    private var workers: [String: Task<Void, Never>] = [:]
    private var generations: [String: Int] = [:]
    private var scanWorkers: [String: Task<Void, Never>] = [:]
    private var scanGenerations: [String: Int] = [:]
    private var storageWritable = true
    private var stopped = false

    init(codexHome: String, automatic: Bool = true, storageDirectory: URL? = nil,
         reader: TaskProgressReader = TaskProgressReader(),
         discovery: TaskProgressDiscoveryService = TaskProgressDiscoveryService()) {
        sourceID = Self.canonical(codexHome)
        self.automatic = automatic
        self.reader = reader
        self.discovery = discovery
        let directory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexMonitor/task-progress", isDirectory: true)
        let digest = SHA256.hash(data: Data(sourceID.utf8)).map { String(format: "%02x", $0) }.joined()
        storageURL = directory.appendingPathComponent(digest + ".json")
        do {
            if FileManager.default.fileExists(atPath: storageURL.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: storageURL.path)
                guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4 * 1024 * 1024 else {
                    throw TaskProgressError.invalid("任务绑定存储超过大小限制。")
                }
                let state = try JSONDecoder().decode(StoredState.self, from: Data(contentsOf: storageURL))
                guard [1, 2].contains(state.version), state.sourceID == sourceID else {
                    throw TaskProgressError.invalid("任务绑定存储格式或数据来源不匹配。")
                }
                try Self.validateState(state)
                bindingsByThread = state.threads
                ignoredByThread = state.ignored ?? [:]
                settingsByThread = state.preferences ?? [:]
                revisions = state.revisions ?? [:]
            }
        } catch {
            storageWritable = false
            storageError = "绑定存储读取失败，原文件已保留：\(error.localizedDescription)"
        }
    }

    func bindings(for threadID: String) -> [TaskProgressBinding] { bindingsByThread[threadID] ?? [] }
    func summary(for threadID: String) -> TaskProgressSummary { .summarize(bindings: bindings(for: threadID), snapshots: snapshots) }
    func discoveryState(for threadID: String) -> TaskProgressScanState { discoveryByThread[threadID] ?? .init() }
    func settings(for threadID: String) -> TaskProgressThreadSettings { settingsByThread[threadID] ?? .init() }
    func ignoredPaths(for threadID: String) -> [String] { ignoredByThread[threadID] ?? [] }
    func revision(for threadID: String) -> Int { revisions[threadID] ?? 0 }
    func title(for threadID: String) -> String { contexts[threadID]?.title ?? "当前任务" }

    /// 复用任务加载时已经确定的日志路径，不再扫描整个 Codex 会话目录。
    func setTasks(_ tasks: [CodexTask]) {
        guard !stopped else { return }
        let previous = contexts
        contexts = tasks.reduce(into: [:]) { $0[$1.id] = $1 }
        updateObservation()
        guard automatic else { return }
        for task in tasks where task.status == .running && !task.isAutoReview && discoveryThreads.contains(task.id) {
            if previous[task.id]?.rolloutPath != task.rolloutPath || previous[task.id]?.updatedAt != task.updatedAt
                || discoveryByThread[task.id] == nil {
                discover(threadID: task.id)
            }
        }
        refreshMonitored()
    }

    func sessionFilesChanged() { scheduleRefresh() }

    func retain(threadID: String) {
        visibleThreads[threadID, default: 0] += 1
        if presentationVisible {
            refresh(threadID: threadID)
            if automatic, discoveryThreads.contains(threadID) { discover(threadID: threadID) }
        }
        updateObservation()
    }

    func release(threadID: String) {
        Self.decrement(&visibleThreads, threadID)
        updateObservation()
    }

    func retainPanel(threadID: String) {
        panelThreads[threadID, default: 0] += 1
        refresh(threadID: threadID)
        discover(threadID: threadID)
        updateObservation()
    }

    func releasePanel(threadID: String) {
        Self.decrement(&panelThreads, threadID)
        updateObservation()
    }

    // 主详情隐藏后，运行任务、已绑定任务和固定的清单面板继续更新。
    func setPresentationVisible(_ visible: Bool) {
        guard presentationVisible != visible else { return }
        presentationVisible = visible
        updateObservation()
        if visible { refreshMonitored() }
    }

    func replaceBindings(threadID: String, with bindings: [TaskProgressBinding], expectedRevision: Int? = nil) throws {
        if let expectedRevision, expectedRevision != revision(for: threadID) {
            throw TaskProgressError.invalid("任务文档已自动更新。请重新载入当前绑定后再保存，现有草稿已保留。")
        }
        let old = self.bindings(for: threadID)
        let normalized = bindings.map { binding -> TaskProgressBinding in
            let path = Self.canonical(binding.path)
            let existing = old.first { $0.path == path }
            let origin: TaskProgressBindingOrigin = existing?.origin == .automatic && binding.origin == .automatic
                && existing?.scope == binding.scope ? .automatic : .manual
            return .init(id: binding.id, path: path, scope: binding.scope, origin: origin)
        }
        var ignored = Set(ignoredPaths(for: threadID))
        ignored.formUnion(Set(old.map(\.path)).subtracting(normalized.map(\.path)))
        ignored.subtract(normalized.map(\.path))
        try commit(threadID: threadID, bindings: normalized, ignored: ignored.sorted())
    }

    func ignoreCandidate(path: String, threadID: String) throws {
        let canonical = Self.canonical(path)
        var ignored = Set(ignoredPaths(for: threadID)); ignored.insert(canonical)
        try commit(threadID: threadID, bindings: bindings(for: threadID).filter { $0.path != canonical }, ignored: ignored.sorted())
        discoveryByThread[threadID]?.candidates.removeAll { $0.path == canonical }
    }

    func restoreIgnored(path: String, threadID: String) throws {
        try commit(threadID: threadID, bindings: bindings(for: threadID),
                   ignored: ignoredPaths(for: threadID).filter { $0 != Self.canonical(path) })
        discover(threadID: threadID, force: true)
    }

    func updateSettings(threadID: String, autoBind: Bool, scanWorkspace: Bool) throws {
        var preferences = settingsByThread
        preferences[threadID] = .init(autoBind: autoBind, scanWorkspace: scanWorkspace)
        try persist(threads: bindingsByThread, ignored: ignoredByThread, preferences: preferences, revisions: revisions)
        settingsByThread = preferences
        discover(threadID: threadID, force: true)
    }

    func discover(threadID: String, force: Bool = false) {
        guard !stopped, !threadID.isEmpty else { return }
        if scanWorkers[threadID] != nil {
            guard force else { return }
            scanWorkers.removeValue(forKey: threadID)?.cancel()
        }
        if !force, let last = discoveryByThread[threadID]?.lastScannedAt, Date().timeIntervalSince(last) < 1 { return }
        let generation = (scanGenerations[threadID] ?? 0) + 1
        scanGenerations[threadID] = generation
        var state = discoveryState(for: threadID); state.isScanning = true
        discoveryByThread[threadID] = state
        let rollout = contexts[threadID]?.rolloutPath
        let workspace = state.workspacePath
        let service = discovery
        scanWorkers[threadID] = Task { [weak self] in
            // 每次最多推进 8 块，目录上限和超大日志都不会造成无限循环。
            for chunk in 0..<8 {
                guard let self, !Task.isCancelled, self.scanGenerations[threadID] == generation else { return }
                let result = await service.scan(threadID: threadID, rolloutPath: rollout,
                    workspacePath: workspace, includeWorkspace: self.settings(for: threadID).scanWorkspace,
                    force: force && chunk == 0)
                guard !Task.isCancelled, self.scanGenerations[threadID] == generation else { return }
                await self.accept(result, threadID: threadID, generation: generation)
                guard !Task.isCancelled, self.scanGenerations[threadID] == generation else { return }
                if !result.hasUnreadSessionRecords { break }
                try? await Task.sleep(for: .milliseconds(60))
            }
            guard let self, self.scanGenerations[threadID] == generation else { return }
            self.discoveryByThread[threadID]?.isScanning = false
            self.scanWorkers.removeValue(forKey: threadID)
            self.updateObservation()
        }
    }

    func discoverAndWait(threadID: String, force: Bool = false) async {
        discover(threadID: threadID, force: force)
        await scanWorkers[threadID]?.value
        await workers[threadID]?.value
    }

    func scanDirectory(path: String, threadID: String) async {
        let result = await discovery.scanDirectory(path: path)
        guard !stopped else { return }
        extraHints[threadID] = Self.mergeHints((extraHints[threadID] ?? []) + result.hints)
        var state = discoveryState(for: threadID)
        state.isScanning = true; discoveryByThread[threadID] = state
        let known = acceptedHints[threadID] ?? []
        let merged = TaskProgressDiscoveryResult(hints: Self.mergeHints(known + result.hints),
            workspacePath: state.workspacePath, message: result.message, hasMore: state.hasMore || result.hasMore)
        await accept(merged, threadID: threadID, generation: nil)
        discoveryByThread[threadID]?.isScanning = scanWorkers[threadID] != nil
        updateObservation()
    }

    private func accept(_ result: TaskProgressDiscoveryResult, threadID: String, generation: Int?) async {
        let hints = Self.mergeHints(result.hints + (extraHints[threadID] ?? []))
        let ignored = Set(ignoredPaths(for: threadID))
        let eligible = hints.filter { !ignored.contains(Self.canonical($0.path)) }
        let pending = Array(eligible.prefix(1_024))
        scannedPaths[threadID] = Set(pending.map { Self.canonical($0.path) })
        let reader = reader
        var candidates: [TaskProgressCandidate] = []
        // 有界并发读取；同一文件共用 reader 的版本与解析缓存。
        for start in stride(from: 0, to: pending.count, by: 4) {
            guard !Task.isCancelled, generation == nil || scanGenerations[threadID] == generation else { return }
            let batch = Array(pending[start..<min(start + 4, pending.count)])
            let parsed = await withTaskGroup(of: TaskProgressCandidate.self) { group in
                for hint in batch { group.addTask { await Self.candidate(hint, reader: reader) } }
                var values: [TaskProgressCandidate] = []
                for await value in group { values.append(value) }
                return values
            }
            candidates.append(contentsOf: parsed)
        }
        guard !stopped, !Task.isCancelled, generation == nil || scanGenerations[threadID] == generation else { return }
        acceptedHints[threadID] = pending
        let currentIgnored = Set(ignoredPaths(for: threadID))
        let positions = Dictionary(uniqueKeysWithValues: pending.enumerated().map { (Self.canonical($0.element.path), $0.offset) })
        candidates = candidates.filter { candidate in
            !currentIgnored.contains(candidate.path) &&
                (candidate.origins.contains(where: { $0 != .workspace }) || candidate.canBind)
        }.sorted { (positions[$0.path] ?? Int.max) < (positions[$1.path] ?? Int.max) }
        var state = discoveryState(for: threadID)
        state.candidates = candidates
        state.workspacePath = result.workspacePath ?? state.workspacePath
        state.lastScannedAt = Date(); state.message = result.message; state.hasMore = result.hasMore
        if eligible.count > pending.count {
            state.hasMore = true
            state.message = "候选文档超过 1024 份，请选择更小的任务目录继续查找。"
        }
        discoveryByThread[threadID] = state
        if settings(for: threadID).autoBind {
            var bindings = bindings(for: threadID)
            for candidate in candidates where candidate.canBind && candidate.origins.contains(where: { $0 == .written || $0 == .mentioned }) {
                if let index = bindings.firstIndex(where: { $0.path == candidate.path }) {
                    // 后续日志可能补充别的章节；自动范围跟随证据，手动范围始终优先。
                    if bindings[index].origin == .automatic, bindings[index].scope != candidate.suggestedScope {
                        bindings[index] = .init(id: bindings[index].id, path: candidate.path,
                                               scope: candidate.suggestedScope, origin: .automatic)
                    }
                    continue
                }
                guard bindings.count < TaskProgressParser.maximumDocuments else {
                    discoveryByThread[threadID]?.message = "已有 16 个绑定文档，其余关联文档保留在候选列表。"
                    break
                }
                bindings.append(.init(id: UUID(), path: candidate.path, scope: candidate.suggestedScope, origin: .automatic))
            }
            if bindings != self.bindings(for: threadID) {
                do { try commit(threadID: threadID, bindings: bindings, ignored: ignoredPaths(for: threadID)) }
                catch { discoveryByThread[threadID]?.message = error.localizedDescription }
            }
        }
    }

    nonisolated private static func candidate(_ hint: TaskProgressDiscoveryHint, reader: TaskProgressReader) async -> TaskProgressCandidate {
        let path = canonical(hint.path)
        do {
            let document = try await reader.read(path: path).tasks
            let scope = suggestedScope(hint.sectionHint, sections: document.sections)
            let tasks = scope == .document ? document : try await reader.read(path: path, scope: scope).tasks
            return .init(path: path, origins: hint.origins, suggestedScope: scope, tasks: tasks, status: .ready,
                         message: tasks.total == 0 ? "文档中尚未发现任务项" : nil)
        } catch {
            return .init(path: path, origins: hint.origins, suggestedScope: .document, tasks: nil,
                         status: status(for: error), message: error.localizedDescription)
        }
    }

    nonisolated private static func suggestedScope(_ hint: String?, sections: [TaskProgressSection]) -> TaskProgressScope {
        guard let hint, !hint.isEmpty else { return .document }
        func normalized(_ value: String) -> String {
            (value.removingPercentEncoding ?? value).lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let matches = sections.filter {
            guard case .section(let path) = $0.scope, let last = path.last else { return false }
            return normalized(last.title) == normalized(hint) || normalized($0.scope.label) == normalized(hint)
        }
        return matches.count == 1 ? matches[0].scope : .document
    }

    nonisolated private static func mergeHints(_ hints: [TaskProgressDiscoveryHint]) -> [TaskProgressDiscoveryHint] {
        var result: [TaskProgressDiscoveryHint] = []
        var positions: [String: Int] = [:]
        for hint in hints {
            let path = canonical(hint.path)
            if let index = positions[path] {
                for origin in hint.origins where !result[index].origins.contains(origin) { result[index].origins.append(origin) }
                // 目录扫描没有章节证据，不能抹掉会话已明确引用的章节。
                if result[index].hasConflictingSectionHints || hint.hasConflictingSectionHints {
                    result[index].sectionHint = nil
                    result[index].hasConflictingSectionHints = true
                } else if let section = hint.sectionHint {
                    if let previous = result[index].sectionHint, previous != section {
                        result[index].sectionHint = nil
                        result[index].hasConflictingSectionHints = true
                    } else { result[index].sectionHint = section }
                }
            } else {
                positions[path] = result.count
                result.append(.init(path: path, origins: hint.origins, sectionHint: hint.sectionHint,
                                    hasConflictingSectionHints: hint.hasConflictingSectionHints))
            }
        }
        return result
    }

    func refresh(threadID: String) {
        guard !stopped else { return }
        workers.removeValue(forKey: threadID)?.cancel()
        let generation = (generations[threadID] ?? 0) + 1
        generations[threadID] = generation
        let bindings = bindings(for: threadID)
        guard !bindings.isEmpty else { return }
        for binding in bindings where snapshots[binding.id] == nil {
            snapshots[binding.id] = .init(bindingID: binding.id, tasks: nil, status: .loading)
        }
        let reader = reader
        workers[threadID] = Task { [weak self] in
            for binding in bindings {
                do {
                    let read = try await reader.read(path: binding.path, scope: binding.scope)
                    guard !Task.isCancelled, let self, self.generations[threadID] == generation else { return }
                    self.snapshots[binding.id] = .init(bindingID: binding.id, tasks: read.tasks, status: .ready, lastReadAt: read.readAt)
                } catch {
                    guard !Task.isCancelled, let self, self.generations[threadID] == generation else { return }
                    var state = self.snapshots[binding.id] ?? .init(bindingID: binding.id, tasks: nil, status: .error)
                    state.status = Self.status(for: error); state.message = error.localizedDescription
                    self.snapshots[binding.id] = state
                }
            }
            guard let self, self.generations[threadID] == generation else { return }
            self.workers.removeValue(forKey: threadID)
        }
    }

    func refreshAndWait(threadID: String) async {
        refresh(threadID: threadID)
        await workers[threadID]?.value
    }

    func preview(path: String, scope: TaskProgressScope = .document) async throws -> TaskProgressTasks {
        let canonical = Self.canonical(path)
        try Self.validatePath(canonical)
        return try await reader.read(path: canonical, scope: scope).tasks
    }

    func openSource(_ binding: TaskProgressBinding, line: Int? = nil) {
        let file = URL(fileURLWithPath: binding.path)
        if let line, line > 0, let application = NSWorkspace.shared.urlForApplication(toOpen: file),
           let identifier = Bundle(url: application)?.bundleIdentifier,
           let scheme = ["com.microsoft.VSCode": "vscode", "com.microsoft.VSCodeInsiders": "vscode-insiders",
                         "com.todesktop.230313mzl4w4u92": "cursor", "com.exafunction.windsurf": "windsurf"][identifier] {
            var components = URLComponents(); components.scheme = scheme; components.host = "file"
            components.path = binding.path + ":\(line)"
            if let url = components.url, NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(file)
    }

    private func commit(threadID: String, bindings: [TaskProgressBinding], ignored: [String]) throws {
        try Self.validate(threadID: threadID, bindings: bindings)
        var next = bindingsByThread
        if bindings.isEmpty { next.removeValue(forKey: threadID) } else { next[threadID] = bindings }
        var exclusions = ignoredByThread
        if ignored.isEmpty { exclusions.removeValue(forKey: threadID) } else { exclusions[threadID] = ignored }
        var versions = revisions
        if bindings != self.bindings(for: threadID) { versions[threadID] = revision(for: threadID) + 1 }
        try persist(threads: next, ignored: exclusions, preferences: settingsByThread, revisions: versions)
        bindingsByThread = next; ignoredByThread = exclusions; revisions = versions
        let validIDs = Set(next.values.flatMap { $0.map(\.id) })
        snapshots = snapshots.filter { validIDs.contains($0.key) }
        storageError = nil
        updateObservation()
        refresh(threadID: threadID)
    }

    private func persist(threads: [String: [TaskProgressBinding]], ignored: [String: [String]],
                         preferences: [String: TaskProgressThreadSettings], revisions: [String: Int]) throws {
        guard storageWritable else { throw TaskProgressError.invalid(storageError ?? "绑定存储不可写。") }
        let state = StoredState(version: 2, sourceID: sourceID, threads: threads,
                                ignored: ignored, preferences: preferences, revisions: revisions)
        try Self.validateState(state)
        let data = try JSONEncoder().encode(state)
        guard data.count <= 4 * 1024 * 1024 else { throw TaskProgressError.invalid("任务绑定存储超过大小限制。") }
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: storageURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }

    private var monitoredThreads: Set<String> {
        let active = contexts.values.filter { $0.status == .running && !$0.isAutoReview }.map(\.id)
        let bound = contexts.values.filter { !bindings(for: $0.id).isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }.prefix(128).map(\.id)
        return Set(active).union(bound).union(panelThreads.keys)
            .union(presentationVisible ? Array(visibleThreads.keys) : [])
    }

    // 历史绑定只刷新文档；持续发现限于运行任务和正在浏览的任务，预算低于日志游标容量。
    private var discoveryThreads: Set<String> {
        let ids = Set(contexts.values.filter { $0.status == .running && !$0.isAutoReview }.map(\.id))
            .union(panelThreads.keys).union(presentationVisible ? Array(visibleThreads.keys) : [])
        return Set(ids.sorted {
            if (panelThreads[$0] != nil) != (panelThreads[$1] != nil) { return panelThreads[$0] != nil }
            if (contexts[$0]?.status == .running) != (contexts[$1]?.status == .running) { return contexts[$0]?.status == .running }
            let left = contexts[$0]?.updatedAt ?? .distantPast, right = contexts[$1]?.updatedAt ?? .distantPast
            return left == right ? $0 < $1 : left > right
        }.prefix(128))
    }

    private func updateObservation() {
        guard !stopped else { return }
        let threads = monitoredThreads
        let paths = Set(threads.flatMap { bindings(for: $0).map(\.path) })
        let candidates = Set(threads.flatMap { Array(scannedPaths[$0] ?? []) })
        Task { await reader.retain(paths: paths.union(candidates)) }
        guard automatic else { return }
        let rolloutPaths = threads.compactMap { contexts[$0]?.rolloutPath }
        let observed = paths.union(candidates).union(rolloutPaths)
        let directories = Set(observed.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        for path in Set(watchers.keys).subtracting(directories) { watchers.removeValue(forKey: path)?.cancel() }
        for path in directories where watchers[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib, .extend], queue: .main)
            watcher.setEventHandler { [weak self] in Task { @MainActor in self?.scheduleRefresh() } }
            watcher.setCancelHandler { close(descriptor) }
            watchers[path] = watcher; watcher.resume()
        }
        if !threads.isEmpty, pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshMonitored() }
            }
        } else if threads.isEmpty { pollTimer?.invalidate(); pollTimer = nil }
    }

    private func scheduleRefresh() {
        guard !stopped else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refreshMonitored()
        }
    }

    private func refreshMonitored() {
        guard !stopped else { return }
        for thread in monitoredThreads {
            if workers[thread] == nil { refresh(threadID: thread) }
            if automatic, discoveryThreads.contains(thread) { discover(threadID: thread) }
        }
    }

    func stop() {
        stopped = true
        debounce?.cancel(); debounce = nil
        workers.values.forEach { $0.cancel() }; workers.removeAll()
        scanWorkers.values.forEach { $0.cancel() }; scanWorkers.removeAll()
        watchers.values.forEach { $0.cancel() }; watchers.removeAll()
        pollTimer?.invalidate(); pollTimer = nil
        visibleThreads.removeAll(); panelThreads.removeAll(); contexts.removeAll()
        acceptedHints.removeAll()
        Task { await discovery.reset() }
    }

    private static func decrement(_ values: inout [String: Int], _ key: String) {
        let count = (values[key] ?? 0) - 1
        if count > 0 { values[key] = count } else { values.removeValue(forKey: key) }
    }

    nonisolated private static func canonical(_ path: String) -> String {
        TaskProgressPath.canonical(path)
    }

    private static func validateState(_ state: StoredState) throws {
        let ids = Set(state.threads.keys).union(state.ignored?.keys.map { $0 } ?? [])
            .union(state.preferences?.keys.map { $0 } ?? []).union(state.revisions?.keys.map { $0 } ?? [])
        guard ids.count <= 2_000 else { throw TaskProgressError.invalid("已达到会话绑定数量上限。") }
        for id in ids { try validate(threadID: id, bindings: state.threads[id] ?? []) }
        for paths in (state.ignored ?? [:]).values {
            guard paths.count <= 512, Set(paths).count == paths.count else { throw TaskProgressError.invalid("忽略文档数量超过限制或含重复项。") }
            for path in paths { try validatePath(path) }
        }
        guard (state.revisions ?? [:]).values.allSatisfy({ $0 >= 0 && $0 < Int.max }) else {
            throw TaskProgressError.invalid("绑定修订信息无效。")
        }
    }

    nonisolated private static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), path.count <= 4_096, !path.contains("\0"),
              ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
            throw TaskProgressError.invalid("请选择 Markdown 文档。")
        }
    }

    private static func validate(threadID: String, bindings: [TaskProgressBinding]) throws {
        guard !threadID.isEmpty, threadID.count <= 128, !threadID.contains("\0"),
              bindings.count <= TaskProgressParser.maximumDocuments,
              Set(bindings.map(\.id)).count == bindings.count,
              Set(bindings.map(\.path)).count == bindings.count else {
            throw TaskProgressError.invalid("会话或文档绑定无效，同一文件只能绑定一次。")
        }
        for binding in bindings {
            try validatePath(binding.path)
            if case .section(let parts) = binding.scope {
                guard !parts.isEmpty, parts.count <= 6 else { throw TaskProgressError.invalid("章节范围无效。") }
                var depth = 0
                for part in parts {
                    guard (1...6).contains(part.depth), part.depth > depth, !part.title.isEmpty, part.title.count <= 512,
                          part.ordinal > 0, part.total >= part.ordinal, part.total <= 10_000 else {
                        throw TaskProgressError.invalid("章节定位信息无效。")
                    }
                    depth = part.depth
                }
            }
        }
    }

    nonisolated private static func status(for error: any Error) -> TaskProgressSourceStatus {
        if let error = error as? TaskProgressError {
            switch error {
            case .scopeMissing: return .scopeMissing
            case .unstable: return .unstable
            case .invalid: return .unsupported
            }
        }
        let code = (error as NSError).code
        if [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(code) { return .missing }
        if code == NSFileReadNoPermissionError { return .permissionDenied }
        return .error
    }
}
