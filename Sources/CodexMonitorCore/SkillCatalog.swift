import Foundation

public enum SkillCatalog {
    /// 文件系统发现不是 Codex 生效目录。不会扫描未激活插件缓存并声称 enabled。
    public static func discover(config: LedgerConfiguration) -> (skills: [Skill], issues: [String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [(URL, String, String?)] = [
            (home.appendingPathComponent(".agents/skills"), "用户", nil),
            (Paths.url(config.codexHome).appendingPathComponent("skills"), "Codex 本地", nil)
        ]
        roots += config.skillRoots.map { (Paths.url($0), "手动添加", nil) }
        for project in config.projects {
            let cwd = Paths.url(project)
            var path = cwd
            for _ in 0..<30 {
                roots.append((path.appendingPathComponent(".agents/skills"), "项目", cwd.path))
                if FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path) || path.path == "/" { break }
                path.deleteLastPathComponent()
            }
        }
        var skills: [String: Skill] = [:]; var issues: [String] = []
        for (root, scope, cwd) in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            var visited: Set<String> = []; var count = 0
            func walk(_ directory: URL, depth: Int) {
                guard depth <= 10, count < 3000 else { return }
                let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
                guard visited.insert(canonical.path).inserted else { return }
                count += 1
                let file = canonical.lastPathComponent == "SKILL.md" ? canonical : canonical.appendingPathComponent("SKILL.md")
                if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   values.isRegularFile == true, (values.fileSize ?? 0) <= 256 * 1024,
                   let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8),
                   let fields = frontmatter(text) {
                    let skill = Skill(name: fields.name, description: fields.description,
                        path: file.path, scope: scope, cwd: cwd)
                    // 同一路径跨作用域的实际生效规则未知，不覆盖成“全局已启用”。
                    skills[file.path] = skill
                    return
                }
                let children = (try? FileManager.default.contentsOfDirectory(at: canonical,
                    includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
                for child in children where ![".git", "node_modules", ".build", "assets", "references", "scripts"].contains(child.lastPathComponent) {
                    if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { walk(child, depth: depth + 1) }
                }
            }
            walk(root, depth: 0)
            if count >= 3000 { issues.append("Skill 根目录超过扫描预算，目录可能不完整") }
        }
        return (skills.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, issues)
    }

    public static func frontmatter(_ text: String) -> (name: String, description: String)? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0 == "---" }), end <= 200 else { return nil }
        var name: String?; var description = ""; var block = false
        for line in lines[1..<end] {
            if line.hasPrefix("name:") { name = scalar(String(line.dropFirst(5))); block = false }
            else if line.hasPrefix("description:") {
                let value = line.dropFirst(12).trimmingCharacters(in: .whitespaces)
                block = ["|", ">", "|-", ">-", "|+", ">+"].contains(value)
                description = block ? "" : scalar(value)
            } else if block {
                if line.first?.isWhitespace == true || line.isEmpty {
                    description += (description.isEmpty ? "" : " ") + line.trimmingCharacters(in: .whitespaces)
                } else { block = false }
            }
        }
        guard let name, !name.isEmpty, name.count <= 160, !description.isEmpty else { return nil }
        return (Display.safe(name, limit: 160), String(description.prefix(12000)))
    }
    private static func scalar(_ text: String) -> String {
        let s = text.trimmingCharacters(in: .whitespaces)
        if s.first == "\"", let data = s.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String { return value }
        if s.hasPrefix("'"), s.hasSuffix("'"), s.count >= 2 { return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        return s.components(separatedBy: " #").first ?? s
    }

    /// 可选离线导入实际 skills/list 响应；不调用子进程，不读取用户凭据。
    public static func decodeSnapshot(_ data: Data) throws -> [Skill] {
        guard data.count < 4 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LedgerError.invalidCatalog }
        let result = object["result"] as? [String: Any] ?? object
        guard let groups = result["data"] as? [[String: Any]] else { throw LedgerError.invalidCatalog }
        var rows: [String: Skill] = [:]
        for group in groups {
            let cwd = group["cwd"] as? String
            for item in group["skills"] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String, let path = item["path"] as? String,
                      path.hasPrefix("/"), path.hasSuffix("/SKILL.md") else { continue }
                let enabled = item["enabled"] as? Bool
                let skill = Skill(name: name, description: item["description"] as? String ?? "",
                    path: path, scope: "目录快照", cwd: cwd,
                    state: enabled.map { $0 ? .enabled : .disabled } ?? .unknown,
                    stateSource: "导入时的 skills/list；不代表历史或此刻状态")
                if let previous = rows[path], previous.state != skill.state {
                    var unknown = skill; unknown.state = .unknown
                    unknown.stateSource = "不同项目状态冲突，请按单个项目导入核对"; rows[path] = unknown
                } else { rows[path] = skill }
            }
        }
        return rows.values.sorted { $0.name < $1.name }
    }
}
