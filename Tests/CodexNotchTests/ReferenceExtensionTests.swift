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
    #expect(DetailPage.allCases.map(\.title) == ["Codex", "性能", "Skills", "Codex Radar", "远程账号", "NewAPI", "Sub2API"])
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
    let overlay = OverlayState(); overlay.isExpanded = true; overlay.setDetailPresentationPhase(.visible)
    let output = ProcessInfo.processInfo.environment["CODEX_MONITOR_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    for page in [DetailPage.codex, .performance, .skills, .codexRadar] {
        let view = DetailPanelView(viewModel: usage, remoteViewModel: remote, newAPIViewModel: newAPI,
            subAPIViewModel: subAPI, codexRadarViewModel: radar, performanceViewModel: perf,
            skillInsights: skills, overlayState: overlay, settings: settings, onSettings: {},
            onLocalRefresh: {}, onRemoteRefresh: {}, onNewAPIRefresh: {}, onSubAPIRefresh: {},
            onCodexRadarRefresh: {}, initialPage: page)
        let content = VStack(spacing: 0) {
            Text("原生 SwiftUI · 合成数据 · \(page.title)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).padding(6)
            view
        }.background(Color.black).environment(\.colorScheme, .dark)
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
            try png.write(to: output.appendingPathComponent("\(page.rawValue).png"))
        }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}
