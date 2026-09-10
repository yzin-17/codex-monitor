import AppKit
import SwiftUI
import CodexMonitorCore

@MainActor
final class HUDController {
    private var panel: NSPanel?
    var onOpen: (() -> Void)?
    func toggle(store: AppStore) {
        if let panel {
            if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDSummary(store: store)
            .onTapGesture { [weak self] in self?.onOpen?() }
            .contextMenu {
                Button("打开监控面板") { [weak self] in self?.onOpen?() }
                Button("刷新本地数据") { store.refresh() }
                Button("隐藏浮动条") { [weak self] in self?.panel?.orderOut(nil) }
            })
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setFrameOrigin(NSPoint(x: frame.midX - 195, y: frame.maxY - 52))
        self.panel = panel; panel.orderFrontRegardless()
    }
}

struct HUDSummary: View {
    @ObservedObject var store: AppStore
    private var state: String {
        if store.scanning { return "SCAN" }
        return store.dashboard.activity == .running ? "RUN" : store.dashboard.activity.rawValue
    }
    var body: some View {
        HStack(spacing: 13) {
            HStack(spacing: 7) {
                Circle().fill(MonitorTheme.color(store.dashboard.activity)).frame(width: 8, height: 8)
                Text(state).font(.system(size: 12, weight: .bold))
            }
            quota("5h", minutes: 300)
            quota("7d", minutes: 10080)
            HStack(spacing: 5) {
                Text("Today").foregroundStyle(MonitorTheme.secondary)
                Text(Display.tokens(store.dashboard.today.total)).fontWeight(.bold)
            }
            if store.demo { Text("演示").foregroundStyle(MonitorTheme.amber).font(.system(size: 9)) }
        }.font(.system(size: 11, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 15).frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(MonitorTheme.text)
            .background(MonitorTheme.hud, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
            .contentShape(Capsule()).preferredColorScheme(.dark)
            .help("本地日志快照 · 点击展开面板，拖动移动，右键隐藏。")
    }
    private func quota(_ title: String, minutes: Int) -> some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(MonitorTheme.secondary)
            Text(MonitorQuota.percentage(MonitorQuota.generalWindow(store.quota, minutes: minutes)))
                .foregroundStyle(MonitorTheme.accent).fontWeight(.bold)
        }
    }
}
