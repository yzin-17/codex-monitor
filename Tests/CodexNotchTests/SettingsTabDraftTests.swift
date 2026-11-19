import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexNotch

@Test @MainActor
func appearanceEditingSessionRetainsUnsavedSourceBindingsAcrossConsumers() {
    let session = HUDLayoutEditingSession()
    let layout = HUDLayout(lines: [[]])
        .inserting(.weekly, row: 0, sourceID: "remote:preview-account")
        .inserting(.tokensToday, row: 0, sourceID: "local")
    session.update(layout, for: "preview-layout")

    // 同一设置窗口重建外观页时复用该会话，草稿中的账号绑定仍然存在。
    let recreatedPageSession = session
    #expect(recreatedPageSession.layout(for: "preview-layout") == layout.normalized)
    let items = recreatedPageSession.layout(for: "preview-layout")?.lines.first ?? []
    #expect(items.map { HUDLayoutToken.sourceID($0) } == ["remote:preview-account", "local"])

    recreatedPageSession.update(nil, for: "preview-layout")
    #expect(session.layout(for: "preview-layout") == nil)
}

@Test @MainActor
func appearanceDraftCannotBeAppliedToADifferentLayout() {
    let session = HUDLayoutEditingSession()
    session.update(.init(lines: [["weekly@@local"]]), for: "first-layout")
    #expect(session.layout(for: "second-layout") == nil)
    #expect(session.layout(for: "first-layout") != nil)

    session.update(.init(lines: [["tokensToday@@local"]]), for: "second-layout")
    #expect(session.layout(for: "first-layout") == nil)
    #expect(session.layout(for: "second-layout")?.lines == [["tokensToday@@local"]])
}

private final class SettingsTabLoginManager: LaunchAtLoginManaging {
    var isEnabled = false
    var changes: [Bool] = []
    func setEnabled(_ enabled: Bool) throws { changes.append(enabled) }
}

@Test @MainActor
func startupAndAppearanceRenderWithoutChangingStartupOrRefreshing() async throws {
    _ = NSApplication.shared
    let suite = "settings-tabs-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let login = SettingsTabLoginManager()
    let settings = CodexNotchSettings(defaults: defaults, initialManagementKey: "", initialNewAPIKey: "", initialSubAPIKey: "",
        secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
        launchAtLoginManager: login, loadSecretsSynchronously: true)
    settings.codexAccounts = CodexAccountsStore(defaults: defaults,
        vault: .init(read: { _, _ in throw CodexAccountError.missingCredential }, write: { _, _ in }, delete: { _ in }),
        client: .init(fetch: { _ in throw URLError(.notConnectedToInternet) }),
        automaticStart: false, localAuthURL: directory.appendingPathComponent("auth.json"))
    let remote = RemoteMonitorViewModel(settings: settings)
    let newAPI = BalanceMonitorViewModel(source: .newAPI, settings: settings)
    let subAPI = BalanceMonitorViewModel(source: .subAPI, settings: settings)
    let radar = CodexRadarViewModel(settings: settings, previewSnapshot: .disabled)
    let output = ProcessInfo.processInfo.environment["CODEX_MONITOR_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    var refreshes = 0

    for (tab, name) in [(SettingsTab.launch, "settings-startup"), (.appearance, "settings-appearance")] {
        let view = SettingsView(settings: settings, remoteViewModel: remote, newAPIViewModel: newAPI,
            subAPIViewModel: subAPI, codexRadarViewModel: radar, onRefresh: { refreshes += 1 }, initialTab: tab)
        let host = NSHostingView(rootView: view.frame(width: 900, height: 780)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 780)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 900)
        #expect(bitmap.pixelsHigh >= 660)
        if let output {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(name + ".png"))
        }
    }
    #expect(login.changes.isEmpty)
    #expect(refreshes == 0)
    #expect(!settings.launchAtLoginEnabled)
}
