import AppKit
import Combine
import CodexMonitorCore
import Foundation
import UniformTypeIdentifiers

typealias SkillSnapshotLoader = @Sendable (LedgerConfiguration) async throws -> LedgerSnapshot

/// 仅提供 Skills 增量；不参与 ALight 的额度、Token 或成本计算。
@MainActor
final class SkillInsightsViewModel: ObservableObject {
    @Published private(set) var snapshot: LedgerSnapshot?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var message = "点击刷新分析本机 Skills，不调用模型。"
    @Published var search = ""
    @Published var days = 7
    @Published private(set) var importedSkills: [CodexMonitorCore.Skill] = []
    private let defaults: UserDefaults
    private let loader: SkillSnapshotLoader
    private var task: Task<Void, Never>?
    private var generation = 0

    init(defaults: UserDefaults = .standard, loader: SkillSnapshotLoader? = nil) {
        self.defaults = defaults
        let engine = AnalysisEngine()
        self.loader = loader ?? { configuration in try await engine.refresh(configuration) }
        // 不在初始化、展开 HUD、切换 Tab 时自动扫描历史。
    }

    deinit { task?.cancel() }

    var enabled: Bool { defaults.object(forKey: "skills.enabled") as? Bool ?? true }
    var status: String {
        if !enabled { return "已关闭" }
        if isAnalyzing { return "分析中" }
        guard let snapshot else { return "待分析" }
        return snapshot.progress.pendingFiles > 0 || !snapshot.progress.issues.isEmpty ? "部分数据" : "已更新"
    }
    var rows: [SkillRow] {
        guard let snapshot else { return [] }
        var catalog = Dictionary(uniqueKeysWithValues: snapshot.skills.map { ($0.path, $0) })
        for skill in importedSkills { catalog[skill.path] = skill }
        let since = Calendar.current.date(byAdding: .day, value: -days, to: snapshot.createdAt)
        return LedgerMath.skillRows(Array(catalog.values), sessions: snapshot.sessions, since: since).map { row in
            var row = row
            row.evidence.removeAll { ($0.date ?? .distantFuture) > snapshot.createdAt }
            return row
        }.filter { row in
            search.isEmpty || row.skill.name.localizedCaseInsensitiveContains(search)
                || row.skill.description.localizedCaseInsensitiveContains(search)
        }
    }

    func analyze() {
        guard enabled, !isAnalyzing else { return }
        generation += 1
        let current = generation
        let home = defaults.string(forKey: "skills.codexHome")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configuration = LedgerConfiguration(
            codexHome: home,
            projects: defaults.stringArray(forKey: "skills.projects") ?? [],
            skillRoots: defaults.stringArray(forKey: "skills.roots") ?? [],
            cacheDirectory: support.appendingPathComponent("CodexMonitor-ALight/Skills").path,
            byteBudget: 32 * 1024 * 1024, timeBudget: 2
        )
        isAnalyzing = true
        message = "本机分片分析中，可随时取消。"
        let loader = loader
        task = Task { [weak self] in
            do {
                let result = try await loader(configuration)
                guard !Task.isCancelled, let self, current == self.generation else { return }
                self.snapshot = result
                let pending = result.progress.pendingFiles
                self.message = pending > 0
                    ? "还有 \(pending) 个文件待回填；点击刷新继续，不重复扫描已完成部分。"
                    : "已分析 \(result.progress.files) 个文件；证据不等于执行效果。"
                if !result.progress.issues.isEmpty {
                    self.message += " 有 \(result.progress.issues.count) 项数据完整度提示，未观察到不等于未使用。"
                }
                self.isAnalyzing = false
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, current == self.generation else { return }
                self.isAnalyzing = false
                self.task = nil
                self.message = "分析未完成，请检查本机数据目录和读取权限；未清空上一轮结果。"
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isAnalyzing = false
        message = "已停止分析，保留上一轮结果。"
    }

    func openSession(_ id: String) {
        guard UUID(uuidString: id) != nil, let url = URL(string: "codex://threads/\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    func importCatalog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, url.lastPathComponent != "auth.json" else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size < 4 * 1024 * 1024 else { throw LedgerError.invalidCatalog }
            importedSkills = try SkillCatalog.decodeSnapshot(Data(contentsOf: url))
            message = "目录状态仅代表这次导入的 skills/list 快照，不倒推历史。"
        } catch { message = "目录快照无效；需要已有的 skills/list JSON 响应。" }
    }

    /// 只导出计数，不附带路径、项目名、会话 ID、描述或原文。
    static func report(_ rows: [SkillRow], days: Int, date: Date?, partial: Bool) -> [String: Any] {
        ["schemaVersion": 1, "periodDays": days,
         "analyzedAt": date.map { ISO8601DateFormatter().string(from: $0) } ?? "未分析",
         "quality": partial ? "PARTIAL" : "OBSERVED",
         "perSkillTokens": "UNAVAILABLE",
         "rows": rows.map { row in
             ["name": row.skill.name, "requested": row.count(.requested),
              "readAttempts": row.count(.readAttempt), "successfulReads": row.count(.fileRead),
              "declarations": row.count(.declared), "relatedSessions": row.sessions,
              "currentState": row.skill.state.rawValue,
              "catalogTokenEstimate": row.skill.catalogTokenEstimate] as [String: Any]
         }]
    }

    func export(markdown: Bool) {
        guard let snapshot else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = markdown ? "skills-report.md" : "skills-report.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if markdown {
                var text = "# Skills 使用证据\n\n最近 \(days) 天；仅已观察记录，不是完整调用账单。\n\n读取成功不等于执行有效；逐 Skill Token 不可用。\n\n"
                for row in rows {
                    let name = row.skill.name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "`", with: "")
                    text += "- `\(name)`：明确指定 \(row.count(.requested))；读取尝试 \(row.count(.readAttempt))；读取成功 \(row.count(.fileRead))；关联对话 \(row.sessions)。\n"
                }
                data = Data(text.utf8)
            } else {
                data = try JSONSerialization.data(withJSONObject: Self.report(rows, days: days, date: snapshot.createdAt,
                    partial: snapshot.progress.pendingFiles > 0 || !snapshot.progress.issues.isEmpty), options: [.prettyPrinted, .sortedKeys])
            }
            try data.write(to: url, options: .atomic)
            message = "报告已导出；分享前仍请检查 Skill 名称。"
        } catch { message = "导出失败，请检查所选位置权限。" }
    }
}
