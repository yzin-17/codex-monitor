import AppKit
import SwiftUI
import Testing
@testable import CodexNotch

@MainActor private final class LoginCompletionGate {
    var continuation: CheckedContinuation<Void, Error>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor private final class LoginTestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor private func waitForPresentation(_ condition: () -> Bool) async {
    for _ in 0..<30 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(100))
    }
}

@Test @MainActor func reauthenticationSheetRendersOnLightPanelAndDismissesAfterSuccess() async throws {
    _ = NSApplication.shared
    let flow = CodexReauthenticationFlow()
    let content = VStack {
        Text("合成账号")
        Button("重新登录") {}
            .modifier(CodexReauthenticationPresentation(flow: flow, accountLabel: "合成账号", onCancel: flow.cancel))
    }.frame(width: 680, height: 520)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: content)
    host.appearance = NSAppearance(named: .aqua)
    host.sizingOptions = []
    let size = NSSize(width: 680, height: 520)
    host.frame = NSRect(origin: .zero, size: size)
    let panel = LoginTestPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.appearance = NSAppearance(named: .aqua)
    panel.contentView = TopAnchoredClippingView(hostedView: host, contentSize: size)
    panel.orderFrontRegardless()
    defer { flow.cancel(); panel.orderOut(nil); panel.contentView = nil; panel.close() }
    try await Task.sleep(for: .milliseconds(200))

    let gate = LoginCompletionGate()
    flow.start { try await gate.wait() }
    await waitForPresentation { panel.attachedSheet != nil && gate.continuation != nil }
    #expect(flow.presented && flow.busy)
    let sheet = try #require(panel.attachedSheet)
    try await captureLoginSheet(sheet, name: "reauthentication-loading")

    gate.finish(.success(()))
    await waitForPresentation { !flow.presented && panel.attachedSheet == nil }
    #expect(!flow.presented)
    #expect(!flow.busy)
    #expect(panel.attachedSheet == nil)

    flow.start { throw CodexAccountError.http(401) }
    await waitForPresentation { !flow.busy && panel.attachedSheet != nil }
    #expect(flow.presented)
    #expect(flow.message.contains("401"))
    try await captureLoginSheet(try #require(panel.attachedSheet), name: "reauthentication-failure")
    flow.cancel()
    await waitForPresentation { panel.attachedSheet == nil }
    #expect(panel.attachedSheet == nil)
}

@Test @MainActor func cancelledLoginCannotCloseANewerPresentation() async {
    let flow = CodexReauthenticationFlow()
    let old = LoginCompletionGate()
    flow.start { try await old.wait() }
    await waitForPresentation { old.continuation != nil }
    flow.cancel()
    flow.start { throw CodexAccountError.http(401) }
    await waitForPresentation { !flow.busy }
    old.finish(.success(()))
    try? await Task.sleep(for: .milliseconds(100))
    #expect(flow.presented)
    #expect(flow.message.contains("401"))
    flow.cancel()
}

@MainActor private func captureLoginSheet(_ sheet: NSWindow, name: String) async throws {
    try await Task.sleep(for: .milliseconds(350))
    let view = try #require(sheet.contentView)
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    var dark = 0, light = 0, total = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
            if brightness < 0.3 { dark += 1 }
            if brightness > 0.65 { light += 1 }
            total += 1
        }
    }
    #expect(Double(dark) / Double(max(total, 1)) > 0.7)
    #expect(light > 10)
    if let directory = ProcessInfo.processInfo.environment["CODEX_MONITOR_SNAPSHOT_DIR"] {
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: root.appendingPathComponent(name + ".png"))
    }
}
