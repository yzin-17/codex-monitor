import AppKit
import SwiftUI
import CodexMonitorCore

/// 只渲染固定的合成数据，既不读取用户配置，也不启动扫描器。
/// 可用于 CI 截图复核；不是用户真实桌面交互的自动验收。
@MainActor
enum MonitorSnapshots {
    static func write(to directory: URL) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(preview: true)
        store.demo = true
        store.snapshot = fixture()
        try capture(RootView(store: store), size: CGSize(width: 760, height: 744), to: directory.appendingPathComponent("codex.png"))
        try capture(RootView(store: store, initialTab: .skills), size: CGSize(width: 760, height: 744), to: directory.appendingPathComponent("skills.png"))
        try capture(RootView(store: store), size: CGSize(width: 640, height: 660), to: directory.appendingPathComponent("compact.png"))
        try capture(HUDSummary(store: store), size: CGSize(width: 390, height: 44), to: directory.appendingPathComponent("hud.png"))
        store.demo = false; store.snapshot = LedgerSnapshot()
        try capture(RootView(store: store), size: CGSize(width: 760, height: 744), to: directory.appendingPathComponent("empty.png"))
        print("已生成 5 张原生 SwiftUI 截图，仅使用合成数据。")
    }
    private static func capture<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(MonitorTheme.background)
        window.contentView = host
        window.orderFront(nil)
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
        window.orderOut(nil); window.close()
    }
    private static func fixture() -> LedgerSnapshot {
        let now = Date()
        let skills = [
            ("swiftui-layout", "还原紧凑的原生监控面板"), ("test-driven-development", "为修改添加回归测试"),
            ("code-review", "核对模块边界与数据口径"), ("systematic-debugging", "依据错误与证据排查问题"),
            ("documentation", "维护中文规格与任务文档"), ("release-check", "校验构建与安装包")
        ].map { Skill(name: $0.0, description: $0.1, path: "/demo/skills/\($0.0)/SKILL.md", scope: "演示", stateSource: "合成数据，生效状态未知") }
        let titles = ["重构任务列表与监控面板", "检查 macOS 构建与安装", "完善 Skills 证据分析", "核对父子代理用量", "更新文档与测试"]
        var sessions = titles.enumerated().map { index, title in
            let today = Int64([128_600_000, 9_390_000, 96_700_000, 38_220_000, 700_000][index])
            let old = Int64([240_000_000, 6_000_000, 310_000_000, 12_000_000, 40_000][index])
            let model = index.isMultiple(of: 2) ? "demo-parent" : "demo-worker"
            let own = [UsageSample(id: "today-\(index)", date: now.addingTimeInterval(-45), turnID: "turn-\(index)", model: model, tokens: Tokens(input: today, cached: today * 3 / 4, output: today / 10)),
                       UsageSample(id: "history-\(index)", date: now.addingTimeInterval(-3 * 86400), turnID: "old-\(index)", model: model, tokens: Tokens(input: old, cached: old / 2, output: old / 10))]
            return Session(id: "demo-\(index)", title: title, samples: own,
                           status: index == 0 ? "日志显示运行中" : "已完成", lastActivity: now.addingTimeInterval(-45))
        }
        sessions.append(Session(id: "demo-child", title: "组件测试", parentID: "demo-0", isSubagent: true,
                                samples: [UsageSample(id: "child-use", date: now.addingTimeInterval(-50), turnID: "child-turn", model: "demo-worker", tokens: Tokens(input: 22_000_000, cached: 18_000_000, output: 1_200_000))], status: "已完成", lastActivity: now))
        for (i, skill) in skills.enumerated() where i < 5 {
            for n in 0..<(5 - i) {
                sessions[i].evidence.append(SkillEvidence(id: "e-\(i)-\(n)", sessionID: sessions[i].id, turnID: "t-\(n)", name: skill.name, path: skill.path, kind: n.isMultiple(of: 3) ? .requested : .fileRead, date: now.addingTimeInterval(Double(-n * 300 - i * 900)), sourceOffset: UInt64(n * 1024)))
            }
        }
        let quotaJSON = """
        [{"id":"codex:primary","minutes":300,"usedPercent":54,"resetsAt":\(now.addingTimeInterval(1380).timeIntervalSince1970),"observedAt":\(now.timeIntervalSince1970)},
        {"id":"codex:secondary","minutes":10080,"usedPercent":21,"resetsAt":\(now.addingTimeInterval(4 * 86400).timeIntervalSince1970),"observedAt":\(now.timeIntervalSince1970)}]
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        sessions[0].quotas = (try? decoder.decode([QuotaWindow].self, from: Data(quotaJSON.utf8))) ?? []
        var progress = ScanProgress(); progress.files = 6; progress.caughtUp = 6
        return LedgerSnapshot(sessions: sessions, skills: skills, progress: progress, createdAt: now, isDemo: true)
    }
}
