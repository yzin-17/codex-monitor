import AppKit
import SwiftUI
import Testing
@testable import CodexNotch

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

@Test @MainActor func hudNativeEditorAndAdaptiveWidthSnapshots() async throws {
    guard let path = ProcessInfo.processInfo.environment["CODEX_MONITOR_SNAPSHOT_DIR"] else { return }
    let output = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let (_, editor) = hudFixtureWindow()
    defer { editor.orderOut(nil); editor.contentView = nil; editor.close() }
    try await Task.sleep(for: .milliseconds(200))
    try saveHUDSnapshot(try #require(editor.contentView), to: output.appendingPathComponent("hud-native-layout-editor.png"))

    let now = Date()
    let samples: [(String, Double?)] = [("空闲", nil), ("一位数", 8.5), ("两位数", 68.4), ("三位数", 999.9)]
    let strips = VStack(alignment: .leading, spacing: 14) {
        ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
            HStack(spacing: 12) {
                Text(sample.0).font(.system(size: 11)).frame(width: 50, alignment: .leading)
                HUDMetricStrip(layout: .init(lines: [["weekly", "tokensPerSecond"]]),
                    data: .init(weekly: 4, hasRunningTasks: sample.1 != nil, tokenRate: .init(value: sample.1, measuredAt: now)), menuBar: true)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.black, in: Capsule())
            }
        }
    }.padding(20).frame(width: 420, height: 190, alignment: .leading).background(Color(nsColor: .windowBackgroundColor))
    let host = NSHostingView(rootView: strips.environment(\.colorScheme, .dark))
    host.sizingOptions = []
    host.frame = .init(x: 0, y: 0, width: 420, height: 190)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    defer { window.orderOut(nil); window.contentView = nil; window.close() }
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(200))
    try saveHUDSnapshot(host, to: output.appendingPathComponent("hud-adaptive-width.png"))
}

@MainActor
private func saveHUDSnapshot(_ view: NSView, to url: URL) throws {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: url)
}
