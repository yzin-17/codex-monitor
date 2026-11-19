import Combine
import Foundation

/// 有界增量读取；只读当前已发现的 rollout，不扫描历史账单。
actor CodexTokenRateReader {
    private struct Cursor {
        var identity: String
        var modifiedAt: Date?
        var offset: UInt64 = 0
        var pending = Data()
        var discardPartial = false
        var boundary = Data()
        var state: CodexTokenRateState
    }
    private var cursors: [String: Cursor] = [:]
    private let decoder = CodexTokenRateEventDecoder()
    private let maximumRead = 1_048_576
    private let maximumLine = 1_048_576

    func read(paths: [String]) -> [TokenRateTaskSample] {
        let selected = Array(Set(paths.filter { $0.hasSuffix(".jsonl") })).sorted().prefix(64)
        let keep = Set(selected)
        cursors = cursors.filter { keep.contains($0.key) }
        var budget = 8 * maximumRead
        for path in selected {
            guard !Task.isCancelled, budget > 0 else { break }
            do { budget -= try read(path: path, budget: min(maximumRead, budget)) }
            catch { cursors.removeValue(forKey: path) }
        }
        return cursors.values.compactMap { $0.state.sample }
    }

    func reset() { cursors.removeAll() }

    private func read(path: String, budget: Int) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return 0 }
        let identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
        let modifiedAt = attributes[.modificationDate] as? Date
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var cursor = cursors[path]
        if let previous = cursor {
            var changed = previous.identity != identity || size < previous.offset
                || (size == previous.offset && modifiedAt != previous.modifiedAt)
            if !changed, !previous.boundary.isEmpty, previous.offset >= UInt64(previous.boundary.count) {
                try handle.seek(toOffset: previous.offset - UInt64(previous.boundary.count))
                changed = try handle.read(upToCount: previous.boundary.count) != previous.boundary
            }
            if changed { cursor = nil }
        }
        if cursor == nil {
            // rollout 文件名携带会话 ID；祖先 session_meta 不可把子代理计量器改名。
            let basename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let candidate = String(basename.suffix(36))
            let id = UUID(uuidString: candidate)?.uuidString.lowercased()
            var fresh = Cursor(identity: identity, modifiedAt: modifiedAt, state: .init(threadID: id))
            try handle.seek(toOffset: 0)
            let header = try handle.read(upToCount: min(65_536, Int(min(size, 65_536)))) ?? Data()
            for line in header.split(separator: 0x0A) {
                if let event = decoder.decode(Data(line)), case .metadata = event.kind {
                    fresh.state.consume(event)
                }
            }
            fresh.offset = size > UInt64(maximumRead) ? size - UInt64(maximumRead) : 0
            fresh.discardPartial = fresh.offset > 0
            cursor = fresh
        }
        guard var current = cursor else { return 0 }
        if size - current.offset > UInt64(maximumRead) {
            // 大段追赶可能丢失请求边界；重新建立样本，不拿跳过的输出计算瞬时速率。
            current.offset = size - UInt64(maximumRead)
            current.pending.removeAll(); current.discardPartial = true
            current.state.resetMeasurement()
        }
        try handle.seek(toOffset: current.offset)
        let available = Int(min(UInt64(budget), size - current.offset))
        let bytes = available > 0 ? try handle.read(upToCount: available) ?? Data() : Data()
        current.offset += UInt64(bytes.count)
        current.pending.append(bytes)
        var start = current.pending.startIndex
        for index in current.pending.indices where current.pending[index] == 0x0A {
            let length = current.pending.distance(from: start, to: index)
            if current.discardPartial {
                current.discardPartial = false
            } else if length <= maximumLine {
                let line = current.pending.subdata(in: start..<index)
                if let event = decoder.decode(line) { current.state.consume(event) }
            } else {
                current.state.resetMeasurement()
            }
            start = current.pending.index(after: index)
        }
        current.pending = Data(current.pending[start...])
        if current.pending.count > maximumLine {
            current.pending.removeAll(); current.discardPartial = true; current.state.resetMeasurement()
        }
        if current.offset > 0 {
            let count = min(64, Int(current.offset))
            try handle.seek(toOffset: current.offset - UInt64(count))
            current.boundary = try handle.read(upToCount: count) ?? Data()
        }
        current.modifiedAt = modifiedAt
        cursors[path] = current
        return bytes.count
    }
}

@MainActor
final class CodexTokenRateStore: ObservableObject {
    @Published private(set) var summary: TokenRateSummary = .unavailable
    private let reader = CodexTokenRateReader()
    private var paths: [String] = []
    private var activeIDs: Set<String> = []
    private var activeCount = 0
    private var samples: [TokenRateTaskSample] = []
    private var timer: Timer?
    private var work: Task<Void, Never>?
    private var pending = false
    private var stopped = false
    private var lastReadAt: Date = .distantPast
    private let automatic: Bool

    init(automatic: Bool = true) { self.automatic = automatic }

    func setPaths(_ paths: [String]) {
        self.paths = paths.filter { $0.hasSuffix(".jsonl") }
        refresh(force: true)
    }

    func setTasks(_ tasks: [CodexTask]) {
        let running = tasks.filter { $0.status == .running && !$0.isAutoReview }
        activeIDs = Set(running.map { $0.id.lowercased() })
        activeCount = running.reduce(0) { $0 + 1 + $1.activeSubagentCount }
        publish()
        refresh()
        scheduleTimer()
    }

    func refresh(force: Bool = false) {
        guard automatic, !stopped else { return }
        guard work == nil else { pending = true; return }
        guard force || Date().timeIntervalSince(lastReadAt) >= 0.75 else { return }
        lastReadAt = Date()
        let currentPaths = paths
        work = Task(priority: .utility) { [weak self, reader] in
            let next = await reader.read(paths: currentPaths)
            guard let self, !Task.isCancelled, !self.stopped else { return }
            if currentPaths == self.paths { self.samples = next; self.publish() }
            self.work = nil
            if self.pending || currentPaths != self.paths {
                self.pending = false; self.refresh(force: currentPaths != self.paths)
            }
        }
    }

    func stop() {
        stopped = true; timer?.invalidate(); timer = nil
        work?.cancel(); work = nil
        Task { [reader] in await reader.reset() }
    }

    private func publish(now: Date = Date()) {
        let next = TokenRateSummary.aggregate(samples, activeThreadIDs: activeIDs,
                                             expectedActiveCount: activeCount, now: now)
        if summary != next { summary = next }
    }

    private func scheduleTimer() {
        guard automatic, !stopped else { return }
        timer?.invalidate()
        // 活跃期间仅检查文件增量；空闲时降低频率，不触发历史统计刷新。
        let interval: TimeInterval = activeIDs.isEmpty ? 15 : 1
        let next = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        next.tolerance = interval * 0.2
        timer = next
    }
}
