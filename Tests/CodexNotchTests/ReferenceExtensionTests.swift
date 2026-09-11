import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexNotch

private struct ReferenceLoginManager: LaunchAtLoginManaging {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws {}
}

@MainActor private func referenceSettings(_ defaults: UserDefaults) -> CodexNotchSettings {
    CodexNotchSettings(defaults: defaults, initialManagementKey: "", initialNewAPIKey: "", initialSubAPIKey: "",
        secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
        launchAtLoginManager: ReferenceLoginManager(), loadSecretsSynchronously: true)
}

@Test @MainActor func referenceExtensionSettingsPersistAndDoNotEnableRemoteSources() throws {
    let suite = "reference-settings-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = referenceSettings(defaults)
    #expect(settings.skillInsightsEnabled)
    #expect(!settings.performanceMonitoringEnabled)
    #expect(!settings.codexRadarEnabled)
    #expect(!settings.remoteMonitorEnabled)
    settings.skillInsightsEnabled = false
    settings.performanceMonitoringEnabled = true
    let reloaded = referenceSettings(defaults)
    #expect(!reloaded.skillInsightsEnabled)
    #expect(reloaded.performanceMonitoringEnabled)
    #expect(DetailPage.allCases.map(\.title) == ["Codex", "性能", "Skills", "Codex Radar", "重置预测", "远程账号", "NewAPI", "Sub2API"])
}

@Test func referencePerformanceCadenceRemainsBounded() {
    let normal = RefreshEnvironment(isLowPowerModeEnabled: false, isThermallyConstrained: false)
    let low = RefreshEnvironment(isLowPowerModeEnabled: true, isThermallyConstrained: false)
    #expect(PerformanceCadencePolicy.interval(isVisible: false, samplingEnabled: false, environment: normal) == nil)
    #expect(PerformanceCadencePolicy.interval(isVisible: true, samplingEnabled: false, environment: normal) == 5)
    #expect(PerformanceCadencePolicy.interval(isVisible: false, samplingEnabled: true, environment: normal) == 60)
    #expect(PerformanceCadencePolicy.interval(isVisible: true, samplingEnabled: true, environment: low) == 300)
}

private func referenceProcessSample(now: Date = Date()) -> PerformanceSample {
    let rows = PerformanceSampler.parseProcessList("""
    100 1 10.0 400000 /Applications/Codex.app/Contents/MacOS/Codex
    101 100 20.0 200000 /usr/bin/worker
    200 1 2.0 180000 /Applications/Safari.app/Contents/MacOS/Safari
    301 1 12.0 250000 /System/Library/Frameworks/WebKit.framework/WebContent
    400 1 8.0 120000 /System/Library/PrivateFrameworks/SkyLight.framework/WindowServer
    invalid row
    """)
    return PerformanceSampler.makeSample(records: rows, memoryFreePercent: 72, capturedAt: now)
}

@Test func referencePerformanceUsesRealParserAndProcessTree() {
    let sample = referenceProcessSample()
    #expect(sample.chatGPT.processCount == 2)
    #expect(sample.chatGPT.cpuPercent == 30)
    #expect(sample.webKitContent.pid == 301)
    #expect(sample.windowServer.cpuPercent == 8)
    #expect(PerformanceSampler.parseMemoryFreePercent("System-wide memory free percentage: 77%") == 77)
    #expect(PerformanceSampler.parseMemoryFreePercent("unavailable") == nil)
}

@Test func referencePerformanceHistoryOmitsPathsAndText() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ref-performance-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = PerformanceHistoryStore(logURL: dir.appendingPathComponent("sample.jsonl"))
    store.record(referenceProcessSample())
    let data = store.recentData(limit: 10)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("/Applications/"))
    #expect(!text.contains("worker"))
    #expect(store.recentSamples().count == 1)
}

private func referenceCatalog(at now: Date) throws -> SkillCatalogSnapshot {
    try CodexSkillsAppServerClient.parseSkillsListResponse(Data(#"""
    {"id":2,"result":{"data":[{"cwd":"/fixture","skills":[
    {"name":"review","description":"review code changes safely","path":"/fixture/skills/review/SKILL.md","enabled":true},
    {"name":"planning","description":"plan a bounded task","path":"/fixture/skills/planning/SKILL.md","enabled":false}
    ],"errors":[]}]}}
    """#.utf8), loadedAt: now)
}

@Test func referenceSkillsCatalogUsesAuthoritativeStates() throws {
    let catalog = try referenceCatalog(at: Date())
    #expect(catalog.quality == .complete)
    #expect(catalog.enabledCount == 1)
    #expect(catalog.disabledCount == 1)
    #expect(catalog.skills.first(where: { $0.name == "review" })?.enabled == true)
}

@Test func referenceSkillsCatalogRejectsInvalidEnvelope() {
    #expect(throws: (any Error).self) {
        try CodexSkillsAppServerClient.parseSkillsListResponse(Data("{}".utf8), loadedAt: Date())
    }
}

@Test func referenceSkillReaderResumesHalfLine() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ref-reader-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("sample.jsonl")
    let first = Data("{\"type\":\"event_msg\"}\n{\"type\":".utf8)
    try first.write(to: file)
    let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
    var offsets: [UInt64] = []
    let result = try SkillJSONLReader.read(handle: handle, startOffset: 0, fileSize: UInt64(first.count),
        byteBudget: 100000, maxRowBytes: 8192, initialDiscardingOversizedRow: false,
        wallDeadlineUptime: .greatestFiniteMagnitude, cpuDeadlineNanoseconds: .max,
        shouldCancel: { false }, classify: { _ in .parse }, process: { _, offset in offsets.append(offset) })
    #expect(offsets == [0])
    #expect(result.hasIncompleteRow)
    #expect(result.processedOffset < UInt64(first.count))
}

@Test func referenceSkillsAnalyzerKeepsEvidenceLocalAndIncremental() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ref-skills-\(UUID())")
    let home = dir.appendingPathComponent("codex"); let sessions = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date(); let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-20))
    let file = sessions.appendingPathComponent("rollout-11111111-1111-4111-8111-111111111111.jsonl")
    let content = """
    {"timestamp":"\(stamp)","type":"session_meta","payload":{"id":"11111111-1111-4111-8111-111111111111","cwd":"/fixture"}}
    {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"user_message","message":"请使用 $review 检查修改 PRIVATE_SENTINEL"}}
    {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"task_complete"}}

    """
    try Data(content.utf8).write(to: file)
    let catalog = try referenceCatalog(at: now)
    let store = SkillObservationStore(databaseURL: dir.appendingPathComponent("derived/skills.sqlite"))
    let analyzer = SkillSessionAnalyzer(codexDirectory: home, observationStore: store)
    let first = analyzer.analyze(catalog: catalog, now: now)
    #expect(!first.wasCancelled)
    #expect(first.performance.analyzedFiles == 1)
    let snapshot = store.buildSnapshot(catalog: catalog, now: now)
    #expect((snapshot.rows.first(where: { $0.skill.name == "review" })?.directCount ?? 0) > 0)
    let second = analyzer.analyze(catalog: catalog, now: now)
    #expect(second.performance.analyzedBytes == 0)
    let exported = try SkillInsightsService(codexDirectory: home, skillRoots: [], databaseURL: dir.appendingPathComponent("export.sqlite")).export(snapshot, format: .json)
    #expect(!String(decoding: exported, as: UTF8.self).contains("PRIVATE_SENTINEL"))
    #expect(SkillInsightsReportRenderer.markdown(snapshot).contains("Per-Skill Token: UNAVAILABLE"))
}

@Test func referenceSkillsCancellationDoesNotScan() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ref-cancel-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SkillObservationStore(databaseURL: dir.appendingPathComponent("skills.sqlite"))
    let analyzer = SkillSessionAnalyzer(codexDirectory: dir, observationStore: store)
    let result = analyzer.analyze(catalog: try referenceCatalog(at: Date()), shouldCancel: { true })
    #expect(result.wasCancelled)
    #expect(result.performance.analyzedBytes == 0)
}

@MainActor private func referenceSkillSnapshot() throws -> SkillInsightsSnapshot {
    let now = Date(); let catalog = try referenceCatalog(at: now)
    let rows = catalog.skills.map { skill in
        SkillInsightRow(skill: skill, directCount: skill.enabled ? 3 : 0, strongCount: skill.enabled ? 2 : 0,
            inferredCount: 0, shadowCount: skill.enabled ? 0 : 1, suspectedMissCount: 0,
            suspectedMisfireCount: 0, replacedByExistingCount: 0, relatedSessionCount: 3,
            relatedSessionTokens: 120000, recommendation: .continueObserving, evidenceQuality: .complete)
    }
    return SkillInsightsSnapshot(schemaVersion: 2, windowStartedAt: now.addingTimeInterval(-604800), windowEndedAt: now,
        enabledSkillCount: 1, disabledSkillCount: 1, enabledCatalogTokenEstimate: catalog.enabledCatalogTokenEstimate,
        confirmedUseCount: 5, suspectedMissCount: 0, suspectedMisfireCount: 0, shadowHitCount: 1, retestCount: 0,
        quality: .complete, lastAnalyzedAt: now, rows: rows, performance: .empty, diagnostics: [],
        unverified: ["合成演示数据，不代表真实账户"])
}

@Test @MainActor func referenceNativeTabsRenderFromActualUpstreamViews() async throws {
    _ = NSApplication.shared
    let suite = "reference-render-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = referenceSettings(defaults)
    let usage = UsageViewModel(settings: settings, previewSnapshot: NotchOverlayController.visualQASnapshot())
    var radarData = CodexRadarSnapshot.disabled
    radarData.state = .ready
    radarData.models = [
        .init(id: "demo-a", label: "Demo Max", score: 135, status: "complete", passed: 9, tasks: 10, costUSD: 6.4, wallTime: "24 分钟"),
        .init(id: "demo-b", label: "Demo Medium", score: 105, status: "complete", passed: 7, tasks: 10, costUSD: 2.3, wallTime: "12 分钟")
    ]
    radarData.monitoredAt = Date(); radarData.fetchedAt = Date(); radarData.message = nil
    radarData.recommendation = "合成示例 · 保留原版 Radar 界面，未发出网络请求"
    let radar = CodexRadarViewModel(settings: settings, previewSnapshot: radarData)
    let perf = PerformanceMonitorViewModel(settings: settings, previewSamples: [referenceProcessSample()])
    let skills = SkillInsightsFeatureCoordinator(previewSnapshot: try referenceSkillSnapshot())
    let remote = RemoteMonitorViewModel(settings: settings)
    let newAPI = BalanceMonitorViewModel(source: .newAPI, settings: settings)
    let subAPI = BalanceMonitorViewModel(source: .subAPI, settings: settings)
    usage.publicInsights.installPreview([
        .init(source: .openAIStatus, fetchedAt: Date(), updatedAt: Date(), summary: "All Systems Operational",
              components: [.init(id: "api", name: "Codex API", state: "operational"),
                           .init(id: "desktop", name: "Codex in ChatGPT Desktop", state: "operational")], overallIndicator: "none"),
        .init(source: .observatory, fetchedAt: Date(), updatedAt: Date(), summary: "合成数据：根据公开历史和信号生成的社区概率，仅供参考。", probabilities: [12:20, 24:38, 48:69, 72:83], announcement: "无明确重置预告"),
        .init(source: .willReset, fetchedAt: Date(), updatedAt: Date(), summary: "合成数据：未校准的社区评分，不代表可靠发生率。", probabilities: [48:23])
    ])
    let overlay = OverlayState(); overlay.isExpanded = true; overlay.setDetailPresentationPhase(.visible)
    let output = ProcessInfo.processInfo.environment["CODEX_MONITOR_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    for (page, expanded) in [(DetailPage.codex, false), (.performance, false), (.skills, false), (.codexRadar, false), (.resetPrediction, false), (.remoteCodex, false), (.codex, true)] {
        let firstTask = usage.snapshot.tasks[0]
        let childUsage = usage.snapshot.tasks[1].tokenUsage
        let sample = ConversationCostDetails(rootID: firstTask.id,
            agents: [
                .init(id: firstTask.id, parentID: nil, depth: 0, model: "gpt-5.6-sol", usage: firstTask.tokenUsage, hasUsage: true, complete: true),
                .init(id: "demo-child", parentID: firstTask.id, depth: 1, model: "gpt-5.6-luna", usage: childUsage, hasUsage: true, complete: true)
            ], skills: [.init(id: "/synthetic/skills/code-review/SKILL.md", name: "code-review", usage: childUsage, turns: 1, agentIDs: ["demo-child"])],
            pending: false, diagnostics: [], observedAt: Date())
        let view = DetailPanelView(viewModel: usage, remoteViewModel: remote, newAPIViewModel: newAPI,
            subAPIViewModel: subAPI, codexRadarViewModel: radar, performanceViewModel: perf,
            skillInsights: skills, overlayState: overlay, settings: settings, onSettings: {},
            onLocalRefresh: {}, onRemoteRefresh: {}, onNewAPIRefresh: {}, onSubAPIRefresh: {},
            onCodexRadarRefresh: {}, initialPage: page,
            initialExpandedTaskID: expanded ? firstTask.id : nil, previewCosts: expanded ? [firstTask.id: sample] : [:])
        let content = VStack(spacing: 0) {
            Text("原生 SwiftUI · 合成数据 · \(page.title)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).padding(6)
            view
        }.frame(width: 680, height: 746).background(Color.black).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let measured = try #require(renderer.cgImage)
        let size = NSSize(width: CGFloat(measured.width) / renderer.scale, height: CGFloat(measured.height) / renderer.scale)
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(size)
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 300)
        #expect(bitmap.pixelsHigh >= 400)
        if let output {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(expanded ? "conversation-costs.png" : "\(page.rawValue).png"))
        }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    // 自定义布局与提供商页也走同一生产 View；仅注入合成数据及内存凭据库。
    let previewStore = CodexAccountsStore(defaults: defaults,
        vault: .init(read: { _, _ in "synthetic-only" }, write: { _, _ in }, delete: { _ in }),
        client: .init(fetch: { _ in
            Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":54,"limit_window_seconds":18000},"secondary_window":{"used_percent":21,"limit_window_seconds":604800}}}"#.utf8)
        }), automaticStart: false)
    try await previewStore.verifyAndSave(.init(label: "合成示例 · 工作账号"), token: "synthetic-only")
    try await previewStore.verifyAndSave(.init(label: "合成示例 · 个人账号"), token: "synthetic-only")
    #expect(previewStore.states.values.filter { $0.usage != nil }.count == 2)
    let prefs = settings.hudPreferences
    prefs.value.mode = .menuBar
    prefs.value.layout = .detailed
    let hud = ConfigurableHUDView(preferences: prefs, accounts: previewStore, usage: usage,
        remote: remote, newAPI: newAPI, subAPI: subAPI, settings: settings, publicInsights: usage.publicInsights, menuBar: true)
    try await captureCustomization(AnyView(hud), size: .init(width: 220, height: MenuBarMetrics.height()), name: "hud-menu-bar", output: output)
    // 切换右侧来源后，本机运行指示不被账户状态替换；清空布局也只清空右侧。
    prefs.value.sourceID = previewStore.accounts[0].hudID
    #expect(hud.data.state == "OFF")
    #expect(usage.snapshot.isRunning)
    prefs.value.maximumWidth = 360
    prefs.value.layout = .init(lines: [["primary", "space:8", "weekly", "tokensToday"]])
    prefs.value.sourceID = "local"
    try await captureCustomization(AnyView(hud), size: .init(width: 360, height: MenuBarMetrics.height()), name: "hud-fixed-status", output: output)
    prefs.value.layout = .init(lines: [[]])
    try await captureCustomization(AnyView(hud), size: .init(width: 100, height: MenuBarMetrics.height()), name: "hud-status-only", output: output)
    prefs.value.layout = .detailed
    prefs.value.maximumWidth = 220
    // 覆盖式 NSPanel 浮窗，实际菜单高度内，没有创建 NSStatusItem。
    let floatFrame = FloatingHUDGeometry.frame(screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
        menuBarHeight: 24, contentSize: CGSize(width: 180, height: 20), maximumWidth: 220, position: 0.5)
    #expect(floatFrame.height <= 24 && floatFrame.width == 180)
    let floating = NSPanel(contentRect: floatFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    floating.isReleasedWhenClosed = false
    floating.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    #expect(floating.styleMask.contains(.nonactivatingPanel))
    #expect(floating.level.rawValue > NSWindow.Level.statusBar.rawValue)
    floating.close()
    let editor = Form {
        HUDLayoutEditorView(preferences: prefs, accounts: previewStore, remote: remote, newAPI: newAPI, subAPI: subAPI)
    }.formStyle(.grouped)
    try await captureCustomization(AnyView(editor), size: .init(width: 710, height: 1020), name: "hud-layout", output: output)
    let providerPanel = VStack(alignment: .leading) {
        Text("原生界面 · 合成数据 · 非真实账户").font(.caption).foregroundStyle(.secondary)
        CodexAccountsPanel(store: previewStore, preferences: prefs, onSettings: {})
        Spacer()
    }.padding(18).background(Color.black)
    try await captureCustomization(AnyView(providerPanel), size: .init(width: 680, height: 520), name: "codex-accounts", output: output)
    let resumeID = "11111111-1111-4111-8111-111111111111"
    let resume = CLIResumeStore(home: URL(fileURLWithPath: "/synthetic/codex"), defaults: defaults, automatic: false,
        inspector: { _, _, _ in .init(context: .init(threadID: resumeID, path: "/synthetic/log", cwd: "/synthetic/project", model: "gpt-test", effort: "high", sandbox: "workspace-write", approval: "on-request", fileSize: 0, modifiedAt: Date()), identity: .init(workspaceID: "synthetic-workspace", subject: "synthetic-user", label: "合成示例账号"), lastTurnID: "synthetic-turn", quotaPaused: true, lastTurnStatus: "failed", usage: .init(quotas: [.init(id: "primary_window", label: "5h", usedPercent: 100, resetsAt: Date().addingTimeInterval(3600), durationSeconds: 18000)]), checkedAt: Date()) },
        runner: { _, _, _ in })
    resume.prepare(resumeID)
    try await Task.sleep(for: .milliseconds(100))
    try await captureCustomization(AnyView(VStack(alignment: .leading) {
        Text("原生 SwiftUI · 合成数据 · 不执行真实 CLI").font(.caption).foregroundStyle(MonitorTheme.textSecondary)
        CLIResumeControl(threadID: resumeID, store: resume)
        Spacer()
    }.padding(16).background(Color.black)), size: .init(width: 680, height: 440), name: "cli-resume", output: output)
    await resume.shutdown()
    previewStore.stop()
    await usage.shutdownExtensions()
}

@MainActor private func captureCustomization(_ view: AnyView, size: NSSize, name: String, output: URL?) async throws {
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.setContentSize(size)
    window.orderFrontRegardless(); host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    if name == "hud-menu-bar" {
        #expect(host.bounds.height == MenuBarMetrics.height())
        #expect(window.contentView?.bounds.height == host.bounds.height)
    }
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let output {
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent(name + ".png"))
    }
    window.orderOut(nil); window.contentView = nil; window.close()
}
