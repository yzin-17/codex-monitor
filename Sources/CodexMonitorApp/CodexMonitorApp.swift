import AppKit
import SwiftUI
import CodexMonitorCore

@main
@MainActor
struct CodexMonitorApp: App {
    @StateObject private var store: AppStore
    init() {
        let arguments = CommandLine.arguments
        let preview = arguments.contains("--ui-snapshots")
        _store = StateObject(wrappedValue: AppStore(preview: preview))
        if preview {
            guard let index = arguments.firstIndex(of: "--ui-snapshots"), index + 1 < arguments.count else {
                print("需要指定合成数据截图输出目录"); exit(2)
            }
            do { try MonitorSnapshots.write(to: URL(fileURLWithPath: arguments[index + 1])); exit(0) }
            catch { print("界面截图失败：\(error)"); exit(1) }
        }
    }
    var body: some Scene {
        Window("Codex Monitor", id: "main") {
            RootView(store: store).frame(minWidth: 640, minHeight: 660)
                .ignoresSafeArea(.container, edges: .top)
                .task { store.startIfNeeded() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 744)
        .commands { CommandGroup(replacing: .newItem) {} }
        MenuBarExtra {
            RootView(store: store, showsHUD: false).frame(width: 720, height: 660)
                .task { store.startIfNeeded() }
        } label: {
            Label("\(Display.tokens(store.dashboard.today.total))", systemImage: "chart.bar.xaxis")
        }
        .menuBarExtraStyle(.window)
    }
}
