import SwiftUI
import CodexMonitorCore

struct SkillsView: View {
    @ObservedObject var store: AppStore
    @State private var selected: SkillRow?
    @State private var search = ""
    private var rows: [SkillRow] {
        store.skillRows.filter { search.isEmpty || $0.skill.name.localizedCaseInsensitiveContains(search) || $0.skill.description.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        if !store.configuration.skillsEnabled {
            VStack(spacing: 12) {
                EmptyPanel(title: "Skills 分析已关闭", detail: "可在设置中开启。Token 统计仍然正常工作。", icon: "square.stack.3d.up.slash")
                Spacer()
            }
        } else {
            VStack(spacing: 12) {
                HStack {
                    Text("Skill 观察").font(.system(size: 13, weight: .semibold))
                    Text("\(store.snapshot.skills.count) 个目录").font(.system(size: 11)).foregroundStyle(MonitorTheme.muted)
                    Spacer()
                    Picker("观察范围", selection: $store.window) {
                        ForEach(TimeWindow.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().fixedSize().controlSize(.small)
                    MonitorIconButton(icon: "plus", label: "添加 Skills 目录") { store.addSkillRoot() }
                }.frame(height: 25)
                ScrollView {
                    VStack(spacing: 12) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 9)], spacing: 9) {
                            ForEach(rows) { row in
                                SkillTile(row: row) { selected = row }
                            }
                        }
                        if rows.isEmpty {
                            EmptyPanel(title: "暂无 Skill 目录", detail: "添加项目或实际 Skills 根目录；本地文件存在不代表当前已启用。", icon: "square.stack.3d.up")
                            Button("添加项目…") { store.addProject() }
                        }
                        Notice(text: "读取返回成功 ≠ 指令被执行有效。生效状态来自离线快照或标记未知，不自动禁用任何 Skill。")
                        evidenceTable
                    }.padding(.bottom, 2)
                }
                HStack(spacing: 0) {
                    summary("已观察使用证据", "\(store.skillRows.filter { !$0.evidence.isEmpty }.count)")
                    Rectangle().fill(MonitorTheme.stroke).frame(width: 1, height: 32)
                    summary("成功读取返回", "\(store.skillRows.reduce(0) { $0 + $1.count(.fileRead) })")
                    Rectangle().fill(MonitorTheme.stroke).frame(width: 1, height: 32)
                    summary("目录 Token 粗估", "≈ \(store.snapshot.skills.reduce(0) { $0 + $1.catalogTokenEstimate })")
                }.padding(.vertical, 11).monitorSurface()
            }.sheet(item: $selected) { row in DetailShell(title: "Skill 证据详情") { SkillDetail(store: store, row: row) } }
        }
    }
    private var evidenceTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("最近证据").font(.system(size: 13, weight: .semibold))
                Spacer()
                TextField("搜索 Skill", text: $search).textFieldStyle(.plain).font(.system(size: 11))
                    .padding(7).frame(width: 170).background(MonitorTheme.inset, in: RoundedRectangle(cornerRadius: 6))
            }.padding(12)
            let records = rows.flatMap { row in row.evidence.map { (row, $0) } }
                .sorted { ($0.1.date ?? .distantPast) > ($1.1.date ?? .distantPast) }
            ForEach(Array(records.prefix(8).enumerated()), id: \.offset) { _, record in
                Button { selected = record.0 } label: {
                    HStack(spacing: 10) {
                        Circle().fill(record.1.kind == .fileRead ? MonitorTheme.accent : MonitorTheme.cyan).frame(width: 6, height: 6)
                        Text(record.0.skill.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(record.1.kind.label).font(.system(size: 11)).foregroundStyle(MonitorTheme.secondary)
                        Text(record.1.date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "未知")
                            .font(.system(size: 11)).foregroundStyle(MonitorTheme.muted).monospacedDigit().frame(width: 55, alignment: .trailing)
                    }.padding(.horizontal, 14).frame(height: 38)
                        .overlay(alignment: .top) { Rectangle().fill(MonitorTheme.stroke).frame(height: 1) }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if records.isEmpty { Text("已扫描范围内暂无匹配证据").font(.caption).foregroundStyle(MonitorTheme.muted).padding(24) }
        }.monitorSurface()
    }
    private func summary(_ title: String, _ value: String) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(MonitorTheme.secondary)
            Text(value).font(.system(size: 18, weight: .bold)).monospacedDigit()
        }.frame(maxWidth: .infinity)
    }
}

private struct SkillTile: View {
    let row: SkillRow
    var select: () -> Void
    @State private var hovered = false
    private var color: Color { row.count(.fileRead) > 0 ? MonitorTheme.accent : row.evidence.isEmpty ? MonitorTheme.muted : MonitorTheme.cyan }
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(row.skill.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }.foregroundStyle(MonitorTheme.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(row.count(.fileRead))").font(.system(size: 29, weight: .semibold)).monospacedDigit().foregroundStyle(color)
                    Text("次读取返回成功").font(.system(size: 10)).foregroundStyle(MonitorTheme.muted)
                }
                HStack {
                    Text("\(row.sessions) 个对话 · \(row.count(.requested)) 次提及")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").opacity(hovered ? 1 : 0.3)
                }.font(.system(size: 10)).foregroundStyle(MonitorTheme.muted)
            }.padding(.horizontal, 13).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered ? MonitorTheme.surface : MonitorTheme.inset, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(MonitorTheme.stroke))
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 2, height: 40).padding(.leading, 4) }
        }.buttonStyle(.plain).onHover { hovered = $0 }.help("查看 \(row.skill.name) 的证据与目录状态")
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
        }.frame(maxWidth:.infinity,alignment:.leading).padding(14).background(MonitorTheme.inset,in:RoundedRectangle(cornerRadius:10))
    }
}
