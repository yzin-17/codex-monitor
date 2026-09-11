import AppKit
import Foundation
import Testing
@testable import CodexNotch

@Test func hudFillsEntireMenuBarAtEveryScale() {
    for height: CGFloat in [20, 22, 24, 28, 32, 37, 48] {
        let screen = CGRect(x: -1920, y: -600, width: 1920, height: 1080)
        let frame = FloatingHUDGeometry.frame(screen: screen, menuBarHeight: height,
            contentSize: .init(width: 220, height: 22), maximumWidth: 220, position: 0.5)
        #expect(frame.height == height)
        #expect(frame.maxY == screen.maxY)
        #expect(frame.minY == screen.maxY - height)
    }
}
@Test func floatingHUDWidthFollowsContentInsteadOfLegacyMaximumWidth() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let compact = FloatingHUDGeometry.frame(screen: screen, menuBarHeight: 24,
        contentSize: .init(width: 148, height: 20), maximumWidth: 90, position: 0.5)
    let detailed = FloatingHUDGeometry.frame(screen: screen, menuBarHeight: 24,
        contentSize: .init(width: 428, height: 20), maximumWidth: 90, position: 0.5)
    let oversized = FloatingHUDGeometry.frame(screen: screen, menuBarHeight: 24,
        contentSize: .init(width: 5_000, height: 20), maximumWidth: 90, position: 0.5)
    #expect(compact.width == 148)
    #expect(detailed.width == 428)
    #expect(oversized.width == screen.width - 24)
}
@Test func transparencyUsesInverseOfExistingOpacityWithoutChangingStoredAppearance() throws {
    var configuration = HUDConfiguration(); configuration.hudOpacity = 0.50; configuration.panelOpacity = 0.63
    #expect(abs(configuration.hudTransparency - 0.50) < 0.0001)
    #expect(abs(configuration.panelTransparency - 0.37) < 0.0001)
    let restored = try JSONDecoder().decode(HUDConfiguration.self, from: JSONEncoder().encode(configuration))
    // 0.4.4 会把旧的未绑定布局控件固定到本机 Codex；透明度往返本身不得改变。
    #expect(abs(restored.hudOpacity - configuration.hudOpacity) < 0.0001)
    #expect(abs(restored.panelOpacity - configuration.panelOpacity) < 0.0001)
    #expect(restored.mode == configuration.mode)
    #expect(restored.cornerRadius == configuration.cornerRadius)
    configuration.hudTransparency = 0
    #expect(configuration.hudOpacity == 1)
    configuration.panelTransparency = 0.65
    #expect(abs(configuration.panelOpacity - 0.35) < 0.0001)
}
@Test func transparencyLimitsKeepPanelReadable() {
    var c = HUDConfiguration(); c.hudTransparency = .nan; c.panelTransparency = 2
    #expect(c.hudOpacity == 1)
    #expect(abs(c.panelOpacity - 0.35) < 0.0001)
}
@Test func resetCountdownChoosesNearestFutureCreditAndAdvances() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let display = try #require(ResetCreditsDisplay(resetCredits: .init(availableCount: 3, credits: [
        .init(id: "later", expiresAt: now.addingTimeInterval(86400)),
        .init(id: "first", expiresAt: now.addingTimeInterval(1800)),
        .init(id: "middle", expiresAt: now.addingTimeInterval(3600))], fetchedAt: now)))
    #expect(display.nearestExpiry(at: now) == now.addingTimeInterval(1800))
    #expect(display.nearestExpiryText(at: now) == "最近到期 30分")
    #expect(display.nearestExpiry(at: now.addingTimeInterval(1800)) == now.addingTimeInterval(3600))
    #expect(display.nearestExpiryText(at: now.addingTimeInterval(90000)) == "到期信息待刷新")
}
@Test func resetCountdownNeverInventsDatesOrZeroBalances() throws {
    let now = Date()
    let absent = ResetCreditsDisplay(resetCredits: nil)
    #expect(absent == nil)
    let zero = try #require(ResetCreditsDisplay(resetCredits: .init(availableCount: 0, credits: [], fetchedAt: now)))
    #expect(zero.nearestExpiryText(at: now) == nil)
    let unknown = try #require(ResetCreditsDisplay(resetCredits: .init(availableCount: 3, credits: [], fetchedAt: now)))
    #expect(unknown.nearestExpiryText(at: now) == "到期时间未知")
}
@Test func widerResetCreditLayoutPreservesNarrowLayout() {
    #expect(ResetCreditsLayout.mode(availableWidth: 652, hasResetCredits: true) == .spacious)
    #expect(ResetCreditsLayout.mode(availableWidth: 340, hasResetCredits: true) == .full)
    #expect(ResetCreditsLayout.mode(availableWidth: 276, hasResetCredits: true) == .compact)
}
@Test func unifiedSourceCatalogRetainsDistinctPermissionScopes() {
    #expect(Set(RemoteSourceCategory.allCases.map(\.rawValue)) == ["codex", "gateway", "newapi", "subapi"])
    #expect(RemoteSourceCategory.gateway.detail.contains("管理权限"))
    #expect(RemoteSourceCategory.subAPI.detail.contains("两个权限范围"))
}

private let loginURL = "https://auth.openai.com/oauth/authorize?state=synthetic&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"
private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
@Test func browserLoginOnlyOpensOfficialURLWithLocalCallback() throws {
    #expect(try CodexBrowserLoginProtocol.authorizationURL(loginURL).host == "auth.openai.com")
    for bad in [loginURL.replacingOccurrences(of: "auth.openai.com", with: "auth.openai.com.evil.test"),
                loginURL.replacingOccurrences(of: "https://", with: "http://"),
                loginURL.replacingOccurrences(of: "localhost", with: "evil.test"),
                "https://auth.openai.com/authorize", "https://auth.openai.com@evil.test/authorize"] {
        #expect(throws: CodexBrowserLoginError.rejectedURL) { try CodexBrowserLoginProtocol.authorizationURL(bad) }
    }
}
@Test func loginMustMatchInitiatedIDAndSuccessfulCompletion() throws {
    var parser = CodexBrowserLoginProtocol()
    #expect(try parser.consume(json(["method":"account/login/completed", "params":["loginId":"wrong", "success":true]])) == .ignored)
    #expect(try parser.consume(json(["id":1,"result":[:]])) == .initialized)
    #expect(try parser.consume(json(["id":2,"result":["type":"chatgpt","loginId":"expected","authUrl":loginURL]])) == .authorization(URL(string: loginURL)!))
    #expect(try parser.consume(json(["method":"account/login/completed", "params":["loginId":"wrong", "success":true]])) == .ignored)
    #expect(throws: CodexBrowserLoginError.loginFailed) {
        try parser.consume(json(["method":"account/login/completed", "params":["loginId":"expected", "success":false, "error":"sensitive server text"]]))
    }
}
@Test func loginDoesNotAcceptSuccessfulFileAsAuthorization() throws {
    var parser = CodexBrowserLoginProtocol()
    #expect(try parser.consume(json(["id":2,"result":["type":"chatgpt","loginId":"unstarted","authUrl":loginURL]])) == .ignored)
}
@Test @MainActor func loginEnvironmentCannotBorrowExistingCredential() {
    let home = URL(fileURLWithPath: "/synthetic/isolated")
    let environment = CodexBrowserLoginClient.environment(home: home, inherited: ["CODEX_HOME":"/existing", "OPENAI_API_KEY":"secret", "CODEX_ACCESS_TOKEN":"secret", "PATH":"/usr/bin", "HTTPS_PROXY":"http://127.0.0.1:7890"])
    #expect(environment["CODEX_HOME"] == home.path)
    #expect(environment["OPENAI_API_KEY"] == nil && environment["CODEX_ACCESS_TOKEN"] == nil)
    #expect(environment["HTTPS_PROXY"] == "http://127.0.0.1:7890")
}

/// 替身只实现登录协议，既不打开真实浏览器也不调用网络。
private func makeLoginFixture(in directory: URL, complete: Bool) throws -> URL {
    let path = directory.appendingPathComponent("fake-codex")
    let record = directory.appendingPathComponent("used-home").path
    let script = """
    #!/bin/sh
    printf '%s' "$CODEX_HOME" > '\(record)'
    IFS= read -r initial
    printf '%s\\n' '{"id":1,"result":{"userAgent":"synthetic"}}'
    IFS= read -r initialized
    IFS= read -r start
    printf '%s\\n' '{"id":2,"result":{"type":"chatgpt","loginId":"test-login","authUrl":"\(loginURL)"}}'
    \(complete ? "printf '%s' '{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"synthetic-access\",\"account_id\":\"synthetic-workspace\",\"refresh_token\":\"discard-on-cleanup\"}}' > \"$CODEX_HOME/auth.json\"\nprintf '%s\\n' '{\"method\":\"account/login/completed\",\"params\":{\"loginId\":\"test-login\",\"success\":true}}'" : "")
    while IFS= read -r line; do :; done
    """
    try script.write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    return path
}
private func waitForFixtureStart(_ marker: URL, timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if FileManager.default.fileExists(atPath: marker.path) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return FileManager.default.fileExists(atPath: marker.path)
}
@Test @MainActor func browserLoginUsesRealProcessProtocolAndCleansTemporaryCredentials() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeLoginFixture(in: root, complete: true)
    var opened: [URL] = []
    let credentials = try await CodexBrowserLoginClient(executablePath: fixture.path, timeout: 3).login { opened.append($0); return true }
    #expect(opened.count == 1)
    #expect(credentials.accessToken == "synthetic-access" && credentials.workspaceID == "synthetic-workspace")
    let usedHome = try String(contentsOf: root.appendingPathComponent("used-home"), encoding: .utf8)
    #expect(usedHome.contains("codex-monitor-login-"))
    #expect(!FileManager.default.fileExists(atPath: usedHome))
}
@Test @MainActor func cancelledBrowserLoginStopsItsOwnProcessAndDeletesCredentials() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeLoginFixture(in: root, complete: false)
    let task = Task { try await CodexBrowserLoginClient(executablePath: fixture.path, timeout: 3).login { _ in true } }
    let marker = root.appendingPathComponent("used-home")
    guard await waitForFixtureStart(marker) else {
        task.cancel()
        _ = try? await task.value
        Issue.record("登录替身未启动，无法验证取消后的清理")
        return
    }
    task.cancel()
    do { _ = try await task.value; Issue.record("已取消登录不得成功") } catch is CancellationError {} catch { Issue.record("取消应报告 CancellationError") }
    let usedHome = try String(contentsOf: marker, encoding: .utf8)
    #expect(!FileManager.default.fileExists(atPath: usedHome))
}
@Test @MainActor func browserFailureDoesNotReturnCredentials() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeLoginFixture(in: root, complete: false)
    do {
        _ = try await CodexBrowserLoginClient(executablePath: fixture.path, timeout: 3).login { _ in false }
        Issue.record("浏览器启动失败不得视为成功")
    } catch let error as CodexBrowserLoginError { #expect(error == .browserUnavailable) }
    let usedHome = try String(contentsOf: root.appendingPathComponent("used-home"), encoding: .utf8)
    #expect(!FileManager.default.fileExists(atPath: usedHome))
}
