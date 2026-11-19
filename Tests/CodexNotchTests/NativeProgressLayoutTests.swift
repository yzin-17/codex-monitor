import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexNotch

@Test func tokenSpeedHUDRemainsSourceBoundAndUsesFreshSamplesForConditions() {
    let now = Date()
    var data = HUDEntityData()
    #expect(data.text(.tokensPerSecond, remaining: true, now: now) == "— token/s")
    #expect(data.numeric(.tokensPerSecond, now: now) == nil)
    data.tokenRate = .init(value: 68.4, measuredAt: now, measuredCount: 1, activeCount: 2)
    #expect(data.text(.tokensPerSecond, remaining: true, now: now) == "68.4 token/s")
    #expect(data.numeric(.tokensPerSecond, remaining: true, now: now) == 68.4)
    #expect(data.numeric(.tokensPerSecond, remaining: false, now: now) == 68.4)
    #expect(data.display(.tokensPerSecond, remaining: true, now: now.addingTimeInterval(16)).tone == .tertiary)
    #expect(data.numeric(.tokensPerSecond, now: now.addingTimeInterval(16)) == nil)

    let id = UUID().uuidString
    let rule = HUDConditional(predicates: [.init(metric: .tokensPerSecond, threshold: 50)],
                              thenMetric: .tokensPerSecond, elseMetric: .hidden)
    let layout = HUDLayout(lines: [["conditional:" + id]], conditionals: [id: rule])
    data.warning = "本机额度暂不可用"
    #expect(data.resolvedMetric(raw: "conditional:" + id, layout: layout, now: now) == .tokensPerSecond)
    #expect(data.resolvedMetric(raw: "conditional:" + id, layout: layout, now: now.addingTimeInterval(16)) == nil)
    let bound = HUDLayout(lines: [[]]).inserting(.tokensPerSecond, row: 0, sourceID: "local")
    #expect(bound.lines == [["tokensPerSecond@@local"]])
    #expect(HUDMetric.palette.contains(.tokensPerSecond))
}

@MainActor private func captureProgressView<V: View>(_ view: V, size: CGSize, name: String) async throws {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    #expect(bitmap.pixelsWide >= Int(size.width))
    #expect(bitmap.pixelsHigh >= Int(size.height))
    if let path = ProcessInfo.processInfo.environment["CODEX_MONITOR_SNAPSHOT_DIR"] {
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
}

@Test @MainActor func nativeTaskProgressAndLongTitlesRenderInExistingRows() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-progress-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("tasks.md")
    try """
    # 研究与复盘
    - [x] 确认策略定义
    - [x] 补充结构化输出校验
    - [ ] 验证入场后保护单
      - 状态：验证中
    - [ ] 检查窄屏布局
    """.write(to: file, atomically: true, encoding: .utf8)
    let store = TaskProgressStore(codexHome: directory.path, automatic: false,
        storageDirectory: directory.appendingPathComponent("bindings"), reader: .init(stabilityNanoseconds: 0))
    defer { store.stop() }
    let id = "11111111-1111-4111-8111-111111111111"
    try store.replaceBindings(threadID: id, with: [.init(id: UUID(), path: file.path, scope: .document)])
    await store.refreshAndWait(threadID: id)
    #expect(store.summary(for: id).completed == 2)
    #expect(store.summary(for: id).total == 4)

    let suite = "native-progress-layout-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let resume = CLIResumeStore(home: directory, defaults: defaults, automatic: false)
    let titles = [
        "请直接在当前 ThesisLedger 本地工作区实施「研究详情与投资复盘阅读布局优化」，先读仓库规范并验证现有逻辑",
        "VeryLongTaskTitleWithoutAnySpacesToCheckTruncationAndStableStatusWidthInTheMonitorPanel",
        "自然语言策略契约 🧪 验证与持久化并行实施"
    ]
    let states: [TaskStatus] = [.recent, .running, .idle]
    let rows = zip(titles, states).map { title, state in
        CodexTask(id: id, title: title, status: state, detailPrefix: "gpt-6.2-astra · 高推理",
                  tokenCount: 490_000_000, updatedAt: Date(), activeSubagentCount: 3)
    }
    func row(_ task: CodexTask) -> some View {
        TaskRow(task: task, now: Date(), isExpanded: false, skillsEnabled: false,
                conversationCostDetail: nil, displayedConversationCost: .init(usage: task.tokenUsage, confidence: .lowerBound),
                conversationCostLoading: false, conversationCostError: nil,
                onConversationCostLoad: {}, onConversationCostRefresh: {},
                resumeStore: resume, progressStore: store, codexAccounts: [], onToggle: {})
    }
    for width: CGFloat in [480, 680] {
        for task in rows {
            let image = ImageRenderer(content: row(task).frame(width: width).environment(\.colorScheme, .dark))
            image.scale = 1
            let cgImage = try #require(image.cgImage)
            // 标题/状态仍在单行；进度摘要不增加第三行。
            #expect(cgImage.height <= 54)
        }
    }
    let list = VStack(spacing: 8) {
        Text("任务状态与原生进度 · 合成数据").font(.system(size: 12)).foregroundStyle(.white)
        ForEach(Array(rows.enumerated()), id: \.offset) { _, task in row(task) }
    }.padding(12).frame(width: 520).background(Color.black)
    try await captureProgressView(list, size: .init(width: 520, height: 218), name: "task-row-long-title")
    try await captureProgressView(TaskProgressPanel(store: store, threadID: id, close: {}).background(Color.black),
                                  size: .init(width: 492, height: 450), name: "task-progress")
}

@Test @MainActor func tokenSpeedHUDRendersFreshEstimatedAndStaleStates() async throws {
    let now = Date()
    let samples: [(String, TokenRateSummary)] = [
        ("有效样本", .init(value: 68.4, measuredAt: now, measuredCount: 1, activeCount: 1)),
        ("增量估算", .init(value: 52.8, measuredAt: now, isEstimate: true, measuredCount: 1, activeCount: 1)),
        ("最近测量", .init(value: 68.4, measuredAt: now.addingTimeInterval(-20), isStale: true)),
        ("没有数据", .unavailable)
    ]
    let layout = HUDLayout(lines: [["tokensPerSecond"]])
    var fresh = HUDEntityData(); fresh.tokenRate = samples[0].1
    var unknown = HUDEntityData(); unknown.tokenRate = .unavailable
    #expect(HUDMetricStrip.measuredWidth(layout: layout, data: fresh, remaining: true, menuBar: false)
        == HUDMetricStrip.measuredWidth(layout: layout, data: unknown, remaining: true, menuBar: false))
    let view = VStack(alignment: .leading, spacing: 16) {
        ForEach(Array(samples.enumerated()), id: \.offset) { _, entry in
            HStack {
                Text(entry.0).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                Spacer()
                HUDMetricStrip(layout: layout, data: HUDEntityData(tokenRate: entry.1))
            }
        }
    }.padding(20).frame(width: 300).background(Color.black)
    try await captureProgressView(view, size: .init(width: 300, height: 160), name: "hud-token-rate")
}
