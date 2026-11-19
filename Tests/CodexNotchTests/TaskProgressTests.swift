import Foundation
import Testing
@testable import CodexNotch

@Test func taskProgressCountsLeafCheckboxesAndGFMTableRows() throws {
    let source = #"""
    # 计划
    - [x] 父分组
      - [x] T1 已完成
      - [ ] T2 待验证
    - [ ] T3 独立任务
      - 状态：进行中

    ```markdown
    - [x] 代码里的伪任务
    ```

    > - [x] 引用里的伪任务

    <div>
    - [x] HTML 里的伪任务
    </div>

    | 任务 | 备注 |
    | --- | --- |
    | [x] T4 表格完成 | 已验证 |
    | [ ] | T5 表格待办 |
    | 普通行 | 不计入 |
    """#
    let tasks = try TaskProgressParser.parse(source)
    #expect(tasks.total == 5)
    #expect(tasks.completed == 2)
    #expect(tasks.items.map(\.title) == ["已完成", "待验证", "独立任务", "表格完成", "表格待办"])
    #expect(tasks.items[0].groups == ["计划", "父分组"])
    #expect(tasks.items[2].status == "进行中")
    #expect(tasks.diagnostics.count == 1)
}

@Test func taskProgressScopesDisambiguateDuplicateHeadingsAndRejectChangedRanges() throws {
    let source = "# 计划\n## 阶段\n- [x] A\n## 阶段\n- [ ] B\n# 其他\n- [x] C\n"
    let all = try TaskProgressParser.parse(source)
    let scope = all.sections[2].scope
    let selected = try TaskProgressParser.parse(source, scope: scope)
    #expect(selected.items.map(\.title) == ["B"])
    #expect(scope.label == "计划 / 阶段 (2/2)")
    #expect(throws: TaskProgressError.scopeMissing) {
        try TaskProgressParser.parse(source.replacingOccurrences(of: "## 阶段\n- [ ] B", with: "## 新阶段\n- [ ] B"), scope: scope)
    }
    #expect(throws: TaskProgressError.scopeMissing) {
        try TaskProgressParser.parse(source + "\n# 计划\n- [ ] D", scope: scope)
    }
}

@Test func taskProgressExplicitStatusesDoNotCountAsCompleted() throws {
    let source = "- [ ] T1 尚未完成\n  - Status: validating\n- [x] T2 冲突\n  - 状态：阻塞\n"
    let tasks = try TaskProgressParser.parse(source)
    #expect(tasks.completed == 1)
    #expect(tasks.items.first?.status == "验证中")
    #expect(tasks.items.last?.conflict == true)
}

@Test func taskProgressRejectsOversizedDocumentsAndTaskSets() {
    #expect(throws: (any Error).self) { try TaskProgressParser.parse(String(repeating: "a", count: 2 * 1024 * 1024 + 1)) }
    #expect(throws: (any Error).self) { try TaskProgressParser.parse(String(repeating: "- [ ] item\n", count: 5_001)) }
}

@Test func taskProgressAggregatesCountsAndKeepsUnknownAndCachedStatesDistinct() throws {
    let a = TaskProgressBinding(id: UUID(), path: "/synthetic/a.md", scope: .document)
    let b = TaskProgressBinding(id: UUID(), path: "/synthetic/b.md", scope: .document)
    let complete = try TaskProgressParser.parse("- [x] A")
    let larger = try TaskProgressParser.parse("- [x] B\n" + String(repeating: "- [ ] pending\n", count: 8))
    let snapshots: [UUID: TaskProgressDocumentState] = [
        a.id: .init(bindingID: a.id, tasks: complete, status: .ready),
        b.id: .init(bindingID: b.id, tasks: larger, status: .missing)
    ]
    let total = TaskProgressSummary.summarize(bindings: [a, b], snapshots: snapshots)
    #expect(total.completed == 2 && total.total == 10)
    #expect(total.fraction == 0.2)
    #expect(total.stale && !total.partial)
    #expect(total.label == "2/10 · 缓存")
    let partial = TaskProgressSummary.summarize(bindings: [a, b], snapshots: [a.id: snapshots[a.id]!])
    #expect(partial.partial && partial.label == "1/1 · 部分")
    #expect(partial.fraction == nil)
    #expect(TaskProgressSummary.summarize(bindings: [], snapshots: [:]).fraction == nil)
    #expect(TaskProgressSummary.summarize(bindings: [a], snapshots: [:]).label == "进度 —")
    let empty = TaskProgressDocumentState(bindingID: a.id, tasks: try TaskProgressParser.parse("# 空文档"), status: .ready)
    let zero = TaskProgressSummary.summarize(bindings: [a], snapshots: [a.id: empty])
    #expect(zero.label == "无任务" && zero.fraction == nil)
}

private func progressTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-progress-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func taskProgressReaderHandlesAtomicReplacementAndDoesNotFollowChangedSymlink() async throws {
    let directory = try progressTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("tasks.md")
    try Data("- [ ] A".utf8).write(to: file)
    let reader = TaskProgressReader(stabilityNanoseconds: 0)
    let first = try await reader.read(path: file.path)
    #expect(first.tasks.completed == 0)
    let again = try await reader.read(path: file.path)
    #expect(again.readAt == first.readAt)
    try Data("- [x] A".utf8).write(to: file, options: .atomic)
    #expect(try await reader.read(path: file.path).tasks.completed == 1)
    let other = directory.appendingPathComponent("other.md")
    try Data("- [x] B".utf8).write(to: other)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
    await #expect(throws: (any Error).self) { try await reader.read(path: file.path) }
}

@Test @MainActor func taskProgressStoreRestoresBindingsSeparatesSourcesAndCachesReadFailure() async throws {
    let directory = try progressTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("tasks.md")
    try Data("- [x] Done\n- [ ] Next\n".utf8).write(to: file)
    let reader = TaskProgressReader(stabilityNanoseconds: 0)
    let store = TaskProgressStore(codexHome: directory.appendingPathComponent("source-a").path,
                                  automatic: false, storageDirectory: directory, reader: reader)
    defer { store.stop() }
    let binding = TaskProgressBinding(id: UUID(), path: file.path, scope: .document)
    try store.replaceBindings(threadID: "thread-a", with: [binding])
    await store.refreshAndWait(threadID: "thread-a")
    #expect(store.summary(for: "thread-a").label == "1/2")
    let restored = TaskProgressStore(codexHome: store.sourceID, automatic: false, storageDirectory: directory)
    defer { restored.stop() }
    #expect(restored.bindings(for: "thread-a") == [binding])
    let other = TaskProgressStore(codexHome: directory.appendingPathComponent("source-b").path,
                                  automatic: false, storageDirectory: directory)
    defer { other.stop() }
    #expect(other.bindings(for: "thread-a").isEmpty)
    try FileManager.default.removeItem(at: file)
    await store.refreshAndWait(threadID: "thread-a")
    #expect(store.summary(for: "thread-a").label == "1/2 · 缓存")
    #expect(store.snapshots[binding.id]?.status == .missing)
    #expect(store.snapshots[binding.id]?.cached == true)
    try store.replaceBindings(threadID: "thread-a", with: [])
    #expect(store.summary(for: "thread-a").label == "绑定任务清单")
    #expect(store.snapshots[binding.id] == nil)
}

@Test @MainActor func taskProgressStoreRejectsDuplicateFilesAndPreservesCorruptStorage() throws {
    let directory = try progressTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskProgressStore(codexHome: "/synthetic/codex", automatic: false, storageDirectory: directory)
    defer { store.stop() }
    let a = TaskProgressBinding(id: UUID(), path: directory.appendingPathComponent("a.md").path, scope: .document)
    let duplicate = TaskProgressBinding(id: UUID(), path: a.path, scope: .document)
    #expect(throws: (any Error).self) { try store.replaceBindings(threadID: "thread", with: [a, duplicate]) }
    #expect(store.bindings(for: "thread").isEmpty)
    let corrupt = Data("not a valid binding store".utf8)
    try corrupt.write(to: store.storageURL)
    let restored = TaskProgressStore(codexHome: store.sourceID, automatic: false, storageDirectory: directory)
    defer { restored.stop() }
    #expect(restored.storageError != nil)
    #expect(throws: (any Error).self) { try restored.replaceBindings(threadID: "thread", with: [a]) }
    #expect(try Data(contentsOf: restored.storageURL) == corrupt)
}

@Test func taskProgressImportRequiresExactThreadAndExplicitSourceSelection() throws {
    func row(source: String, thread: String) -> [String: Any] {
        let monitor: [String: Any] = ["kind": "thread", "sourceId": source, "threadId": thread]
        return ["monitor": monitor, "bindings": [["monitor": monitor,
            "documentRealPath": "/synthetic/\(source).md", "scope": ["kind": "document"]]]]
    }
    let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2,
        "monitors": [row(source: "codex-default", thread: "exact-thread"), row(source: "other-profile", thread: "exact-thread"),
                     row(source: "wrong-thread", thread: "other-thread")]])
    let candidates = try TaskProgressImport.candidates(data: data, threadID: "exact-thread")
    #expect(candidates.map(\.sourceID) == ["codex-default", "other-profile"])
    #expect(candidates.allSatisfy { $0.threadID == "exact-thread" && $0.bindings.count == 1 })
    #expect(try TaskProgressImport.candidates(data: data, threadID: "missing").isEmpty)
    let mismatch = try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "monitors": [[
        "monitor": ["kind": "thread", "sourceId": "source", "threadId": "exact-thread"],
        "bindings": [["monitor": ["kind": "thread", "sourceId": "other", "threadId": "exact-thread"],
                      "documentRealPath": "/synthetic/a.md", "scope": ["kind": "document"]]]]]])
    #expect(throws: (any Error).self) { try TaskProgressImport.candidates(data: mismatch, threadID: "exact-thread") }
}
