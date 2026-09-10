import SwiftUI
import CodexMonitorCore

struct SkillsView: View {
    @ObservedObject var store: AppStore
    @State private var selected: String?
    @State private var search = ""
    private var rows: [SkillRow] {
        store.skillRows.filter { search.isEmpty || $0.skill.name.localizedCaseInsensitiveContains(search) || $0.skill.description.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        if !store.configuration.skillsEnabled {
            EmptyPanel(title:"Skills 分析已关闭",detail:"可在设置中开启。本地 Token 统计仍可使用。",icon:"square.stack.3d.up.slash")
        } else {
            HSplitView {
                VStack(spacing:0) {
                    TextField("搜索 Skill",text:$search).textFieldStyle(.roundedBorder).padding(16)
                    List(selection:$selected) {
                        ForEach(rows) { row in
                            VStack(alignment:.leading,spacing:8) {
                                HStack {
                                    Text(row.skill.name).font(.callout.weight(.medium))
                                    Spacer()
                                    Text("\(row.count(.fileRead))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Text(row.skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                HStack {
                                    Text(row.skill.scope)
                                    Spacer()
                                    Text(row.skill.state == .unknown ? "生效状态未知" : row.skill.state == .enabled ? "快照：启用" : "快照：停用")
                                }.font(.caption2).foregroundStyle(.secondary)
                            }.padding(.vertical,8).tag(row.id)
                        }
                    }.listStyle(.inset)
                    Button("添加 Skills 目录") { store.addSkillRoot() }.padding(16)
                }.frame(minWidth:260,idealWidth:310,maxWidth:380)
                if let row = rows.first(where:{$0.id == selected}) ?? rows.first {
                    SkillDetail(store:store,row:row).frame(minWidth:420,maxWidth:.infinity)
                } else {
                    VStack(spacing:16) {
                        EmptyPanel(title:"未发现 Skill",detail:"默认读取用户目录与手动添加项目。插件缓存不会被当作已启用目录；可手动添加其实际 Skills 目录。",icon:"square.stack.3d.up")
                        Button("添加项目") { store.addProject() }
                    }.padding(24)
                }
            }
        }
    }
}

private struct SkillDetail: View {
    @ObservedObject var store: AppStore
    let row: SkillRow
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Text(row.skill.name).font(.title2.bold()).textSelection(.enabled)
                Text(row.skill.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Notice(text:row.skill.stateSource + "。当前目录状态不能倒推历史对话；没有使用证据也不等于不需要这个 Skill。")
                HStack(spacing:12) {
                    number("明确提及",row.count(.requested))
                    number("读取成功",row.count(.fileRead))
                    number("关联对话",row.sessions)
                }
                Surface {
                    VStack(alignment:.leading,spacing:10) {
                        Text("目录描述开销").font(.headline)
                        Text("约 \(row.skill.catalogTokenEstimate) Token").font(.title3.weight(.medium))
                        Text("名称 + 描述 + 路径共 \(row.skill.catalogCharacters) 字符，按字符 / 4 粗估。中文、模型 tokenizer、目录截断会改变实际值；不是每次请求的账单，也不是完整 Skill 正文开销。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("逐 Skill 实际用量：不可用").font(.callout.weight(.medium))
                    }
                }
                Surface {
                    VStack(alignment:.leading,spacing:14) {
                        HStack { Text("使用证据").font(.headline); Spacer(); Text(store.window.rawValue).font(.caption).foregroundStyle(.secondary) }
                        if row.evidence.isEmpty {
                            Text("已扫描范围内未观察到匹配证据。不要据此自动禁用或删除。").foregroundStyle(.secondary)
                        }
                        ForEach(row.evidence.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(100)) { evidence in
                            VStack(alignment:.leading,spacing:7) {
                                HStack {
                                    Image(systemName:evidence.kind == .fileRead ? "doc.text.magnifyingglass" : "text.bubble")
                                    Text(evidence.kind.label).font(.callout.weight(.medium))
                                    Spacer()
                                    if let date = evidence.date { Text(date,style:.date).font(.caption).foregroundStyle(.secondary) }
                                }
                                if let session = store.snapshot.sessions.first(where:{$0.id == evidence.sessionID}) {
                                    Button(store.title(session)) { store.openSession(session) }.buttonStyle(.link).disabled(store.demo)
                                }
                                Text("日志字节偏移：\(evidence.sourceOffset) · 不保存原始 Prompt/工具输出")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if !evidence.sourceFile.isEmpty && !store.privacyMode {
                                    Button("定位证据日志") { store.revealSource(evidence.sourceFile) }.font(.caption).disabled(store.demo)
                                }
                            }
                            Divider()
                        }
                    }
                }
                Notice(text:"“读取返回成功”仅说明简单读取命令返回了成功状态，不证明完整指令已加载、被遵守或提高质量。“明确提及”包括文本中的 $skill 标记，可能是举例。")
                if !store.privacyMode {
                    Text(row.skill.path).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(24)
        }
    }
    private func number(_ label:String,_ value:Int) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text("\(value)").font(.system(size:26,weight:.semibold,design:.rounded)).monospacedDigit()
        }.frame(maxWidth:.infinity,alignment:.leading).padding(14).background(Color.blue.opacity(0.06),in:RoundedRectangle(cornerRadius:10))
    }
}
