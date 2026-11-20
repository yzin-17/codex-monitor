import AppKit
import SwiftUI
import Testing
@testable import CodexNotch

@Test @MainActor func taskProgressThreeTabsRenderWithAutomaticAndCandidateDocuments() async throws {
    guard let path = ProcessInfo.processInfo.environment["CODEX_MONITOR_SNAPSHOT_DIR"] else { return }
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("progress-presentation-\(UUID())")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("tasks"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("implementation.md")
    try """
    # 当前实施
    - [x] T1 接入任务会话上下文
    - [x] T2 增量发现进度文档
    - [ ] T3 验证自动绑定和手动排除
      - 状态：验证中
    - [ ] T4 检查拖拽排序与跨行移动
    # 后续工作
    - [ ] T5 检查较长标题和多文档布局
    """.write(to: first, atomically: true, encoding: .utf8)
    let second = directory.appendingPathComponent("review.md")
    try "# 复核\n- [x] R1 保留账号绑定\n- [ ] R2 验证原生窗口交互\n".write(to: second, atomically: true, encoding: .utf8)
    try "# 项目历史清单\n- [ ] H1 由用户决定是否关联当前任务\n"
        .write(to: directory.appendingPathComponent("tasks/history.md"), atomically: true, encoding: .utf8)
    let threadID = "44444444-4444-4444-8444-444444444444"
    let log = directory.appendingPathComponent("rollout-\(threadID).jsonl")
    let records: [[String: Any]] = [
        ["type": "session_meta", "payload": ["id": threadID, "cwd": directory.path]],
        ["type": "event_msg", "payload": ["type": "agent_message",
            "message": "任务进度：[实施](implementation.md) 与 [复核](review.md)"]]
    ]
    var data = Data()
    for record in records {
        data.append(try JSONSerialization.data(withJSONObject: record)); data.append(0x0A)
    }
    try data.write(to: log)
    let store = TaskProgressStore(codexHome: directory.path, automatic: false,
        storageDirectory: directory.appendingPathComponent("state"), reader: .init(stabilityNanoseconds: 0))
    defer { store.stop() }
    store.setTasks([.init(id: threadID, title: "改进任务进度发现、自动绑定与自定义布局交互",
        status: .running, detailPrefix: "合成数据", tokenCount: 0, updatedAt: Date(), rolloutPath: log.path)])
    await store.discoverAndWait(threadID: threadID, force: true)
    #expect(store.bindings(for: threadID).count == 2)
    #expect(store.discoveryState(for: threadID).candidates.count == 3)
    let output = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for tab in TaskProgressPanelTab.allCases {
        let host = NSHostingView(rootView: TaskProgressPanel(store: store, threadID: threadID, initialTab: tab, close: {})
            .environment(\.colorScheme, .dark))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = .init(x: 0, y: 0, width: 460, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let name: String
        switch tab { case .tasks: name = "checklist"; case .documents: name = "documents"; case .settings: name = "settings" }
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("task-progress-\(name).png"))
        #expect(bitmap.pixelsWide >= 460 && bitmap.pixelsHigh >= 560)
    }
}
