import AppKit
import SwiftUI
import CodexMonitorCore

@main
struct CodexMonitorApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        Window("Codex Monitor", id: "main") {
            RootView(store: store).frame(minWidth: 980, minHeight: 660).tint(.blue)
                .task { store.startIfNeeded() }
        }
        .defaultSize(width: 1160, height: 780)
        MenuBarExtra {
            MenuContent(store: store).task { store.startIfNeeded() }
        } label: {
            Label("\(Display.tokens(store.usage.total))", systemImage: "chart.bar.xaxis")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuContent: View {
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("Codex Monitor", systemImage: "chart.bar.xaxis").font(.headline)
                Spacer()
                Text(store.demo ? "演示" : "离线").font(.caption).foregroundStyle(.secondary)
            }
            Text(Display.tokens(store.usage.total)).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
            Text("\(store.window.rawValue) · 本机所有已扫描对话").font(.caption).foregroundStyle(.secondary)
            if store.snapshot.progress.pendingFiles > 0 {
                Text("回填中：还有 \(store.snapshot.progress.pendingFiles) 个文件").font(.caption).foregroundStyle(.orange)
            }
            Divider()
            Button("打开分析面板") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button("显示 / 隐藏浮动条") { store.hud.toggle(store: store) }
            Button(store.scanning ? "扫描中…" : "刷新 / 继续回填") { store.refresh() }.disabled(store.scanning)
            Divider()
            Button("退出 Codex Monitor") { NSApp.terminate(nil) }
        }.padding(20).frame(width: 300)
    }
}
