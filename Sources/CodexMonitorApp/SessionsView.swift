import SwiftUI
import CodexMonitorCore

struct SessionsView: View {
    @ObservedObject var store: AppStore
    @State private var selected: String?
    @State private var search = ""
    private var rows: [TaskUsage] {
        store.tasks.filter { search.isEmpty || store.title($0.root).localizedCaseInsensitiveContains(search) ||
            $0.root.models.joined(separator:" ").localizedCaseInsensitiveContains(search) || $0.root.id.contains(search) }
    }
    var body: some View {
        if store.snapshot.sessions.isEmpty {
            EmptyPanel(title:"暂无对话",detail:"先扫描本地 Codex 数据，或打开演示模式。",icon:"bubble.left.and.bubble.right")
        } else {
            HSplitView {
                VStack(spacing:0) {
                    TextField("搜索对话、模型或 ID",text:$search).textFieldStyle(.roundedBorder).padding(16)
                    List(selection:$selected) {
                        ForEach(rows) { task in
                            VStack(alignment:.leading,spacing:8) {
                                Text(store.title(task.root)).font(.callout.weight(.medium)).lineLimit(2)
                                HStack {
                                    Text("\(task.descendants.count) 个子代理").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(Display.tokens(task.total.total)).fontWeight(.semibold).monospacedDigit()
                                }.font(.caption)
                                if !store.privacyMode, let cwd = task.root.cwd {
                                    Text(URL(fileURLWithPath:cwd).lastPathComponent).font(.caption2).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical,8).tag(task.id)
                        }
                    }.listStyle(.inset)
                }.frame(minWidth:260,idealWidth:300,maxWidth:380)
                if let task = rows.first(where:{$0.id == selected}) ?? rows.first {
                    TaskDetail(store:store,task:task).frame(minWidth:420,maxWidth:.infinity)
                } else { EmptyPanel(title:"没有匹配的任务",detail:"尝试其他名称或模型。",icon:"magnifyingglass") }
            }
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
            .background(Color.blue.opacity(0.06),in:RoundedRectangle(cornerRadius:10))
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
