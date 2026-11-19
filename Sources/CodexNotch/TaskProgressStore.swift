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
    @Published private(set) var storageError: String?
    let sourceID: String
    let storageURL: URL

    private struct StoredState: Codable {
        let version: Int
        let sourceID: String
        let threads: [String: [TaskProgressBinding]]
    }
    private let automatic: Bool
    private let reader: TaskProgressReader
    private var presentationVisible = true
    private var visibleThreads: [String: Int] = [:]
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var pollTimer: Timer?
    private var debounce: Task<Void, Never>?
    private var workers: [String: Task<Void, Never>] = [:]
    private var generations: [String: Int] = [:]
    private var storageWritable = true

    init(codexHome: String, automatic: Bool = true, storageDirectory: URL? = nil,
         reader: TaskProgressReader = TaskProgressReader()) {
        sourceID = URL(fileURLWithPath: codexHome).standardizedFileURL.resolvingSymlinksInPath().path
        self.automatic = automatic
        self.reader = reader
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
                guard state.version == 1, state.sourceID == sourceID, state.threads.count <= 2_000 else {
                    throw TaskProgressError.invalid("任务绑定存储格式或数据来源不匹配。")
                }
                for (thread, bindings) in state.threads { try Self.validate(threadID: thread, bindings: bindings) }
                bindingsByThread = state.threads
            }
        } catch {
            storageWritable = false
            storageError = "绑定存储读取失败，原文件已保留：\(error.localizedDescription)"
        }
    }

    func bindings(for threadID: String) -> [TaskProgressBinding] { bindingsByThread[threadID] ?? [] }
    func summary(for threadID: String) -> TaskProgressSummary { .summarize(bindings: bindings(for: threadID), snapshots: snapshots) }

    func retain(threadID: String) {
        visibleThreads[threadID, default: 0] += 1
        if presentationVisible { refresh(threadID: threadID) }
        updateObservation()
    }

    // 详情 NSPanel 会 orderOut 而不卸载 SwiftUI 行，不能只依赖 onDisappear。
    func setPresentationVisible(_ visible: Bool) {
        guard presentationVisible != visible else { return }
        presentationVisible = visible
        if !visible {
            debounce?.cancel(); debounce = nil
            workers.values.forEach { $0.cancel() }; workers.removeAll()
            for thread in Array(generations.keys) { generations[thread, default: 0] += 1 }
        }
        updateObservation()
        if visible { refreshVisible() }
    }

    func release(threadID: String) {
        let count = (visibleThreads[threadID] ?? 0) - 1
        if count > 0 { visibleThreads[threadID] = count }
        else {
            visibleThreads.removeValue(forKey: threadID)
            workers.removeValue(forKey: threadID)?.cancel()
            generations[threadID, default: 0] += 1
        }
        updateObservation()
    }

    func replaceBindings(threadID: String, with bindings: [TaskProgressBinding]) throws {
        guard storageWritable else { throw TaskProgressError.invalid(storageError ?? "绑定存储不可写。") }
        let normalized = bindings.map { TaskProgressBinding(id: $0.id,
            path: URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path, scope: $0.scope) }
        try Self.validate(threadID: threadID, bindings: normalized)
        var next = bindingsByThread
        if normalized.isEmpty { next.removeValue(forKey: threadID) } else { next[threadID] = normalized }
        guard next.count <= 2_000 else { throw TaskProgressError.invalid("已达到会话绑定数量上限。") }
        let data = try JSONEncoder().encode(StoredState(version: 1, sourceID: sourceID, threads: next))
        guard data.count <= 4 * 1024 * 1024 else { throw TaskProgressError.invalid("任务绑定存储超过大小限制。") }
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: storageURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        bindingsByThread = next
        let validIDs = Set(next.values.flatMap { $0.map(\.id) })
        snapshots = snapshots.filter { validIDs.contains($0.key) }
        storageError = nil
        updateObservation()
        refresh(threadID: threadID)
    }

    func refresh(threadID: String) {
        workers.removeValue(forKey: threadID)?.cancel()
        let generation = (generations[threadID] ?? 0) + 1
        generations[threadID] = generation
        let bindings = bindings(for: threadID)
        guard !bindings.isEmpty else { return }
        for binding in bindings where snapshots[binding.id] == nil {
            snapshots[binding.id] = TaskProgressDocumentState(bindingID: binding.id, tasks: nil, status: .loading)
        }
        let reader = reader
        workers[threadID] = Task { [weak self] in
            for binding in bindings {
                do {
                    let read = try await reader.read(path: binding.path, scope: binding.scope)
                    guard !Task.isCancelled, let self, self.generations[threadID] == generation else { return }
                    self.snapshots[binding.id] = TaskProgressDocumentState(bindingID: binding.id, tasks: read.tasks,
                        status: .ready, lastReadAt: read.readAt)
                } catch {
                    guard !Task.isCancelled, let self, self.generations[threadID] == generation else { return }
                    var state = self.snapshots[binding.id] ?? .init(bindingID: binding.id, tasks: nil, status: .error)
                    state.status = Self.status(for: error)
                    state.message = error.localizedDescription
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
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: canonical).pathExtension.lowercased()) else {
            throw TaskProgressError.invalid("请选择 Markdown 文档。")
        }
        return try await reader.read(path: canonical, scope: scope).tasks
    }

    func openSource(_ binding: TaskProgressBinding) { NSWorkspace.shared.open(URL(fileURLWithPath: binding.path)) }

    func stop() {
        presentationVisible = false
        debounce?.cancel(); debounce = nil
        workers.values.forEach { $0.cancel() }; workers.removeAll()
        for thread in Array(generations.keys) { generations[thread, default: 0] += 1 }
        watchers.values.forEach { $0.cancel() }; watchers.removeAll()
        pollTimer?.invalidate(); pollTimer = nil
        visibleThreads.removeAll()
    }

    private func updateObservation() {
        let paths = presentationVisible ? Set(visibleThreads.keys.flatMap { bindings(for: $0).map(\.path) }) : []
        Task { await reader.retain(paths: paths) }
        guard automatic else { return }
        let directories = Set(paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        for path in Set(watchers.keys).subtracting(directories) { watchers.removeValue(forKey: path)?.cancel() }
        for path in directories where watchers[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib, .extend], queue: .main)
            watcher.setEventHandler { [weak self] in Task { @MainActor in self?.scheduleRefresh() } }
            watcher.setCancelHandler { close(descriptor) }
            watchers[path] = watcher
            watcher.resume()
        }
        if !paths.isEmpty, pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshVisible() }
            }
        } else if paths.isEmpty { pollTimer?.invalidate(); pollTimer = nil }
    }

    private func scheduleRefresh() {
        guard presentationVisible else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshVisible()
        }
    }

    private func refreshVisible() {
        guard presentationVisible else { return }
        for thread in visibleThreads.keys where workers[thread] == nil { refresh(threadID: thread) }
    }

    private static func validate(threadID: String, bindings: [TaskProgressBinding]) throws {
        guard !threadID.isEmpty, threadID.count <= 128, !threadID.contains("\0"),
              bindings.count <= TaskProgressParser.maximumDocuments,
              Set(bindings.map(\.id)).count == bindings.count,
              Set(bindings.map(\.path)).count == bindings.count else { throw TaskProgressError.invalid("会话或文档绑定无效，同一文件只能绑定一次。") }
        for binding in bindings {
            guard binding.path.hasPrefix("/"), binding.path.count <= 4_096, !binding.path.contains("\0"),
                  ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: binding.path).pathExtension.lowercased()) else {
                throw TaskProgressError.invalid("请选择 Markdown 文档。")
            }
            if case .section(let parts) = binding.scope {
                guard !parts.isEmpty, parts.count <= 6 else { throw TaskProgressError.invalid("章节范围无效。") }
                var depth = 0
                for part in parts {
                    guard (1...6).contains(part.depth), part.depth > depth, !part.title.isEmpty, part.title.count <= 512,
                          part.ordinal > 0, part.total >= part.ordinal, part.total <= 10_000 else { throw TaskProgressError.invalid("章节定位信息无效。") }
                    depth = part.depth
                }
            }
        }
    }

    private static func status(for error: any Error) -> TaskProgressSourceStatus {
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
