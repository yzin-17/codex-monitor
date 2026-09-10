import Foundation
import CSQLite

struct SessionIndex {
    struct Entry {
        var title: String?
        var cwd: String?
        var parent: String?
        var fork: String?
    }
    var entries: [String: Entry] = [:]
    var parents: [String: String] = [:]
    var issues: [String] = []

    static func load(home: URL) -> SessionIndex {
        var index = SessionIndex()
        let fm = FileManager.default
        let candidates = (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        let databases = candidates.compactMap { url -> (Int, URL)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", name.hasPrefix("state_"),
                  let version = Int(name.dropFirst(6)), Paths.contains(url, in: home) else { return nil }
            return (version, url)
        }
        if let url = databases.max(by: { $0.0 < $1.0 })?.1 {
            var connection: OpaquePointer?
            if sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
               let db = connection {
                sqlite3_busy_timeout(db, 200)
                _ = sqlite3_exec(db, "PRAGMA query_only=ON; BEGIN;", nil, nil, nil)
                defer { _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil); sqlite3_close(db) }
                let columns = columnNames(db, "threads")
                if columns.contains("id") {
                    func field(_ names: [String]) -> String { names.first(where: columns.contains) ?? "NULL" }
                    let sql = "SELECT id, substr(\(field(["title", "name"])), 1, 512), \(field(["cwd"])), \(field(["parent_thread_id"])), \(field(["forked_from_id"])) FROM threads LIMIT 30001;"
                    let rows = query(db, sql)
                    if rows.count > 30000 { index.issues.append("会话索引超过 30,000 条，仅使用有界结果") }
                    for row in rows.prefix(30000) {
                        guard let id = row[0] else { continue }
                        index.entries[id] = Entry(title: row[1], cwd: row[2], parent: row[3], fork: row[4])
                    }
                } else { index.issues.append("state 数据库结构不匹配，改用 JSONL 元数据") }
                let edgeColumns = columnNames(db, "thread_spawn_edges")
                if edgeColumns.contains("parent_thread_id") && edgeColumns.contains("child_thread_id") {
                    let rows = query(db, "SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges LIMIT 30001;")
                    if rows.count > 30000 { index.issues.append("子代理关系超过 30,000 条，仅使用有界结果") }
                    for row in rows.prefix(30000) {
                        if let parent = row[0], let child = row[1], parent != child {
                            if let old = index.parents[child], old != parent {
                                index.issues.append("同一子代理存在多个父节点，关系需要核对")
                            } else { index.parents[child] = parent }
                        }
                    }
                }
            } else {
                if let connection { sqlite3_close(connection) }
                index.issues.append("无法只读打开 state 数据库，使用日志内已知关系")
            }
        }
        let namesURL = home.appendingPathComponent("session_index.jsonl")
        if Paths.contains(namesURL, in: home),
           let size = try? namesURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 8 * 1024 * 1024,
           let data = try? Data(contentsOf: namesURL) {
            for line in data.split(separator: 10) {
                guard let p = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let id = p["id"] as? String, let name = p["thread_name"] as? String else { continue }
                var entry = index.entries[id] ?? Entry()
                if entry.title == nil { entry.title = name; index.entries[id] = entry }
            }
        }
        return index
    }
    private static func columnNames(_ db: OpaquePointer, _ table: String) -> Set<String> {
        Set(query(db, "PRAGMA table_info(\(table));").compactMap { $0.count > 1 ? $0[1] : nil })
    }
    private static func query(_ db: OpaquePointer, _ sql: String) -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { column in
                guard sqlite3_column_type(statement, column) != SQLITE_NULL,
                      let text = sqlite3_column_text(statement, column) else { return nil }
                return String(cString: text)
            })
        }
        return result
    }
}
