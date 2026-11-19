import Foundation

struct TaskProgressFileRead: Sendable {
    let tasks: TaskProgressTasks
    let readAt: Date
}

/// 文件读取与 Markdown 解析在独立 actor 上完成，不占用界面线程。
actor TaskProgressReader {
    private struct Cache {
        let version: String
        let source: String
        let readAt: Date
        var scopes: [TaskProgressScope: TaskProgressTasks]
    }
    private var cache: [String: Cache] = [:]
    private let stabilityNanoseconds: UInt64

    init(stabilityNanoseconds: UInt64 = 120_000_000) {
        self.stabilityNanoseconds = stabilityNanoseconds
    }

    func read(path: String, scope: TaskProgressScope = .document, force: Bool = false) async throws -> TaskProgressFileRead {
        let url = URL(fileURLWithPath: path)
        for _ in 0..<3 {
            try Task.checkCancellation()
            let before = try version(url)
            if !force, var previous = cache[path], previous.version == before {
                let tasks = try previous.scopes[scope] ?? TaskProgressParser.parse(previous.source, scope: scope)
                if previous.scopes.count >= 128, previous.scopes[scope] == nil { previous.scopes.removeAll(keepingCapacity: true) }
                previous.scopes[scope] = tasks
                cache[path] = previous
                return TaskProgressFileRead(tasks: tasks, readAt: previous.readAt)
            }
            let handle = try FileHandle(forReadingFrom: url)
            let data: Data
            do { data = try handle.read(upToCount: TaskProgressParser.maximumBytes + 1) ?? Data(); try handle.close() }
            catch { try? handle.close(); throw error }
            guard data.count <= TaskProgressParser.maximumBytes else { throw TaskProgressError.invalid("文档超过 2 MiB 限制。") }
            guard let source = String(data: data, encoding: .utf8) else { throw TaskProgressError.invalid("请选择 UTF-8 编码的 Markdown 文档。") }
            if stabilityNanoseconds > 0 { try await Task.sleep(nanoseconds: stabilityNanoseconds) }
            guard before == (try version(url)) else { continue }
            let tasks = try TaskProgressParser.parse(source, scope: scope)
            // 编辑器先清空再写入时，保留旧进度直到空内容稳定。
            if cache[path]?.scopes.values.contains(where: { $0.total > 0 }) == true, tasks.total == 0, stabilityNanoseconds > 0 {
                try await Task.sleep(nanoseconds: 300_000_000)
                guard before == (try version(url)) else { continue }
            }
            let date = Date()
            if cache[path] == nil, cache.count >= 128, let oldest = cache.min(by: { $0.value.readAt < $1.value.readAt })?.key {
                cache.removeValue(forKey: oldest)
            }
            cache[path] = Cache(version: before, source: source, readAt: date, scopes: [scope: tasks])
            return TaskProgressFileRead(tasks: tasks, readAt: date)
        }
        throw TaskProgressError.unstable
    }

    func retain(paths: Set<String>) { cache = cache.filter { paths.contains($0.key) } }

    private func version(_ url: URL) throws -> String {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw TaskProgressError.invalid("文件位置已变为符号链接，请重新绑定实际文件。")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw TaskProgressError.invalid("只能读取普通 Markdown 文件。") }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= TaskProgressParser.maximumBytes else { throw TaskProgressError.invalid("文档超过 2 MiB 限制。") }
        return "\((attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "")|\(size)|\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }
}
