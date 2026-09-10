import AppKit
import SwiftUI
import CodexMonitorCore

enum MonitorTab: String, CaseIterable, Identifiable {
    case codex = "Codex", skills = "Skills"
    var id: String { rawValue }
}

struct RootView: View {
    @ObservedObject var store: AppStore
    @State private var tab: MonitorTab
    @State private var settingsShown = false
    @Environment(\.openWindow) private var openWindow
    var showsHUD = true

    init(store: AppStore, initialTab: MonitorTab = .codex, showsHUD: Bool = true) {
        self.store = store; self.showsHUD = showsHUD
        _tab = State(initialValue: initialTab)
    }
    var body: some View {
        VStack(spacing: 0) {
            if showsHUD {
                HUDSummary(store: store).frame(height: 42).frame(width: 390).padding(.top, 10).padding(.bottom, 18)
            }
            VStack(spacing: 14) {
                header
                tabs
                if let error = store.lastError { Notice(text: error, warning: true) }
                if store.snapshot.progress.pendingFiles > 0 {
                    Notice(text: "回填中 · 还有 \(store.snapshot.progress.pendingFiles) 个文件。以下为已扫描部分。", warning: true)
                }
                Group {
                    if tab == .codex { OverviewView(store: store) }
                    else { SkillsView(store: store) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }.padding(.horizontal, 18).padding(.top, showsHUD ? 0 : 18).padding(.bottom, 12)
        }
        .foregroundStyle(MonitorTheme.text).background(MonitorTheme.background)
        .preferredColorScheme(.dark).tint(MonitorTheme.accent)
        .sheet(isPresented: $settingsShown) {
            DetailShell(title: "设置与隐私") { SettingsView(store: store) }
        }
        .onAppear {
            store.hud.onOpen = { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Text(tab == .codex ? "Codex Monitor" : "Skill Insights").font(.system(size: 23, weight: .bold)).tracking(-0.6)
            MonitorBadge(text: store.demo ? "演示" : store.scanning ? "扫描中" : tab == .skills ? "本地证据" : store.dashboard.activity.rawValue,
                         color: store.demo ? MonitorTheme.amber : tab == .skills ? MonitorTheme.cyan : MonitorTheme.color(store.dashboard.activity))
            Spacer(minLength: 8)
            if store.scanning { ProgressView().controlSize(.small).frame(width: 30, height: 30) }
            else { MonitorIconButton(icon: "arrow.clockwise", label: "刷新 / 继续回填") { store.refresh() } }
            MonitorIconButton(icon: "gearshape", label: "设置与隐私") { settingsShown = true }
        }.frame(height: 36)
    }
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(MonitorTab.allCases) { item in
                Button { tab = item } label: {
                    Text(item.rawValue).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tab == item ? MonitorTheme.text : MonitorTheme.secondary)
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .background(tab == item ? MonitorTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }.padding(3).background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: store.demo ? "flask" : "lock.shield").font(.system(size: 10))
            Text(store.demo ? "演示数据 · 非真实账户" : "只读本机日志 · 额度与运行状态均为日志快照").lineLimit(1)
            Spacer(minLength: 4)
            Text(store.snapshot.createdAt, style: .time).monospacedDigit()
            Menu {
                Button("导出 Markdown") { store.export(json: false) }
                Button("导出 JSON") { store.export(json: true) }
                Divider()
                Toggle("自动刷新", isOn: $store.autoRefresh)
                Toggle("隐私显示", isOn: $store.privacyMode)
                Button("显示 / 隐藏浮动条") { store.hud.toggle(store: store) }
                Button(store.demo ? "退出演示模式" : "查看演示数据") { store.toggleDemo() }
                Button("退出 Codex Monitor") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis").frame(width: 18, height: 16) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("报告、显示与退出")
        }.font(.system(size: 10)).foregroundStyle(MonitorTheme.muted)
    }
}
