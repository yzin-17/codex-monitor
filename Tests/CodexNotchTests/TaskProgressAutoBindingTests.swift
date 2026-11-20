import Foundation
import Testing
@testable import CodexNotch

@MainActor
private struct AutoProgressFixture {
    let directory: URL
    let log: URL
    let thread = "33333333-3333-4333-8333-333333333333"
    let store: TaskProgressStore

    init(automatic: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-auto-progress-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = directory.appendingPathComponent("rollout-33333333-3333-4333-8333-333333333333.jsonl")
        store = TaskProgressStore(codexHome: directory.appendingPathComponent("source").path, automatic: automatic,
            storageDirectory: directory.appendingPathComponent("state"), reader: .init(stabilityNanoseconds: 0))
        try Self.row("session_meta", ["id": thread, "cwd": directory.path]).write(to: log)
        store.setTasks([task()])
    }

    func task(status: TaskStatus = .running) -> CodexTask {
        .init(id: thread, title: "合成进度任务", status: status, detailPrefix: "synthetic", tokenCount: 0,
              updatedAt: Date(), rolloutPath: log.path)
    }
    func remove() { store.stop(); try? FileManager.default.removeItem(at: directory) }
    func document(_ relative: String, source: String = "- [x] 已完成\n- [ ] 待验证\n") throws -> URL {
        let file = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
    func mention(_ relative: String) throws { try append("event_msg", ["type": "agent_message", "message": "任务清单 [进度](\(relative))"]) }
    func append(_ type: String, _ payload: [String: Any]) throws {
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Self.row(type, payload))
    }
    nonisolated static func row(_ type: String, _ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
        data.append(0x0A); return data
    }
}

@Test @MainActor func taskAutoBindingDiscoversSessionDocumentsAndLeavesDirectoryMatchesAsCandidates() async throws {
    let fixture = try AutoProgressFixture()
    defer { fixture.remove() }
    let explicit = try fixture.document("docs/evidence/implementation.md")
    let written = try fixture.document("notes/changed.md")
    let workspace = try fixture.document("tasks/other.md")
    try fixture.mention("docs/evidence/implementation.md")
    try fixture.append("response_item", ["type": "custom_tool_call", "name": "apply_patch",
        "input": "*** Begin Patch\n*** Update File: notes/changed.md\n@@\n+- [ ] Next\n*** End Patch"])
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    let bindings = fixture.store.bindings(for: fixture.thread)
    #expect(Set(bindings.map(\.path)) == Set([explicit.path, written.path]))
    #expect(bindings.allSatisfy { $0.origin == .automatic })
    #expect(fixture.store.discoveryState(for: fixture.thread).candidates.contains { $0.path == workspace.path })
    #expect(fixture.store.summary(for: fixture.thread).completed == 2)
    #expect(fixture.store.summary(for: fixture.thread).total == 4)
}

@Test @MainActor func taskAutoBindingRetriesReferencedFilesAfterTheyAreCreated() async throws {
    let fixture = try AutoProgressFixture()
    defer { fixture.remove() }
    try fixture.mention("notes/pending.md")
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    #expect(fixture.store.bindings(for: fixture.thread).isEmpty)
    #expect(fixture.store.discoveryState(for: fixture.thread).candidates.first?.status == .missing)
    let file = try fixture.document("notes/pending.md")
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    #expect(fixture.store.bindings(for: fixture.thread).map(\.path) == [file.path])
}

@Test @MainActor func taskAutoBindingExclusionSurvivesReloadAndExplicitRestore() async throws {
    let fixture = try AutoProgressFixture()
    defer { fixture.remove() }
    let file = try fixture.document("progress.md")
    try fixture.mention("progress.md")
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    try fixture.store.replaceBindings(threadID: fixture.thread, with: [])
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    #expect(fixture.store.bindings(for: fixture.thread).isEmpty)
    let restored = TaskProgressStore(codexHome: fixture.store.sourceID, automatic: false,
        storageDirectory: fixture.store.storageURL.deletingLastPathComponent(), reader: .init(stabilityNanoseconds: 0))
    defer { restored.stop() }
    restored.setTasks([fixture.task()])
    await restored.discoverAndWait(threadID: fixture.thread, force: true)
    #expect(restored.ignoredPaths(for: fixture.thread) == [file.path])
    #expect(restored.bindings(for: fixture.thread).isEmpty)
    try restored.restoreIgnored(path: file.path, threadID: fixture.thread)
    await restored.discoverAndWait(threadID: fixture.thread, force: true)
    #expect(restored.bindings(for: fixture.thread).map(\.path) == [file.path])
}

@Test @MainActor func taskAutoBindingUpdatesAutomaticScopeButPreservesManualScope() async throws {
    let fixture = try AutoProgressFixture()
    defer { fixture.remove() }
    let file = try fixture.document("progress.md", source: "# 阶段一\n- [x] A\n# 阶段二\n- [ ] B\n")
    try fixture.mention("progress.md#阶段一")
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    let first = try #require(fixture.store.bindings(for: fixture.thread).first)
    #expect(first.scope != .document)
    #expect(fixture.store.summary(for: fixture.thread).total == 1)
    try fixture.mention("progress.md#阶段二")
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    #expect(fixture.store.bindings(for: fixture.thread).first?.scope == .document)
    #expect(fixture.store.summary(for: fixture.thread).total == 2)
    try fixture.store.replaceBindings(threadID: fixture.thread,
        with: [.init(id: first.id, path: file.path, scope: first.scope)])
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    #expect(fixture.store.bindings(for: fixture.thread).first?.scope == first.scope)
    #expect(fixture.store.bindings(for: fixture.thread).first?.origin == .manual)
}

@Test @MainActor func taskDirectoryScanPreservesExistingAutomaticSectionAndRevision() async throws {
    let fixture = try AutoProgressFixture()
    defer { fixture.remove() }
    let file = try fixture.document("notes/progress.md", source: "# 阶段一\n- [x] A\n# 阶段二\n- [ ] B\n")
    let other = try fixture.document("other/task.md")
    try fixture.mention("notes/progress.md#阶段一")
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    let bindings = fixture.store.bindings(for: fixture.thread)
    let first = try #require(bindings.first)
    #expect(first.scope != .document)
    let revision = fixture.store.revision(for: fixture.thread)

    // 无关目录和同一文件的目录候选都不能充当新的章节证据。
    for directory in [other.deletingLastPathComponent(), file.deletingLastPathComponent()] {
        await fixture.store.scanDirectory(path: directory.path, threadID: fixture.thread)
        #expect(fixture.store.bindings(for: fixture.thread) == bindings)
        #expect(fixture.store.revision(for: fixture.thread) == revision)
        #expect(fixture.store.summary(for: fixture.thread).total == 1)
        #expect(fixture.store.discoveryState(for: fixture.thread).candidates.first { $0.path == file.path }?.suggestedScope == first.scope)
    }
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    #expect(fixture.store.bindings(for: fixture.thread) == bindings)
    #expect(fixture.store.revision(for: fixture.thread) == revision)
    #expect(fixture.store.discoveryState(for: fixture.thread).candidates.contains { $0.path == other.path })
}

@Test @MainActor func taskAutoBindingRejectsStaleDocumentDraftRevision() async throws {
    let fixture = try AutoProgressFixture()
    defer { fixture.remove() }
    _ = try fixture.document("one.md")
    _ = try fixture.document("two.md")
    try fixture.mention("one.md")
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    let previous = fixture.store.bindings(for: fixture.thread)
    let revision = fixture.store.revision(for: fixture.thread)
    try fixture.mention("two.md")
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    #expect(throws: (any Error).self) {
        try fixture.store.replaceBindings(threadID: fixture.thread, with: previous, expectedRevision: revision)
    }
    #expect(fixture.store.bindings(for: fixture.thread).count == 2)
}

@Test @MainActor func taskAutoBindingCanBeDisabledWhileCandidatesRemainAvailable() async throws {
    let fixture = try AutoProgressFixture()
    defer { fixture.remove() }
    let file = try fixture.document("progress.md")
    try fixture.mention("progress.md")
    try fixture.store.updateSettings(threadID: fixture.thread, autoBind: false, scanWorkspace: true)
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    #expect(fixture.store.bindings(for: fixture.thread).isEmpty)
    #expect(fixture.store.discoveryState(for: fixture.thread).candidates.contains { $0.path == file.path && $0.canBind })
}

@Test @MainActor func taskAutoBindingLimitsBindingsWithoutDiscardingAdditionalCandidates() async throws {
    let fixture = try AutoProgressFixture()
    defer { fixture.remove() }
    for index in 0..<18 {
        _ = try fixture.document("progress-\(index).md")
        try fixture.mention("progress-\(index).md")
    }
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    #expect(fixture.store.bindings(for: fixture.thread).count == 16)
    #expect(fixture.store.discoveryState(for: fixture.thread).candidates.count == 18)
    #expect(fixture.store.discoveryState(for: fixture.thread).message?.contains("16") == true)
}

@Test @MainActor func taskAutoBindingFindsChecklistAfterManyNonTaskMarkdownFiles() async throws {
    let fixture = try AutoProgressFixture()
    defer { fixture.remove() }
    for index in 0..<270 {
        _ = try fixture.document(String(format: "tasks/%03d.md", index), source: "# 说明\n没有任务清单。\n")
    }
    let file = try fixture.document("tasks/999.md")
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    #expect(fixture.store.discoveryState(for: fixture.thread).candidates.contains { $0.path == file.path && $0.canBind })
    #expect(fixture.store.bindings(for: fixture.thread).isEmpty)
}

@Test @MainActor func taskAutoBindingKeepsRunningAndBoundDocumentsFreshWhilePanelsAreClosed() async throws {
    let fixture = try AutoProgressFixture(automatic: true)
    defer { fixture.remove() }
    let file = try fixture.document("progress.md", source: "- [ ] Task\n")
    try fixture.mention("progress.md")
    fixture.store.setPresentationVisible(false)
    await fixture.store.discoverAndWait(threadID: fixture.thread, force: true)
    #expect(fixture.store.summary(for: fixture.thread).total == 1)
    fixture.store.setTasks([fixture.task(status: .recent)])
    try "- [x] Task\n".write(to: file, atomically: true, encoding: .utf8)
    for _ in 0..<200 {
        if fixture.store.summary(for: fixture.thread).completed == 1 { break }
        try await Task.sleep(for: .milliseconds(15))
    }
    #expect(fixture.store.summary(for: fixture.thread).completed == 1)
}

@Test @MainActor func taskProgressV1BindingsMigrateWithoutChangingManualScope() throws {
    let fixture = try AutoProgressFixture()
    defer { fixture.remove() }
    let file = try fixture.document("progress.md")
    let binding = TaskProgressBinding(id: UUID(), path: file.path, scope: .document)
    var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as? [String: Any])
    value.removeValue(forKey: "origin")
    let legacy = try JSONSerialization.data(withJSONObject: [
        "version": 1, "sourceID": fixture.store.sourceID, "threads": [fixture.thread: [value]]
    ])
    try FileManager.default.createDirectory(at: fixture.store.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try legacy.write(to: fixture.store.storageURL)
    let restored = TaskProgressStore(codexHome: fixture.store.sourceID, automatic: false,
        storageDirectory: fixture.store.storageURL.deletingLastPathComponent())
    defer { restored.stop() }
    #expect(restored.bindings(for: fixture.thread) == [binding])
    try restored.updateSettings(threadID: fixture.thread, autoBind: false, scanWorkspace: false)
    let stored = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: restored.storageURL)) as? [String: Any])
    #expect(stored["version"] as? Int == 2)
    #expect(restored.bindings(for: fixture.thread).first?.origin == .manual)
}

@Test func taskProgressDetailsRetainRawTextIdentifiersAndSourceLines() throws {
    let tasks = try TaskProgressParser.parse("# 实施\n- [ ] T12: 原文 **加粗**\n  - 状态：验证中\n- [x] T13 完成\n")
    let first = try #require(tasks.items.first)
    #expect(first.explicitID == "T12")
    #expect(first.title == "原文 加粗")
    #expect(first.rawText.contains("**加粗**"))
    #expect(first.rawText.contains("状态：验证中"))
    #expect(!first.rawText.contains("T13"))
    #expect(first.line == 2 && first.endLine == 3)
}

@Test @MainActor func taskDocumentDraftCannotMutateSelectionWhileSaving() async throws {
    let fixture = try AutoProgressFixture()
    defer { fixture.remove() }
    let a = try fixture.document("one.md"), b = try fixture.document("two.md")
    let draft = TaskProgressDocumentDraftSession(store: fixture.store, threadID: fixture.thread)
    defer { draft.stop() }
    draft.add(path: a.path)
    for _ in 0..<200 {
        if !draft.busy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(draft.canSave)
    var saved = false
    draft.save { saved = true }
    draft.add(path: b.path)
    draft.remove(id: try #require(draft.rows.first?.id))
    draft.clear()
    draft.importBindings([.init(id: UUID(), path: b.path, scope: .document)])
    #expect(draft.rows.map(\.path) == [a.path])
    for _ in 0..<200 {
        if !draft.busy { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(saved)
    #expect(fixture.store.bindings(for: fixture.thread).map(\.path) == [a.path])
}

@Test func taskDiscoveryCanAdvanceMoreThanThirtyTwoConcurrentSessionCursors() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("progress-cursors-\(UUID())")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = TaskProgressDiscoveryService(maximumReadBytes: 256)
    let ids = (0..<33).map { "synthetic-thread-\($0)" }
    for id in ids {
        var data = try AutoProgressFixture.row("session_meta", ["id": id, "cwd": directory.path])
        data.append(try AutoProgressFixture.row("event_msg", ["type": "agent_message", "message": String(repeating: "x", count: 500)]))
        data.append(try AutoProgressFixture.row("event_msg", ["type": "agent_message", "message": "[任务](\(id).md)"]))
        try data.write(to: directory.appendingPathComponent("\(id).jsonl"))
    }
    var found = Set<String>()
    for _ in 0..<8 {
        for id in ids {
            let result = await service.scan(threadID: id, rolloutPath: directory.appendingPathComponent("\(id).jsonl").path,
                                            includeWorkspace: false)
            if result.hints.contains(where: { $0.path.hasSuffix("/\(id).md") }) { found.insert(id) }
        }
    }
    #expect(found.count == ids.count)
}
