#if DEBUG
import AppKit
import Darwin
import SwiftUI

/// 独立于 Swift Testing 的异步入口，以正常 AppKit 循环验证真实鼠标交互。
/// 仅使用合成数据；发布构建不包含这个入口或测试窗口。
enum HUDNativeInteractionQA {
    @MainActor static func run() -> Int32 {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--qa-hud-interaction") else {
            qaTrace("FAIL missing QA flag")
            return 2
        }
        let scenario = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "all"
        guard ["widgets", "settings", "all"].contains(scenario) else {
            qaTrace("FAIL unknown case: \(scenario)")
            return 2
        }
        let app = NSApplication.shared
        let runner = HUDNativeQARunner(scenario: scenario)
        app.delegate = runner
        app.setActivationPolicy(.regular)
        // 即使原生跟踪循环意外卡住，隔离进程也会明确失败，而不是无限等待。
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            FileHandle.standardError.write(Data("HUD_NATIVE_QA FAIL timeout after 45 seconds\n".utf8))
            _exit(124)
        }
        app.run()
        return runner.exitCode
    }
}

@MainActor
private final class HUDNativeQARunner: NSObject, NSApplicationDelegate {
    let scenario: String
    private(set) var exitCode: Int32 = 2
    init(scenario: String) { self.scenario = scenario }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            do {
                if scenario == "widgets" || scenario == "all" {
                    qaTrace("START widgets")
                    try await qaWidgets()
                    qaTrace("PASS widgets")
                }
                if scenario == "settings" || scenario == "all" {
                    qaTrace("START settings")
                    try await qaSettings()
                    qaTrace("PASS settings")
                }
                exitCode = 0
                qaTrace("PASS complete")
            } catch {
                exitCode = 1
                qaTrace("FAIL \(error)")
            }
            NSApp.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(wake, atStart: true) }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateCancel }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct HUDNativeQAError: Error, CustomStringConvertible {
    var description: String
}
private func qaTrace(_ message: String) {
    FileHandle.standardError.write(Data(("HUD_NATIVE_QA " + message + "\n").utf8))
}
private func qaCheck(_ condition: Bool, _ message: String = "检查未通过", file: String = #fileID, line: Int = #line) throws {
    if !condition { throw HUDNativeQAError(description: "\(file):\(line): \(message)") }
}
private func qaRequire<T>(_ value: T?, _ message: String = "缺少原生控件或数据", file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else { throw HUDNativeQAError(description: "\(file):\(line): \(message)") }
    return value
}
private func qaRequire(_ condition: Bool, _ message: String = "检查未通过", file: String = #fileID, line: Int = #line) throws {
    try qaCheck(condition, message, file: file, line: line)
}
private func qaPause(_ seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }

@MainActor
private final class HUDDragFixture: ObservableObject {
    @Published var layout = HUDLayout(lines: [["weekly@@local", "space:8", "account@@local"], []])
    @Published var shown = true
    @Published var feedback: String?
    var clickCount = 0
    private let sessionID = UUID()
    private var revision: UInt64 = 0
    var context: HUDLayoutDragContext { .init(sessionID: sessionID, layoutID: "native-fixture", revision: revision) }

    func commit(_ result: HUDLayoutDropResult) -> Bool {
        switch result {
        case .layout(let next):
            revision &+= 1
            layout = next
            feedback = nil
            return true
        case .rejected(let reason): feedback = reason; return false
        case .conditional: return false
        }
    }
}

private struct HUDDragFixtureView: View {
    @ObservedObject var state: HUDDragFixture
    var body: some View {
        Form {
            Section("自定义布局 · 合成数据") {
                Toggle("显示外观页", isOn: $state.shown)
                if state.shown {
                    HUDNativeDragChip(label: label("Token 速度"), accessibilityLabel: "Token 速度，拖到布局",
                        identifier: "hud-palette:tokensPerSecond",
                        payload: { .init(context: state.context, source: .palette(metric: .tokensPerSecond, sourceID: "local")) },
                        onClick: { state.clickCount += 1 })
                    ForEach(Array(state.layout.lines.enumerated()), id: \.offset) { row, values in
                        HUDNativeLayoutRow(row: row, items: values.enumerated().map { index, raw in
                            HUDLayoutChipDescription(id: "\(row):\(raw):\(index)", label: label(HUDMetric.parse(raw)?.title ?? raw),
                                accessibilityLabel: raw,
                                payload: { .init(context: state.context, source: .placed(row: row, index: index, raw: raw)) },
                                onClick: {
                                    state.clickCount += 1
                                    _ = state.commit(.layout(state.layout.removing(at: .init(row: row, index: index))))
                                }, menu: { NSMenu() })
                        }, evaluate: { payload, index in
                            HUDLayoutDrop.apply(payload, context: state.context, layout: state.layout, row: row, before: index)
                        }, commit: state.commit, feedback: { state.feedback = $0 })
                            .frame(height: 58)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    HUDNativeRemovalTarget(evaluate: { HUDLayoutDrop.remove($0, context: state.context, layout: state.layout) },
                        commit: state.commit, feedback: { state.feedback = $0 })
                        .frame(width: 132, height: 32)
                }
                if let feedback = state.feedback { Text(feedback).foregroundStyle(.orange) }
            }
        }.formStyle(.grouped).padding(12).frame(width: 620, height: 370)
    }
    private func label(_ text: String) -> AnyView {
        AnyView(Text(text).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7)
            .background(.quaternary, in: Capsule()))
    }
}

@MainActor
private func hudFixtureWindow() -> (HUDDragFixture, NSWindow) {
    _ = NSApplication.shared
    let state = HUDDragFixture()
    let host = NSHostingView(rootView: HUDDragFixtureView(state: state).environment(\.colorScheme, .dark))
    host.sizingOptions = []
    host.frame = .init(x: 0, y: 0, width: 620, height: 370)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Codex Monitor · 合成拖放验证"
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.center()
    window.makeKeyAndOrderFront(nil)
    host.layoutSubtreeIfNeeded()
    return (state, window)
}

@MainActor
private func fixtureView(_ identifier: String, in root: NSView) -> NSView? {
    if root.identifier?.rawValue == identifier { return root }
    for child in root.subviews {
        if let match = fixtureView(identifier, in: child) { return match }
    }
    return nil
}

@MainActor
private func fixturePoint(_ identifier: String, in window: NSWindow, fractionX: CGFloat = 0.5) throws -> CGPoint {
    let root = try qaRequire(window.contentView)
    let view = try qaRequire(fixtureView(identifier, in: root), "没有找到原生拖放控件 \(identifier)")
    let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
    let appKit = CGPoint(x: rect.minX + rect.width * fractionX, y: rect.midY)
    let mainTop = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
    return CGPoint(x: appKit.x, y: mainTop - appKit.y)
}

private func postHUDMouse(_ type: CGEventType, at point: CGPoint) throws {
    let event = try qaRequire(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left))
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
}

@MainActor
private func requireHUDInputAccess(points: [CGPoint], window: NSWindow) throws {
    let allowed = CGPreflightPostEventAccess()
    qaTrace("CGPreflightPostEventAccess=\(allowed)")
    try qaRequire(allowed, "当前QA进程没有系统输入投递权限；未请求或修改TCC权限，不能执行真实鼠标验收。")
    try qaRequire(NSRunningApplication.current.isActive && window.isKeyWindow && window.isVisible,
                  "合成QA窗口未处于前台，已停止输入。")
    let mainTop = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
    for point in points {
        try qaRequire(window.frame.contains(.init(x: point.x, y: mainTop - point.y)),
                      "输入位置不在合成QA窗口内，已停止输入。")
    }
}

@MainActor
private func dragHUDMouse(from source: CGPoint, to destination: CGPoint) async throws {
    qaTrace("drag \(source) -> \(destination)")
    qaTrace("active=\(NSRunningApplication.current.isActive) keyWindow=\(NSApp.keyWindow?.windowNumber ?? -1)")
    try requireHUDInputAccess(points: [source, destination], window: qaRequire(NSApp.keyWindow))
    // AppKit 的原生按钮/拖动可进入跟踪循环，输入释放事件必须独立于主线程发出。
    let injection = Task.detached(priority: .userInitiated) {
        defer { try? postHUDMouse(.leftMouseUp, at: destination) }
        try postHUDMouse(.mouseMoved, at: source)
        try postHUDMouse(.leftMouseDown, at: source)
        try await Task.sleep(for: .milliseconds(120))
        for step in 1...16 {
            let fraction = CGFloat(step) / 16
            try postHUDMouse(.leftMouseDragged, at: .init(x: source.x + (destination.x - source.x) * fraction,
                                                        y: source.y + (destination.y - source.y) * fraction))
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(150))
    }
    try await qaPause(1)
    try await injection.value
    try await qaPause(0.25)
    qaTrace("drag input sequence complete")
}

@MainActor func qaWidgets() async throws {
    let (state, window) = hudFixtureWindow()
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    NSApp.activate(ignoringOtherApps: true)
    try await qaPause(0.3)
    let original = state.layout

    try await dragHUDMouse(from: fixturePoint("hud-palette:tokensPerSecond", in: window),
                           to: fixturePoint("hud-row:0", in: window, fractionX: 0.93))
    qaTrace("widgets after add: \(state.layout.lines)")
    try qaCheck(state.layout.lines[0].last == "tokensPerSecond@@local")
    try qaCheck(state.layout.lines[0].count == 4)
    try qaCheck(state.clickCount == 0)

    try await dragHUDMouse(from: fixturePoint("hud-placed:0:tokensPerSecond@@local:3", in: window),
                           to: fixturePoint("hud-row:0", in: window, fractionX: 0.02))
    try qaCheck(state.layout.lines[0].first == "tokensPerSecond@@local")

    try await dragHUDMouse(from: fixturePoint("hud-placed:0:tokensPerSecond@@local:0", in: window),
                           to: fixturePoint("hud-row:1", in: window, fractionX: 0.3))
    try qaCheck(state.layout.lines[1] == ["tokensPerSecond@@local"])
    try qaCheck(state.layout.lines[0] == original.lines[0])

    try await dragHUDMouse(from: fixturePoint("hud-placed:1:tokensPerSecond@@local:0", in: window),
                           to: fixturePoint("hud-trash", in: window))
    try qaCheck(state.layout == original)
    try qaCheck(state.clickCount == 0)

    state.shown = false
    try await qaPause(0.15)
    state.shown = true
    try await qaPause(0.2)
    try await dragHUDMouse(from: fixturePoint("hud-palette:tokensPerSecond", in: window),
                           to: fixturePoint("hud-row:1", in: window, fractionX: 0.3))
    try qaCheck(state.layout.lines[1] == ["tokensPerSecond@@local"])
    try qaCheck(state.clickCount == 0)

    let beforeCancel = state.layout
    let mainTop = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
    try await dragHUDMouse(from: fixturePoint("hud-placed:1:tokensPerSecond@@local:0", in: window),
        to: .init(x: window.frame.midX, y: mainTop - window.frame.maxY + 12))
    try await qaPause(0.3)
    try qaCheck(state.layout == beforeCancel)
    try qaCheck(state.clickCount == 0)
    qaTrace("component drag assertions complete")
}

private final class HUDSettingsFixtureLogin: LaunchAtLoginManaging {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

@MainActor
private func hudAccessibilityObject(_ identifier: String, root: NSObject) -> NSObject? {
    var visited = Set<ObjectIdentifier>()
    func visit(_ object: NSObject) -> NSObject? {
        guard visited.count < 10_000, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
        if object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
           object.value(forKey: "accessibilityIdentifier") as? String == identifier { return object }
        if object.responds(to: NSSelectorFromString("accessibilityChildren")),
           let children = object.value(forKey: "accessibilityChildren") as? [NSObject] {
            for child in children { if let match = visit(child) { return match } }
        }
        if let view = object as? NSView {
            for child in view.subviews { if let match = visit(child) { return match } }
        }
        if let window = object as? NSWindow, let content = window.contentView, let match = visit(content) { return match }
        return nil
    }
    return visit(root)
}

@MainActor
private func clickHUDSettingsButton(_ identifier: String, in window: NSWindow) async throws {
    let element = try qaRequire(hudAccessibilityObject(identifier, root: window), "找不到设置按钮 \(identifier)")
    let value = try qaRequire(element.value(forKey: "accessibilityFrame") as? NSValue)
    let frame = value.rectValue
    try qaRequire(frame.width > 0 && frame.height > 0 && window.frame.contains(.init(x: frame.midX, y: frame.midY)))
    let mainTop = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
    let point = CGPoint(x: frame.midX, y: mainTop - frame.midY)
    try requireHUDInputAccess(points: [point], window: window)
    let injection = Task.detached(priority: .userInitiated) {
        defer { try? postHUDMouse(.leftMouseUp, at: point) }
        try postHUDMouse(.mouseMoved, at: point)
        try postHUDMouse(.leftMouseDown, at: point)
        try await Task.sleep(for: .milliseconds(70))
    }
    try await qaPause(0.4)
    try await injection.value
}

@MainActor
private func revealHUDSettingsViews(_ identifiers: [String], in window: NSWindow) async throws {
    let root = try qaRequire(window.contentView)
    func scrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? [])
            + view.subviews.flatMap { scrollViews($0) }
    }
    for attempt in 0..<24 {
        root.layoutSubtreeIfNeeded()
        let scroll = scrollViews(root).filter {
            ($0.documentView?.bounds.height ?? 0) > $0.contentSize.height + 2 && $0.contentSize.width > 400
        }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        let views = identifiers.compactMap { fixtureView($0, in: root) }
        if views.count == identifiers.count {
            if let scroll, let document = scroll.documentView {
                let target = views.reduce(NSRect.null) { $0.union(document.convert($1.bounds, from: $1)) }
                try qaRequire(target.height < scroll.contentSize.height - 8, "拖拽源和落点不能同时显示在合成设置窗口中")
                let y = min(max(document.bounds.minY, target.midY - scroll.contentSize.height / 2),
                            max(document.bounds.minY, document.bounds.maxY - scroll.contentSize.height))
                scroll.contentView.scroll(to: .init(x: scroll.contentView.bounds.minX, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await qaPause(0.2)
            }
            return
        }
        guard let scroll, let document = scroll.documentView else { break }
        let y = min(document.bounds.maxY - scroll.contentSize.height,
                    document.bounds.minY + CGFloat(attempt + 1) * scroll.contentSize.height * 0.45)
        scroll.contentView.scroll(to: .init(x: scroll.contentView.bounds.minX, y: max(document.bounds.minY, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await qaPause(0.1)
    }
    qaTrace("未能在设置窗口中显示控件：\(identifiers.joined(separator: ", "))")
    try qaRequire(identifiers.allSatisfy { fixtureView($0, in: root) != nil })
}

/// 完整 SettingsView 使用独立偏好域、替身密钥库和空账号；tab、保存均点击真实按钮。
@MainActor func qaSettings() async throws {
    let suite = "hud-native-settings-\(UUID())"
    let defaults = try qaRequire(UserDefaults(suiteName: suite))
    defaults.set(1, forKey: "legacyKeychainMigrationVersion")
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = CodexNotchSettings(defaults: defaults, initialManagementKey: "", initialNewAPIKey: "", initialSubAPIKey: "",
        secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
        launchAtLoginManager: HUDSettingsFixtureLogin(), loadSecretsSynchronously: true)
    settings.codexAccounts = CodexAccountsStore(defaults: defaults,
        vault: .init(read: { _, _ in throw CodexAccountError.missingCredential }, write: { _, _ in }, delete: { _ in }),
        client: .init(fetch: { _ in throw URLError(.notConnectedToInternet) }),
        automaticStart: false, localAuthURL: directory.appendingPathComponent("auth.json"))
    var configuration = settings.hudPreferences.value
    configuration.mode = .menuBar
    configuration.sourceID = "local"
    configuration.updateActiveLayout(.init(lines: [["weekly@@local"], []]))
    settings.hudPreferences.value = configuration
    let initial = settings.hudPreferences.value.activeLayout
    let view = SettingsView(settings: settings, remoteViewModel: RemoteMonitorViewModel(settings: settings),
        newAPIViewModel: BalanceMonitorViewModel(source: .newAPI, settings: settings),
        subAPIViewModel: BalanceMonitorViewModel(source: .subAPI, settings: settings),
        codexRadarViewModel: CodexRadarViewModel(settings: settings, previewSnapshot: .disabled),
        onRefresh: {}, initialTab: .appearance,
        pricingUpdater: TokenPricingUpdater(defaults: defaults, cacheURL: directory.appendingPathComponent("pricing.json"),
            fetch: { _ in throw URLError(.notConnectedToInternet) }))
    let height = max(660, min(940, (NSScreen.main?.visibleFrame.height ?? 900) - 60))
    let host = NSHostingView(rootView: view.frame(width: 900, height: height).environment(\.colorScheme, .dark))
    host.sizingOptions = []
    host.frame = .init(x: 0, y: 0, width: 900, height: height)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Codex Monitor · 完整设置合成验证"
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    try await qaPause(0.3)

    try await revealHUDSettingsViews(["hud-palette:tokensPerSecond", "hud-row:0"], in: window)
    try await dragHUDMouse(from: fixturePoint("hud-palette:tokensPerSecond", in: window),
                           to: fixturePoint("hud-row:0", in: window, fractionX: 0.9))
    try qaCheck(fixtureView("hud-placed:0:tokensPerSecond@@local:0", in: host) != nil)
    try qaCheck(settings.hudPreferences.value.activeLayout == initial)

    try await clickHUDSettingsButton("settings-tab-launch", in: window)
    try qaCheck(fixtureView("hud-row:0", in: host) == nil)
    try await clickHUDSettingsButton("settings-tab-appearance", in: window)
    try await revealHUDSettingsViews(["hud-placed:0:tokensPerSecond@@local:0", "hud-row:1"], in: window)
    try await dragHUDMouse(from: fixturePoint("hud-placed:0:tokensPerSecond@@local:0", in: window),
                           to: fixturePoint("hud-row:1", in: window, fractionX: 0.3))
    try qaCheck(settings.hudPreferences.value.activeLayout == initial)
    try await clickHUDSettingsButton("hud-save-layout", in: window)
    let expected = HUDLayout(lines: [["weekly@@local"], ["tokensPerSecond@@local"]])
    try qaCheck(settings.hudPreferences.value.activeLayout == expected)
    try qaCheck(HUDPreferences(defaults: defaults).value.activeLayout == expected)
    qaTrace("SettingsView tab and save assertions complete")
}

#endif
