import Foundation

public enum Reports {
    public static func markdown(_ snapshot: LedgerSnapshot, since: Date? = nil) -> String {
        let usage = LedgerMath.usage(snapshot.sessions, since: since)
        let aliases = Dictionary(uniqueKeysWithValues: snapshot.sessions.enumerated().map { ($0.element.id, "对话 \($0.offset + 1)") })
        var lines = ["# Codex Monitor 本地分析", "", "生成时间：\(snapshot.createdAt.formatted(.iso8601))", "",
            "数据来源：\(snapshot.isDemo ? "演示数据" : "本机日志")；待扫描文件：\(snapshot.progress.pendingFiles)。",
            "导出已隐藏对话标题、项目路径和原始会话 ID；Skill 名称与模型名称仍保留。", "",
            "## 用量", "", "输入：\(usage.input)；其中缓存输入：\(usage.cached)；输出：\(usage.output)；总计：\(usage.total)。",
            "总计 = 输入 + 输出；reasoning 已包含于输出。按日期的统计排除无法归属时间的基线。", "",
            "## 任务累计用量（父子拆分，不随上面的日期窗口裁剪）", "",
            "| 任务 | 父对话 | 子代理 | 合计 |", "| --- | ---: | ---: | ---: |"]
        for task in LedgerMath.tasks(snapshot.sessions) {
            lines.append("| \(aliases[task.id] ?? "未知") | \(task.root.ownTokens.total) | \(task.childrenTokens.total) | \(task.total.total) |")
        }
        lines += ["", "## Skill 使用证据", "", "| Skill | 明确提及 | 读取尝试 | 成功返回 | 关联对话 |", "| --- | ---: | ---: | ---: | ---: |"]
        for row in LedgerMath.skillRows(snapshot.skills, sessions: snapshot.sessions, since: since) {
            lines.append("| \(escape(row.skill.name)) | \(row.count(.requested)) | \(row.count(.readAttempt)) | \(row.count(.fileRead)) | \(row.sessions) |")
        }
        lines += ["", "Skill 证据不证明指令执行有效。无法计算逐 Skill 实际 Token 或可靠误触发率。目录大小是字符启发式估算，不是实际计费。", "",
                  "## 完整度", "", "扫描文件：\(snapshot.progress.files)；已追平：\(snapshot.progress.caughtUp)；本轮读取：\(snapshot.progress.bytesRead) 字节。",
                  "存在诊断的会话：\(snapshot.sessions.filter { !$0.issues.isEmpty }.count)。请在本机界面核对具体诊断。"]
        return lines.joined(separator: "\n") + "\n"
    }
    public static func json(_ snapshot: LedgerSnapshot) throws -> Data {
        struct PublicSession: Codable {
            var alias: String; var parentAlias: String?; var models: [String]; var tokens: Tokens; var quality: Quality
        }
        struct PublicSkill: Codable {
            var name: String; var state: SkillState; var mentions: Int; var reads: Int; var relatedSessions: Int
        }
        struct Export: Codable {
            var schemaVersion = 1; var generatedAt: Date; var demo: Bool; var pendingFiles: Int
            var sessions: [PublicSession]; var skills: [PublicSkill]
        }
        let aliases = Dictionary(uniqueKeysWithValues: snapshot.sessions.enumerated().map { ($0.element.id, "session-\($0.offset + 1)") })
        let output = Export(generatedAt: snapshot.createdAt, demo: snapshot.isDemo, pendingFiles: snapshot.progress.pendingFiles,
            sessions: snapshot.sessions.map { s in PublicSession(alias: aliases[s.id]!, parentAlias: s.parentID.flatMap { aliases[$0] }, models: s.models, tokens: s.ownTokens, quality: s.quality) },
            skills: LedgerMath.skillRows(snapshot.skills, sessions: snapshot.sessions, since: nil).map {
                PublicSkill(name: $0.skill.name, state: $0.skill.state, mentions: $0.count(.requested), reads: $0.count(.fileRead), relatedSessions: $0.sessions)
            })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(output)
    }
    private static func escape(_ s: String) -> String { Display.safe(s).replacingOccurrences(of: "|", with: "\\|") }
}
