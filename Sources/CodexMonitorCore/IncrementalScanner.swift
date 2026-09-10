import Foundation

struct FileCursor: Codable, Sendable {
    var inode: UInt64
    var offset: UInt64 = 0
    var observedSize: UInt64 = 0
    var observedMTime: Double = 0
    var anchorHash: String?
    var anchorLength: Int = 0
    var discardingLongLine = false
    var parser: ParserState
}
struct ScannerCache: Codable, Sendable {
    var version: Int = 2
    var home: String
    var skillsEnabled: Bool
    var files: [String: FileCursor]
}

/// 仅在 AnalysisEngine actor 内使用。完整行检查点；尾部半行留给下次扫描。
final class IncrementalScanner {
    private var cursors: [String: FileCursor] = [:]
    private var loadedCacheKey: String?
    private var rotation = 0
    private let maxLine = 1024 * 1024
    private let maxFileCount = 30_000

    func reset() { cursors.removeAll(); loadedCacheKey = nil }

    func scan(_ config: LedgerConfiguration, cancelled: () -> Bool = { false }) throws -> ([Session], ScanProgress) {
        let home = Paths.url(config.codexHome).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: home.path) else { throw LedgerError.missingDirectory }
        let cacheURL = config.cacheDirectory.map { Paths.url($0).appendingPathComponent("scan-v1.json") }
        if let cacheURL, Paths.contains(cacheURL, in: home) { throw LedgerError.unsafePath }
        let key = home.path + "|" + String(config.skillsEnabled) + "|" + (cacheURL?.path ?? "")
        var progress = ScanProgress()
        var cacheDirty = false
        if key != loadedCacheKey {
            cursors.removeAll(); cacheDirty = true
            if let cacheURL, let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size <= 128 * 1024 * 1024, let bytes = try? Data(contentsOf: cacheURL),
               let cache = try? JSONDecoder().decode(ScannerCache.self, from: bytes),
               cache.version == 2, cache.home == home.path, cache.skillsEnabled == config.skillsEnabled {
                cursors = cache.files; cacheDirty = false
            }
            loadedCacheKey = key
        }
        let paths = discover(home: home, progress: &progress)
        let pathSet = Set(paths.map(\.path))
        let previousCount = cursors.count
        cursors = cursors.filter { pathSet.contains($0.key) }
        if cursors.count != previousCount { cacheDirty = true }
        progress.files = paths.count
        let start = ProcessInfo.processInfo.systemUptime
        let ordered: [URL]
        if paths.isEmpty { ordered = [] } else {
            let split = rotation % paths.count
            ordered = Array(paths[split...]) + Array(paths[..<split])
        }
        var visited = 0
        for path in ordered {
            if cancelled() { throw CancellationError() }
            guard progress.bytesRead < config.byteBudget,
                  ProcessInfo.processInfo.systemUptime - start < config.timeBudget else { break }
            visited += 1
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let handle = try FileHandle(forReadingFrom: path)
                defer { try? handle.close() }
                var cursor = cursors[path.path] ?? FileCursor(inode: inode, parser: ParserState(path: path.path))
                if cursors[path.path] == nil { cacheDirty = true }
                var valid = cursor.inode == inode && cursor.offset <= size
                if valid && cursor.offset > 0, let hash = cursor.anchorHash, cursor.anchorLength > 0 {
                    guard UInt64(cursor.anchorLength) <= cursor.offset else { throw LedgerError.unsafePath }
                    try handle.seek(toOffset: cursor.offset - UInt64(cursor.anchorLength))
                    let anchor = try handle.read(upToCount: cursor.anchorLength) ?? Data()
                    valid = fingerprint(anchor) == hash
                    progress.bytesRead += cursor.anchorLength
                }
                if cursor.observedSize == size && cursor.observedMTime != 0 && cursor.observedMTime != mtime { valid = false }
                if !valid { cursor = FileCursor(inode: inode, parser: ParserState(path: path.path)); cacheDirty = true }
                if cursor.offset < size {
                    cacheDirty = true
                    try read(handle, size: size, cursor: &cursor, progress: &progress, config: config,
                             start: start, cancelled: cancelled)
                }
                cursor.observedSize = size; cursor.observedMTime = mtime
                if cursor.offset > 0 {
                    let length = Int(min(96, cursor.offset))
                    try handle.seek(toOffset: cursor.offset - UInt64(length))
                    cursor.anchorHash = fingerprint(try handle.read(upToCount: length) ?? Data())
                    cursor.anchorLength = length
                }
                cursors[path.path] = cursor
            } catch is CancellationError { throw CancellationError() }
            catch { progress.issues.append("无法读取日志文件：\(path.lastPathComponent)") }
        }
        if !paths.isEmpty { rotation = (rotation + max(1, visited)) % paths.count }
        for path in paths {
            let size = (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let c = cursors[path.path], c.offset == UInt64(size) { progress.caughtUp += 1 }
        }
        progress.pendingFiles = progress.files - progress.caughtUp
        let unknown = cursors.values.filter { !$0.parser.initialized && $0.offset == $0.observedSize }.count
        if unknown > 0 { progress.issues.append("有 \(unknown) 个文件缺少可识别的 session_meta，未纳入对话统计") }
        if let cacheURL, cacheDirty {
            do {
                let bytes = try JSONEncoder().encode(ScannerCache(home: home.path, skillsEnabled: config.skillsEnabled, files: cursors))
                if bytes.count <= 128 * 1024 * 1024 { try PrivateFile.write(bytes, to: cacheURL) }
                else { progress.issues.append("缓存超过 128 MiB；本轮未持久化，下次启动需要重新扫描") }
            } catch { progress.issues.append("无法写入本应用的派生缓存") }
        }
        return (cursors.values.filter { $0.parser.initialized }.map(\.parser.session), progress)
    }

    private func discover(home: URL, progress: inout ScanProgress) -> [URL] {
        var files: [URL] = []
        for directory in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard Paths.contains(root, in: home) else {
                progress.issues.append("跳过指向 Codex 目录之外的会话根目录"); continue
            }
            let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true })
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") else { continue }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true, Paths.contains(url, in: home) else { continue }
                files.append(url)
                if files.count >= maxFileCount {
                    progress.issues.append("日志文件超过 30,000 个，目录扫描已达上限")
                    return files.sorted { $0.path < $1.path }
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func read(_ handle: FileHandle, size: UInt64, cursor: inout FileCursor,
                      progress: inout ScanProgress, config: LedgerConfiguration, start: Double,
                      cancelled: () -> Bool) throws {
        try handle.seek(toOffset: cursor.offset)
        var buffer = Data()
        var lineStart = cursor.offset
        while cursor.offset + UInt64(buffer.count) < size {
            if cancelled() { throw CancellationError() }
            guard progress.bytesRead < config.byteBudget,
                  ProcessInfo.processInfo.systemUptime - start < config.timeBudget else { break }
            let remaining = size - (cursor.offset + UInt64(buffer.count))
            let count = min(64 * 1024, config.byteBudget - progress.bytesRead, Int(min(remaining, UInt64(Int.max))))
            guard count > 0, let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            progress.bytesRead += chunk.count
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 0x0a) {
                let row = buffer[..<end]
                if !cursor.discardingLongLine && row.count <= maxLine {
                    SessionParser.consume(Data(row), offset: lineStart, state: &cursor.parser, skillsEnabled: config.skillsEnabled)
                } else { cursor.parser.issue("存在超长日志行，部分信息被跳过") }
                let consumed = buffer.distance(from: buffer.startIndex, to: end) + 1
                cursor.offset += UInt64(consumed); lineStart = cursor.offset
                buffer.removeSubrange(...end); cursor.discardingLongLine = false
            }
            if buffer.count > maxLine || cursor.discardingLongLine {
                cursor.parser.issue("存在超长日志行，部分信息被跳过")
                cursor.offset += UInt64(buffer.count); lineStart = cursor.offset
                buffer.removeAll(keepingCapacity: true); cursor.discardingLongLine = true
            }
        }
        // buffer 中的半行不提交 offset，之后补全换行再读。避免把正在写入的 JSON 判为损坏。
    }
}
