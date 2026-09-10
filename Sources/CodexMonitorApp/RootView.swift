import SwiftUI
import CodexMonitorCore

private enum Page: String, CaseIterable, Identifiable {
    case overview = "概览", sessions = "对话与子代理", skills = "Skills", settings = "设置与隐私"
    var id: String { rawValue }
    var icon: String {
        switch self { case .overview: "square.grid.2x2"; case .sessions: "bubble.left.and.bubble.right"; case .skills: "square.stack.3d.up"; case .settings: "slider.horizontal.3" }
    }
}
struct RootView: View {
    @ObservedObject var store: AppStore
    @State private var page: Page? = .overview
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CODEX MONITOR").font(.system(size: 13, weight: .bold, design: .rounded)).tracking(1.4)
                    Text("看见用量，也看见证据").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
                List(Page.allCases, selection: $page) { p in Label(p.rawValue, systemImage: p.icon).tag(p) }
                    .listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label("默认离线 · 无账户登录", systemImage: "lock.shield").font(.caption)
                    Text("0.1.0 / macOS 原生").font(.caption2).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(220)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text((page ?? .overview).rawValue).font(.title2.bold())
                        Text(store.demo ? "演示数据 · 不是你的真实用量" : "只读本机日志 · 不追踪桌面当前选中的窗口")
                            .font(.caption).foregroundStyle(store.demo ? Color.orange : Color.secondary)
                    }
                    Spacer()
                    if page != .settings {
                        if page == .overview || page == .skills {
                            Picker("统计窗口", selection: $store.window) {
                                ForEach(TimeWindow.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().frame(width: 120)
                        }
                        Menu {
                            Button("导出 Markdown") { store.export(json: false) }
                            Button("导出 JSON") { store.export(json: true) }
                        } label: { Image(systemName: "square.and.arrow.up") }
                        .menuStyle(.borderlessButton).frame(width: 28)
                    }
                    Button { store.refresh() } label: {
                        if store.scanning { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }.disabled(store.scanning).help("刷新；未完成的扫描会从检查点继续")
                }.padding(24)
                if let error = store.lastError { Notice(text: error, warning: true).padding(.horizontal, 24).padding(.bottom, 12) }
                Divider()
                Group {
                    switch page ?? .overview {
                    case .overview: OverviewView(store: store)
                    case .sessions: SessionsView(store: store)
                    case .skills: SkillsView(store: store)
                    case .settings: SettingsView(store: store)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(spacing: 12) {
                    Circle().fill(store.scanning ? Color.blue : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Text(store.scanning ? "正在扫描；只在完整行提交检查点" : "已扫描 \(store.snapshot.progress.caughtUp) / \(store.snapshot.progress.files) 个文件")
                    if store.snapshot.progress.pendingFiles > 0 { Text("结果尚未追平").foregroundStyle(.orange) }
                    Spacer()
                    Toggle("自动刷新", isOn: $store.autoRefresh).toggleStyle(.checkbox)
                    Text(store.snapshot.createdAt, style: .time).monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal,24).padding(.vertical,10)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

struct Surface<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}
struct Metric: View {
    let title: String; let value: String; let detail: String
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}
struct Notice: View {
    let text: String
    var warning = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: warning ? "exclamationmark.triangle" : "info.circle").foregroundStyle(warning ? Color.orange : Color.secondary)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer(minLength: 0)
        }.padding(14).background((warning ? Color.orange : Color.secondary).opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
struct EmptyPanel: View {
    let title: String; let detail: String; let icon: String
    var body: some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(detail)).frame(maxWidth: .infinity, minHeight: 220)
    }
}
