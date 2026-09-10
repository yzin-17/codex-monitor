import SwiftUI
import CodexMonitorCore

struct SessionsView: View {
    @ObservedObject var store: AppStore
    @State private var selected: TaskUsage?
    @State private var search = ""
    @State private var showsSearch = false
    private var rows: [MonitorTaskRow] {
        store.dashboard.rows.filter {
            search.isEmpty || store.title($0.task.root).localizedCaseInsensitiveContains(search)
                || $0.task.root.models.joined(separator: " ").localizedCaseInsensitiveContains(search)
                || $0.id.contains(search)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("Session")
                    Button { showsSearch.toggle(); if !showsSearch { search = "" } } label: { Image(systemName: "magnifyingglass").font(.system(size: 10)) }
                        .buttonStyle(.plain).help("搜索对话、模型或 ID").accessibilityLabel("搜索会话")
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text("Status").frame(width: 86)
                Text("Today").frame(width: 122, alignment: .trailing)
                Text("Total").frame(width: 86, alignment: .trailing)
            }.font(.system(size: 12, weight: .semibold)).foregroundStyle(MonitorTheme.secondary)
                .padding(.horizontal, 16).frame(height: 38)
            if showsSearch {
                TextField("搜索会话、模型或 ID", text: $search).textFieldStyle(.plain)
                    .padding(10).background(MonitorTheme.inset, in: RoundedRectangle(cornerRadius: 7))
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        SessionTableRow(store: store, row: row) { selected = row.task }
                    }
                }
                if rows.isEmpty {
                    VStack(spacing: 8) {
                        EmptyPanel(title: search.isEmpty ? "还没有可展示的对话" : "没有匹配的对话",
                                   detail: search.isEmpty ? "选择 Codex 数据目录，读取本地日志。也可以先查看演示界面。" : "换一个名称或模型试试。", icon: "bubble.left.and.bubble.right")
                        if search.isEmpty {
                            HStack(spacing: 16) {
                                Button("选择数据目录") { store.chooseCodexHome() }
                                Button("查看演示") { if !store.demo { store.toggleDemo() } }
                            }.padding(.bottom, 20)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minHeight: 220).monitorSurface().clipShape(RoundedRectangle(cornerRadius: 14))
            .sheet(item: $selected) { task in DetailShell(title: "对话与子代理") { TaskDetail(store: store, task: task) } }
    }
}

private struct SessionTableRow: View {
    @ObservedObject var store: AppStore
    let row: MonitorTaskRow
    var select: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Circle().fill(MonitorTheme.color(row.activity)).frame(width: 7, height: 7)
                    Text(store.title(row.task.root)).lineLimit(1).truncationMode(.tail)
                    if !row.task.descendants.isEmpty {
                        Text("+\(row.task.descendants.count)").font(.system(size: 10)).foregroundStyle(MonitorTheme.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                MonitorBadge(text: row.activity.rawValue, color: MonitorTheme.color(row.activity)).frame(width: 86)
                HStack(spacing: 5) {
                    Spacer(minLength: 0)
                    Text(Display.tokens(row.today.total))
                    Text(row.share.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                        .font(.system(size: 11)).foregroundStyle(MonitorTheme.secondary)
                }.frame(width: 122)
                Text(Display.tokens(row.task.total.total)).frame(width: 86, alignment: .trailing)
            }.font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .padding(.horizontal, 16).frame(height: 50)
                .background(row.activity == .running || hovered ? MonitorTheme.selected : .clear)
                .overlay(alignment: .leading) {
                    if row.activity == .running { Rectangle().fill(MonitorTheme.accent).frame(width: 3) }
                }
                .overlay(alignment: .bottom) { Rectangle().fill(MonitorTheme.stroke).frame(height: 1) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .help("点击查看父 / 子代理拆分。Today 为本地自然日；Total 为父子任务累计。状态来自日志，不是实时进程探测。")
            .contextMenu {
                Button("查看任务拆分", action: select)
                Button("在 Codex 中打开") { store.openSession(row.task.root) }.disabled(store.demo)
            }
    }
}

private struct TaskDetail: View {
    @ObservedObject var store: AppStore
    let task: TaskUsage
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:6) {
                        Text(store.title(task.root)).font(.title3.bold()).textSelection(.enabled)
                        Text("任务累计 · 所有已发现的子代理层级").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { store.openSession(task.root) } label: { Image(systemName:"arrow.up.forward.app") }
                        .help("在 Codex Desktop 中打开对话，不发送消息").disabled(store.demo)
                }
                HStack(spacing:10) {
                    compact("父对话",task.root.ownTokens.total)
                    compact("子代理",task.childrenTokens.total)
                    compact("任务合计",task.total.total)
                }
                Notice(text:"合计按已识别的父子关系去重。关系缺失的子代理会独立列出；不能凭文件更新时间猜它属于哪个任务。")
                Surface {
                    VStack(alignment:.leading,spacing:14) {
                        Text("执行成员").font(.headline)
                        member(task.root,isRoot:true)
                        ForEach(task.descendants) { child in Divider(); member(child,isRoot:false) }
                    }
                }
                let models = LedgerMath.models([task.root] + task.descendants)
                Surface {
                    VStack(alignment:.leading,spacing:12) {
                        Text("分模型 Token").font(.headline)
                        ForEach(models) { model in
                            VStack(alignment:.leading,spacing:6) {
                                HStack { Text(model.model).font(.system(.callout,design:.monospaced)); Spacer(); Text(Display.tokens(model.tokens.total)).monospacedDigit() }
                                Text("未缓存 \(Display.tokens(model.tokens.uncached)) · 缓存 \(Display.tokens(model.tokens.cached)) · 输出 \(Display.tokens(model.tokens.output))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                let samples = [task.root] + task.descendants
                let issues = Array(Set(samples.flatMap(\.issues))).sorted()
                if !issues.isEmpty { Notice(text:issues.joined(separator:"\n"),warning:true) }
                if !store.privacyMode {
                    Text(task.root.id).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    if let path = task.root.files.first {
                        Button("在 Finder 中定位源日志") { store.revealSource(path) }.disabled(store.demo)
                    }
                }
            }.padding(24)
        }
    }
    private func compact(_ label:String,_ value:Int64) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Display.tokens(value)).font(.system(size:22,weight:.semibold,design:.rounded)).monospacedDigit()
        }.frame(maxWidth:.infinity,alignment:.leading).padding(14)
            .background(MonitorTheme.inset,in:RoundedRectangle(cornerRadius:10))
    }
    private func member(_ session:Session,isRoot:Bool) -> some View {
        VStack(alignment:.leading,spacing:7) {
            HStack {
                Image(systemName:isRoot ? "person.crop.square" : "arrow.turn.down.right")
                Text(isRoot ? "父对话" : store.title(session)).font(.callout.weight(.medium))
                Spacer(); Text(Display.tokens(session.ownTokens.total)).monospacedDigit()
            }
            HStack {
                Text(session.models.joined(separator:" / ")).lineLimit(1)
                Spacer(); Text(session.status)
            }.font(.caption).foregroundStyle(.secondary)
            if let last = session.samples.last, let input = last.lastInput, let limit = last.contextLimit, limit > 0 {
                Text("最后请求输入 \(Display.tokens(input)) / 日志上下文上限 \(Display.tokens(limit)) · 压缩 \(session.compactions) 次")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if session.status == "日志显示运行中", let date = session.lastActivity, Date().timeIntervalSince(date) > 600 {
                Text("日志超过 10 分钟未更新，当前运行状态未确认").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
