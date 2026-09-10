import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexNotch

@Test func hudModesDoNotInventPhysicalNotch() {
    #expect(MonitorDisplayMode.automatic.usesCompactOverlay(hasNotch: false))
    #expect(!MonitorDisplayMode.automatic.usesCompactOverlay(hasNotch: true))
    #expect(MonitorDisplayMode.menuBar.usesCompactOverlay(hasNotch: true))
    #expect(!MonitorDisplayMode.notch.usesCompactOverlay(hasNotch: false))
}
@Test func hudLayoutFiltersInvalidDuplicateAndTooManyItems() {
    let layout = HUDLayout(lines: [["icon", "icon", "unknown", "weekly"], ["provider", "weekly"], ["balance"]]).normalized
    #expect(layout.lines == [["icon", "weekly"], ["provider"]])
    #expect(HUDLayout(lines: []).normalized == .compact)
    #expect(HUDLayout(lines: [["bad"]]).normalized == .compact)
}
@Test func hudDragMovesInsteadOfDuplicatingMetric() {
    let layout = HUDLayout.detailed.inserting(.primary, row: 1, before: .tokensToday)
    #expect(layout.lines[1].first == "primary")
    #expect(layout.lines.joined().filter { $0 == "primary" }.count == 1)
    #expect(layout.inserting(.primary, row: 0, before: .weekly).lines[0].first == "primary")
}
@Test func hudEmptySecondLinePersistsUntilRemoved() {
    #expect(HUDLayout(lines: [["primary"], []]).normalized.lines.count == 2)
    #expect(HUDLayout(lines: [["primary"]]).removing(.primary).lines == [[]])
}
@Test func hudMalformedDimensionsAreBounded() {
    var c = HUDConfiguration(); c.maximumWidth = .nan; c.hudOpacity = 100; c.panelOpacity = -3
    #expect(c.normalized.maximumWidth == 220)
    #expect(c.normalized.hudOpacity == 1)
    #expect(c.normalized.panelOpacity == 0.35)
}
@Test func hudProviderOverridesDoNotMutateGlobalLayout() {
    var c = HUDConfiguration(); c.providerLayouts["gateway"] = .costs
    #expect(c.layout(for: "gateway") == .costs)
    #expect(c.layout(for: "codex") == .compact)
}
@Test @MainActor func hudPreferencesRoundTripAndMigrateLegacySelection() throws {
    let suite = "hud-roundtrip-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("remoteCodex", forKey: "notchDisplaySource")
    let prefs = HUDPreferences(defaults: defaults)
    #expect(prefs.value.sourceID == "legacy")
    prefs.value.mode = .menuBar; prefs.value.layout = .detailed; prefs.value.hudOpacity = 0.45
    #expect(HUDPreferences(defaults: defaults).value == prefs.value)
}
@Test func menuBarPanelIsAnchoredAndClampedWithoutFontScale() {
    let layout = FloatingHUDGeometry.panel(screen: .init(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: .init(x: -1920, y: 80, width: 1920, height: 976), anchor: .init(x: -150, y: 1056, width: 120, height: 24))
    #expect(layout.frame.maxY == 1058)
    #expect(layout.frame.maxX <= -12)
    #expect(layout.frame.minX >= -1908)
    #expect(layout.contentScale == 1)
    #expect(layout.logicalSize == layout.frame.size)
}
@Test func hudUnknownMetricsAreNotZeroAndResetIsNotNegative() {
    var d = HUDEntityData()
    #expect(d.text(.primary, remaining: true) == "5h —")
    #expect(d.text(.cost30d, remaining: true) == "30天 —")
    d.resetsAt = Date(timeIntervalSince1970: 0)
    #expect(d.text(.resetCountdown, remaining: true, now: Date()) == "待刷新")
    d.primary = 25
    #expect(d.text(.primary, remaining: false) == "5h 75%")
}

@Test func floatingHUDStaysInsideMenuBarAndHasNoNotchGap() {
    let screen = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
    for barHeight: CGFloat in [20, 22, 24, 32] {
        for position in [0.0, 0.5, 1.0] {
            let f = FloatingHUDGeometry.frame(screen: screen, menuBarHeight: barHeight, contentSize: .init(width: 160, height: 20), maximumWidth: 220, position: position)
            #expect(f.width == 160 && f.height == barHeight)
            #expect(f.maxY <= screen.maxY && f.minY >= screen.maxY - barHeight)
            #expect(f.minX >= screen.minX && f.maxX <= screen.maxX)
        }
    }
}
@Test func revealStartsInsideHUDAndKeepsTopEdgeAndFontSize() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let anchor = FloatingHUDGeometry.frame(screen: screen, menuBarHeight: 24, contentSize: .init(width: 170, height: 20), maximumWidth: 220, position: 0.5)
    let panel = FloatingHUDGeometry.panel(screen: screen, visibleFrame: screen.insetBy(dx: 0, dy: 24), anchor: anchor)
    let collapsed = FloatingHUDGeometry.collapsedFrame(anchor: anchor, expanded: panel.frame)
    #expect(collapsed.width == 170 && collapsed.height == 2)
    #expect(collapsed.maxY == panel.frame.maxY)
    #expect(anchor.intersects(collapsed))
    #expect(panel.contentScale == 1 && panel.frame.width == 680)
}
@Test func floatingHUDSanitizesInvalidDimensions() {
    let f = FloatingHUDGeometry.frame(screen: .init(x: 0, y: 0, width: 800, height: 600), menuBarHeight: .nan,
        contentSize: .init(width: 1000, height: 100), maximumWidth: .nan, position: .nan)
    #expect(f.width == 220 && f.height <= 24 && f.minX.isFinite)
    #expect(MonitorPanelAnimation.anchoredReveal.title.contains("HUD"))
}

private func fixture(_ text: String) -> Data { Data(text.utf8) }
private let validQuotaJSON = #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":54,"limit_window_seconds":18000,"reset_at":1800000000},"secondary_window":{"used_percent":21,"limit_window_seconds":604800}},"credits":{"balance":9}}"#
@Test func codexParserKeepsQuotaCreditsAndPlanSeparate() throws {
    let value = try CodexAccountUsageParser.parse(fixture(validQuotaJSON))
    #expect(value.quotas.map(\.remainingPercent) == [46,79])
    #expect(value.plan == "pro" && value.credits == "9.00 credits")
}
@Test func codexParserRejectsWrongAccountAndEmptySuccess() {
    #expect(throws: CodexAccountError.accountMismatch) {
        try CodexAccountUsageParser.parse(fixture(#"{"account_id":"other","credits":{"balance":3}}"#), workspaceID: "work")
    }
    #expect(throws: CodexAccountError.invalidResponse) { try CodexAccountUsageParser.parse(fixture("{}")) }
    #expect(CodexAccountUsageParser.number(true) == nil)
    #expect(CodexAccountUsageParser.number("nan") == nil)
}
@Test func codexParserBoundsMalformedWindows() throws {
    #expect(throws: CodexAccountError.tooLarge) { try CodexAccountUsageParser.parse(Data(repeating: 32, count: 1_048_577)) }
    let value = try CodexAccountUsageParser.parse(fixture(#"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":1e100}}}"#))
    #expect(value.quotas[0].durationSeconds == nil)
}
@Test func codexImportOnlyReadsAccessTokenAndWorkspace() throws {
    let result = try CodexCredentialImport.parse(fixture(#"{"auth_mode":"chatgpt","tokens":{"access_token":"synthetic-access","account_id":"work-123","refresh_token":"never-save","id_token":"never-save"}}"#))
    #expect(result.accessToken == "synthetic-access" && result.workspaceID == "work-123")
    #expect(throws: CodexAccountError.invalidCredential) { try CodexCredentialImport.parse(fixture(#"{"OPENAI_API_KEY":"sk-api"}"#)) }
    #expect(throws: CodexAccountError.tooLarge) { try CodexCredentialImport.parse(Data(repeating: 32, count: 262145)) }
}
@Test func codexHTTPUsesOnlyFixedOfficialReadOnlyEndpoint() throws {
    let request = try CodexAccountHTTPClient.request(account: .init(label: "test", workspaceID: "work-1"), token: "synthetic-token")
    #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    #expect(request.httpMethod == "GET" && request.httpBody == nil && request.url?.query == nil)
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "work-1")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
}
@Test func codexRejectsHeaderInjectionAndAPIKeys() {
    for token in ["token\nHost:evil", "sk-api-key", "Cookie;a=b", "{\"tokens\":{}}"] {
        #expect(throws: CodexAccountError.invalidCredential) { try CodexAccountHTTPClient.request(account: .init(), token: token) }
    }
    #expect(throws: CodexAccountError.invalidCredential) {
        try CodexAccountHTTPClient.request(account: .init(workspaceID: "work\naccount"), token: "synthetic")
    }
}
@Test func codexMetadataDoesNotEncodeCredentials() throws {
    let text = String(decoding: try JSONEncoder().encode(CodexAccount(label: "work")), as: UTF8.self)
    #expect(!text.contains("token") && !text.contains("secret") && !text.contains("password"))
}
private final class TestCodexVault: @unchecked Sendable {
    let lock = NSLock()
    var values: [UUID: String] = [:]
    var writesFail = false
    var vault: CodexAccountVault {
        .init(read: { [self] a, _ in lock.lock(); defer { lock.unlock() }; return values[a.id] ?? "synthetic" },
              write: { [self] a, s in lock.lock(); defer { lock.unlock() }; if writesFail { throw CodexAccountError.keychain }; values[a.id] = s },
              delete: { [self] a in lock.lock(); defer { lock.unlock() }; values[a.id] = nil })
    }
}
@Test @MainActor func codexFailedOnlineVerificationNeverSavesCredential() async throws {
    let suite = "codex-fail-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let memory = TestCodexVault()
    let store = CodexAccountsStore(defaults: defaults, vault: memory.vault, client: .init(fetch: { _ in throw CodexAccountError.http(401) }), automaticStart: false)
    await #expect(throws: CodexAccountError.http(401)) { try await store.verifyAndSave(.init(label: "test"), token: "synthetic") }
    #expect(store.accounts.isEmpty && memory.values.isEmpty)
}
@Test @MainActor func codexSaveRequiresSuccessfulKeychainWrite() async throws {
    let suite = "codex-vault-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let memory = TestCodexVault(); memory.writesFail = true
    let store = CodexAccountsStore(defaults: defaults, vault: memory.vault, client: .init(fetch: { _ in fixture(validQuotaJSON) }), automaticStart: false)
    await #expect(throws: CodexAccountError.keychain) { try await store.verifyAndSave(.init(label: "test"), token: "synthetic") }
    #expect(store.accounts.isEmpty)
}
@Test @MainActor func codexWorkspaceChangeCannotBorrowOldCredential() async throws {
    let suite = "codex-scope-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = CodexAccountsStore(defaults: defaults, vault: TestCodexVault().vault, client: .init(fetch: { _ in fixture(validQuotaJSON) }), automaticStart: false)
    var account = CodexAccount(label: "work", workspaceID: "work-1")
    try await store.verifyAndSave(account, token: "synthetic")
    account.workspaceID = "work-2"
    await #expect(throws: CodexAccountError.missingCredential) { try await store.verifyAndSave(account, token: "") }
    #expect(store.accounts[0].workspaceID == "work-1")
    #expect(!store.monitoringEnabled)
}
@Test @MainActor func codexCancelledVerificationCannotSaveLateResult() async throws {
    let suite = "codex-cancel-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let memory = TestCodexVault()
    let store = CodexAccountsStore(defaults: defaults, vault: memory.vault, client: .init(fetch: { _ in
        try? await Task.sleep(for: .milliseconds(80)); return fixture(validQuotaJSON)
    }), automaticStart: false)
    let account = CodexAccount(label: "cancelled")
    let task = Task { try await store.verifyAndSave(account, token: "synthetic") }
    try await Task.sleep(for: .milliseconds(20)); store.cancelVerification(id: account.id)
    await #expect(throws: CodexAccountError.superseded) { try await task.value }
    #expect(store.accounts.isEmpty && memory.values.isEmpty)
}
@Test @MainActor func codexAccountsRemainIndependentAndCanBeRemoved() async throws {
    let suite = "codex-many-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = CodexAccountsStore(defaults: defaults, vault: TestCodexVault().vault, client: .init(fetch: { req in
        let percent = req.value(forHTTPHeaderField: "Authorization") == "Bearer personal" ? 7 : 3
        return fixture("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(percent)}}}")
    }), automaticStart: false)
    let one = CodexAccount(label: "个人"), two = CodexAccount(label: "工作")
    try await store.verifyAndSave(one, token: "personal"); try await store.verifyAndSave(two, token: "work")
    #expect(store.states[one.id]?.usage?.quotas[0].usedPercent == 7)
    #expect(store.states[two.id]?.usage?.quotas[0].usedPercent == 3)
    try store.remove(one); #expect(store.accounts.count == 1 && store.states[one.id] == nil)
    store.stop()
}

@Test @MainActor func panelRevealClipsRatherThanScalesItsContent() {
    let content = NSView(frame: .init(x: 0, y: 0, width: 680, height: 720))
    let clip = TopAnchoredClippingView(hostedView: content, contentSize: .init(width: 680, height: 720))
    for size in [NSSize(width: 180, height: 2), NSSize(width: 400, height: 350), NSSize(width: 680, height: 720)] {
        clip.setFrameSize(size); clip.needsLayout = true; clip.layoutSubtreeIfNeeded()
        #expect(content.frame.size == NSSize(width: 680, height: 720))
        #expect(content.frame.midX == clip.bounds.midX && content.frame.maxY == clip.bounds.maxY)
    }
}

@Test @MainActor func legacyBackdropDefaultsMigrateButCustomOpacitySurvives() throws {
    let suite = "hud-palette-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var previous = HUDConfiguration(); previous.hudOpacity = 0.30; previous.panelOpacity = 0.78
    defaults.set(try JSONEncoder().encode(previous), forKey: HUDPreferences.key)
    let prefs = HUDPreferences(defaults: defaults)
    #expect(prefs.value.hudOpacity == 0.985 && prefs.value.panelOpacity == 0.985)
    prefs.value.hudOpacity = 0.55; prefs.value.panelOpacity = 0.65
    let reloaded = HUDPreferences(defaults: defaults)
    #expect(reloaded.value.hudOpacity == 0.55 && reloaded.value.panelOpacity == 0.65)
}
@Test @MainActor func neutralHUDDoesNotInstallWallpaperTintMaterial() {
    let host = NSHostingView(rootView: HUDGlassBackground(opacity: 0.985))
    host.frame = NSRect(x: 0, y: 0, width: 220, height: 22)
    host.layoutSubtreeIfNeeded()
    func containsVisualEffect(_ view: NSView) -> Bool {
        view is NSVisualEffectView || view.subviews.contains(where: containsVisualEffect)
    }
    #expect(!containsVisualEffect(host))
    #expect(HUDMetricStrip.measuredWidth(layout: .init(lines: [["space:8", "space:16"]]), data: .init(), remaining: true, menuBar: true) == 29)
}
