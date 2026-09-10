import AppKit
import CodexMonitorCore
import SwiftUI

/// 嵌入原版 DetailPanelView，不另建主窗口、不改变 Codex/Radar 页。
struct SkillInsightsPanelView: View {
    @ObservedObject var model: SkillInsightsViewModel
    private let accent = Color(red: 0.61, green: 0.95, blue: 0.68)

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                metric("Skill 目录", model.rows.count)
                metric("读取成功", model.rows.reduce(0) { $0 + $1.count(.fileRead) })
                metric("生效未知", model.rows.filter { $0.skill.state == .unknown }.count)
            }
            HStack(spacing: 6) {
                TextField("搜索 Skill", text: $model.search)
                    .textFieldStyle(.plain).font(.system(size: 10))
                    .padding(7).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                Picker("范围", selection: $model.days) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                }.labelsHidden().frame(width: 76).controlSize(.mini)
                if model.isAnalyzing {
                    Button("取消", action: model.cancel).controlSize(.mini)
                } else {
                    Button(model.snapshot == nil ? "分析" : "继续 / 刷新", action: model.analyze).controlSize(.mini)
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if model.snapshot == nil {
                        Text("从原版面板直接查看本机 Skill 证据。首次点击分析；用户和项目目录在设置 → Skills 配置。")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).padding(10)
                    } else if model.rows.isEmpty {
                        Text("当前搜索或已扫描范围内没有 Skill；可添加项目目录或继续回填。")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).padding(10)
                    }
                    ForEach(model.rows) { row in
                        DisclosureGroup {
                            evidenceDetails(row)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Circle().fill(row.count(.fileRead) > 0 ? accent : .white.opacity(0.26)).frame(width: 5, height: 5)
                                    Text(row.skill.name).font(.system(size: 10.5, weight: .bold)).lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text("读取 \(row.count(.fileRead)) · 对话 \(row.sessions)")
                                        .font(.system(size: 9, weight: .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.58))
                                }
                                Text(row.skill.description).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)
                                HStack {
                                    Text(row.skill.scope)
                                    Spacer()
                                    Text(row.skill.state == .unknown ? "生效状态未知" : row.skill.state == .enabled ? "快照：启用" : "快照：停用")
                                }.font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.38))
                            }
                        }
                        .tint(.white.opacity(0.6))
                        .padding(9)
                        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1))
                    }
                }
            }.frame(maxHeight: .infinity, alignment: .top)
            Text(model.message).font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("导入目录快照", action: model.importCatalog)
                Spacer(minLength: 0)
                Button("Markdown") { model.export(markdown: true) }.disabled(model.snapshot == nil)
                Button("JSON") { model.export(markdown: false) }.disabled(model.snapshot == nil)
            }.controlSize(.mini).font(.system(size: 9))
        }.foregroundStyle(.white.opacity(0.82))
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            Text("\(value)").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(accent).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func evidenceDetails(_ row: SkillRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("明确指定 \(row.count(.requested)) · 尝试读取 \(row.count(.readAttempt)) · 助手声明 \(row.count(.declared))")
            Text("目录描述约 \(row.skill.catalogTokenEstimate) Token（字符粗估）；逐 Skill 实耗不可用。")
            Text(row.skill.stateSource).foregroundStyle(.white.opacity(0.42))
            ForEach(row.evidence.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(30)) { item in
                HStack(alignment: .top, spacing: 5) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.kind.label)
                        Text("字节偏移 \(item.sourceOffset)").foregroundStyle(.white.opacity(0.35))
                    }
                    Spacer(minLength: 0)
                    if let date = item.date { Text(date, style: .date).foregroundStyle(.white.opacity(0.45)) }
                    Button("对话") { model.openSession(item.sessionID) }
                        .buttonStyle(.plain).foregroundStyle(accent)
                }.padding(.vertical, 3)
            }
            if row.evidence.isEmpty { Text("未观察到证据，不等于不需要这个 Skill。") }
            Text("读取成功不等于完整指令已遵循或产生效果。")
                .foregroundStyle(.white.opacity(0.4))
        }.font(.system(size: 9)).padding(.top, 8)
    }
}

struct SkillInsightsSettingsView: View {
    @AppStorage("skills.enabled") private var enabled = true
    @AppStorage("skills.codexHome") private var codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    @State private var projects = UserDefaults.standard.stringArray(forKey: "skills.projects") ?? []
    @State private var roots = UserDefaults.standard.stringArray(forKey: "skills.roots") ?? []

    var body: some View {
        Section("Skills 本地证据分析") {
            Toggle("启用 Skills 页面", isOn: $enabled)
            Text("本页设置即时保存；关闭后停止正在运行的 Skills 分析，不影响原版 Token、额度和其他页面。")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Codex 数据目录") {
                Text(codexHome).lineLimit(1).truncationMode(.middle)
                Button("选择") { if let path = chooseDirectory() { codexHome = path } }
            }
            Text("分析为手动触发，每轮约 32 MiB / 2 秒预算；大型历史分轮继续。Skill 文件存在不代表当前启用。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("项目目录") {
            ForEach(projects, id: \.self) { path in
                HStack {
                    Text(path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("移除") { projects.removeAll { $0 == path }; save() }
                }
            }
            Button("添加项目") { if let path = chooseDirectory(), !projects.contains(path) { projects.append(path); save() } }
        }
        Section("额外 Skills 根目录") {
            ForEach(roots, id: \.self) { path in
                HStack {
                    Text(path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("移除") { roots.removeAll { $0 == path }; save() }
                }
            }
            Button("添加 Skills 根目录") { if let path = chooseDirectory(), !roots.contains(path) { roots.append(path); save() } }
            Text("插件的真实 Skills 目录可手动添加；不会把缓存目录当作启用证据。原始 Prompt / 回答不会写入派生缓存。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func save() {
        UserDefaults.standard.set(projects, forKey: "skills.projects")
        UserDefaults.standard.set(roots, forKey: "skills.roots")
    }
    private func chooseDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
