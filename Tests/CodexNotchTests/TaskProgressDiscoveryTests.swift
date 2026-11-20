import Foundation
import Testing
@testable import CodexNotch

private let discoveryThread = "11111111-1111-4111-8111-111111111111"
private let discoveryOtherThread = "22222222-2222-4222-8222-222222222222"

private struct DiscoveryFixture {
    let directory: URL
    let log: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("monitor-discovery-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = directory.appendingPathComponent("rollout-\(discoveryThread).jsonl")
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func write(_ rows: [Data]) throws { try rows.reduce(into: Data()) { $0.append($1) }.write(to: log) }

    func append(_ bytes: Data) throws {
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    func markdown(_ relative: String) throws -> URL {
        let file = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("- [ ] Synthetic task\n".utf8).write(to: file)
        return file
    }

    func meta(id: String = discoveryThread, cwd: String? = nil, extra: [String: Any] = [:]) throws -> Data {
        var fields: [String: Any] = ["id": id, "cwd": cwd ?? directory.path]
        fields.merge(extra) { _, new in new }
        return try discoveryRow("session_meta", fields)
    }
}

private func discoveryRow(_ type: String, _ payload: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload], options: [.sortedKeys])
    data.append(0x0A)
    return data
}

private func discoveryJSON(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
}

private func discoveryMessage(_ text: String, owner: String? = nil) throws -> Data {
    var payload: [String: Any] = ["type": "agent_message", "message": text]
    if let owner { payload["thread_id"] = owner }
    return try discoveryRow("event_msg", payload)
}

@Test func taskDiscoveryFindsExplicitDocumentsAndUniqueSectionWithoutFilenameGuessing() async throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.remove() }
    try fixture.write([
        fixture.meta(),
        discoveryMessage("进度保存在 [执行清单](docs/evidence/implementation.md#阶段一) 和 `notes/review.markdown`；普通 prose.md 不构成路径引用。"),
        discoveryMessage("[远端](https://example.invalid/tasks.md) 与 `~/outside.md`、`$WORK/tasks.md` 不应加入。")
    ])
    let service = TaskProgressDiscoveryService()
    let result = await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(result.hints.count == 2)
    let implementation = try #require(result.hints.first { $0.path.hasSuffix("implementation.md") })
    #expect(implementation.path == fixture.directory.appendingPathComponent("docs/evidence/implementation.md").path)
    #expect(implementation.sectionHint == "阶段一")
    #expect(implementation.shouldAutoBind)
    #expect(implementation.origins == [.mentioned])
    // 文件尚未生成也保留明确路径，让 Store 可以在下一次刷新重试读取。
    #expect(!FileManager.default.fileExists(atPath: implementation.path))
}

@Test func taskDiscoveryKeepsEachWrappedToolsWorkingDirectoryAndPatchOrigin() async throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.remove() }
    let first = fixture.directory.appendingPathComponent("one").path
    let second = fixture.directory.appendingPathComponent("two").path
    let patch = "*** Begin Patch\n*** Add File: docs/progress.md\n+- [ ] synthetic\n*** End Patch"
    let code = """
    const results = await Promise.all([
      tools.exec_command({cmd: "rtk proxy cat notes.md", workdir: \(try discoveryJSON(first))}),
      tools.exec_command({workdir: \(try discoveryJSON(second)), cmd: 'sed -n "1,80p" notes.md'})
    ]);
    text(await tools.apply_patch(\(try discoveryJSON(patch))));
    """
    try fixture.write([
        fixture.meta(),
        discoveryRow("response_item", ["type": "custom_tool_call", "name": "functions.exec", "input": code])
    ])
    let result = await TaskProgressDiscoveryService().scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(Set(result.hints.map(\.path)) == Set([first + "/notes.md", second + "/notes.md", fixture.directory.path + "/docs/progress.md"]))
    #expect(result.hints.filter { $0.origins == [.read] }.count == 2)
    #expect(result.hints.first { $0.path.hasSuffix("progress.md") }?.origins == [.written])
    #expect(result.hints.filter(\.shouldAutoBind).count == 1)
}

@Test func taskDiscoveryRecognizesDirectShellReadAndWritesWithoutRunningCommands() async throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.remove() }
    let directory = fixture.directory.appendingPathComponent("tool-workdir").path
    let args = try discoveryJSON(["cmd": "rtk proxy cat 'a b.md'\nprintf 'synthetic' > progress.md", "workdir": directory])
    try fixture.write([
        fixture.meta(),
        discoveryRow("response_item", ["type": "function_call", "name": "functions.exec_command", "arguments": args]),
        discoveryRow("response_item", ["type": "custom_tool_call", "name": "apply_patch", "input": "*** Begin Patch\n*** Update File: old.md\n*** Move to: renamed.md\n*** End Patch"])
    ])
    let result = await TaskProgressDiscoveryService().scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(result.hints.first { $0.path == directory + "/a b.md" }?.origins == [.read])
    #expect(result.hints.first { $0.path == directory + "/progress.md" }?.origins == [.written])
    #expect(result.hints.first { $0.path.hasSuffix("renamed.md") }?.origins == [.written])
    #expect(!FileManager.default.fileExists(atPath: directory + "/progress.md"))
}

@Test func taskDiscoveryMergesOriginsAndKeepsConflictingSectionsAmbiguous() async throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.remove() }
    try fixture.write([
        fixture.meta(),
        discoveryMessage("[清单](progress.md#第一阶段)"),
        discoveryMessage("[另一范围](progress.md#第二阶段)"),
        discoveryMessage("[再次引用](progress.md#第一阶段)"),
        discoveryRow("response_item", ["type": "custom_tool_call", "name": "apply_patch", "input": "*** Update File: progress.md\n@@\n- [ ] A"])
    ])
    let result = await TaskProgressDiscoveryService().scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    let hint = try #require(result.hints.first)
    #expect(result.hints.count == 1)
    #expect(Set(hint.origins) == Set([.mentioned, .written]))
    #expect(hint.sectionHint == nil && hint.hasConflictingSectionHints)
}

@Test func taskDiscoveryCompletesPartialLinesAndUsesUpdatedTurnDirectory() async throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.remove() }
    try fixture.write([fixture.meta(), discoveryMessage("`first.md`")])
    let service = TaskProgressDiscoveryService()
    #expect(await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false).hints.count == 1)
    let nextDirectory = fixture.directory.appendingPathComponent("next").path
    try fixture.append(discoveryRow("turn_context", ["cwd": nextDirectory]))
    let next = try discoveryMessage("`later.md`")
    try fixture.append(next.dropLast(3))
    let partial = await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(partial.hints.count == 1)
    try fixture.append(next.suffix(3))
    let complete = await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(complete.hints.count == 2)
    #expect(complete.hints.contains { $0.path == nextDirectory + "/later.md" })
    let repeated = await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(repeated.hints == complete.hints)
}

@Test func taskDiscoveryRejectsWrongThreadAndSeparatesInheritedRecords() async throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.remove() }
    try fixture.write([
        fixture.meta(extra: ["parent_thread_id": discoveryOtherThread]),
        discoveryMessage("`inherited-before-boundary.md`"),
        fixture.meta(id: discoveryOtherThread, cwd: "/synthetic/parent"),
        discoveryMessage("`parent-only.md`"),
        discoveryRow("world_state", [:]),
        discoveryRow("turn_context", ["cwd": fixture.directory.path]),
        discoveryMessage("`own.md`", owner: discoveryThread),
        discoveryMessage("`other-thread.md`", owner: discoveryOtherThread)
    ])
    let service = TaskProgressDiscoveryService()
    let own = await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(own.hints.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["own.md"])
    let mismatch = await service.scan(threadID: "not-present-in-log", rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(mismatch.hints.isEmpty)
    #expect(mismatch.workspacePath == nil)
    #expect(mismatch.message != nil)
}

@Test func taskDiscoveryDoesNotReuseHintsAcrossTwoThreadsInOneWorkspace() async throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.remove() }
    try fixture.write([fixture.meta(), discoveryMessage("`one.md`")])
    let other = fixture.directory.appendingPathComponent("other-rollout.jsonl")
    try (fixture.meta(id: discoveryOtherThread) + discoveryMessage("`two.md`")).write(to: other)
    let service = TaskProgressDiscoveryService()
    let first = await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    let second = await service.scan(threadID: discoveryOtherThread, rolloutPath: other.path, includeWorkspace: false)
    #expect(first.hints.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["one.md"])
    #expect(second.hints.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["two.md"])
}

@Test func taskDiscoveryResetsForTruncationSameSizeRewriteAndAtomicReplacement() async throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.remove() }
    let service = TaskProgressDiscoveryService()
    try fixture.write([fixture.meta(), discoveryMessage("`older.md`")])
    _ = await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    try fixture.write([fixture.meta(), discoveryMessage("`newer.md`")])
    let rewritten = await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(rewritten.hints.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["newer.md"])
    try fixture.write([fixture.meta()])
    #expect(await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false).hints.isEmpty)
    try (fixture.meta() + discoveryMessage("`atomic.md`")).write(to: fixture.log, options: .atomic)
    let atomic = await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(atomic.hints.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["atomic.md"])
}

@Test func taskDiscoveryContinuesBoundedReadsAndRecoversAfterOversizedLine() async throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.remove() }
    try fixture.write([fixture.meta(), Data((String(repeating: "x", count: 900) + "\n{broken}\n").utf8), discoveryMessage("`valid.md`")])
    let service = TaskProgressDiscoveryService(maximumReadBytes: 256, maximumLineBytes: 512, scanBudget: 2)
    var result = await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(result.hasMore)
    #expect(result.hasUnreadSessionRecords)
    for _ in 0..<12 where result.hasMore {
        result = await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    }
    #expect(!result.hasMore)
    #expect(!result.hasUnreadSessionRecords)
    #expect(result.hints.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["valid.md"])
    #expect(result.message?.contains("跳过") == true)
}

@Test func taskDiscoveryOnlyScansConventionalWorkspaceDirectoriesAndSkipsArchives() async throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.remove() }
    _ = try fixture.markdown("TASKS.md")
    _ = try fixture.markdown("tasks/current.md")
    _ = try fixture.markdown("docs/tasks/nested/current.md")
    _ = try fixture.markdown("docs/tasks/archive/old.md")
    _ = try fixture.markdown("README.md")
    _ = try fixture.markdown("docs/notes.md")
    _ = try fixture.markdown("node_modules/package/tasks.md")
    try FileManager.default.createSymbolicLink(at: fixture.directory.appendingPathComponent("tasks/linked"),
        withDestinationURL: fixture.directory.appendingPathComponent("docs"))
    let service = TaskProgressDiscoveryService(scanBudget: 2)
    let result = await service.scan(threadID: discoveryThread, rolloutPath: nil, workspacePath: fixture.directory.path)
    #expect(result.hints.count == 3)
    #expect(result.hints.allSatisfy { $0.origins == [.workspace] && !$0.shouldAutoBind })
    #expect(!result.hints.contains { $0.path.contains("archive") || $0.path.contains("linked") })
    let manual = await service.scanDirectory(path: fixture.directory.path)
    #expect(manual.hints.count == 5)
    #expect(manual.hints.contains { $0.path.hasSuffix("README.md") })
    #expect(!manual.hints.contains { $0.path.contains("node_modules") })
}

@Test func taskDiscoveryDirectoryBudgetIsExplicitAndLogSymlinkIsRejected() async throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.remove() }
    for index in 0..<8 { _ = try fixture.markdown("tasks/\(index).md") }
    let service = TaskProgressDiscoveryService(maximumDirectoryCandidates: 2, scanBudget: 2)
    let result = await service.scanDirectory(path: fixture.directory.appendingPathComponent("tasks").path)
    #expect(result.hints.count == 2)
    #expect(result.hasMore)
    #expect(!result.hasUnreadSessionRecords)
    #expect(result.message?.contains("上限") == true)
    let other = fixture.directory.appendingPathComponent("external.jsonl")
    try (fixture.meta() + discoveryMessage("`outside.md`")).write(to: other)
    try FileManager.default.createSymbolicLink(at: fixture.log, withDestinationURL: other)
    let symlink = await service.scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(symlink.hints.isEmpty)
}

@Test func taskDiscoveryIgnoresDynamicCommandsCommentsAndToolOutput() async throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.remove() }
    let code = #"""
    // tools.exec_command({cmd: "cat commented.md"});
    const note = 'tools.exec_command({cmd: "cat quoted.md"})';
    tools.exec_command({cmd: "cat " + "dynamic.md"});
    tools.exec_command({cmd: "cat wrong-base.md", workdir: "$ROOT"});
    tools.exec_command({cmd: "cat $TASK.md *.md"});
    """#
    try fixture.write([
        fixture.meta(),
        discoveryRow("response_item", ["type": "custom_tool_call", "name": "exec", "input": code]),
        discoveryRow("response_item", ["type": "function_call", "name": "exec_command", "arguments": try discoveryJSON(["cmd": "cd /unknown && cat wrong.md"])]),
        discoveryRow("response_item", ["type": "function_call_output", "output": "`tool-output.md`"])
    ])
    let result = await TaskProgressDiscoveryService().scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(result.hints.isEmpty)
}

@Test func taskDiscoveryRetainsRecentUniqueHintsWithinLimit() async throws {
    let fixture = try DiscoveryFixture()
    defer { fixture.remove() }
    try fixture.write([fixture.meta(), discoveryMessage("`one.md` `two.md` `one.md` `three.md`")])
    let result = await TaskProgressDiscoveryService(maximumHints: 2).scan(threadID: discoveryThread, rolloutPath: fixture.log.path, includeWorkspace: false)
    #expect(Set(result.hints.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == Set(["one.md", "three.md"]))
    #expect(result.message?.contains("上限") == true)
}
