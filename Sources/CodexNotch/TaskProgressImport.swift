import Foundation

struct TaskProgressImportCandidate: Identifiable, Sendable {
    let sourceID: String
    let threadID: String
    let bindings: [TaskProgressBinding]
    var id: String { sourceID + "|" + threadID }
}

/// 只读取明确选择的 Task Lens 存储；导入后 Monitor 独立维护，绝不写回原文件。
enum TaskProgressImport {
    static func candidates(data: Data, threadID: String) throws -> [TaskProgressImportCandidate] {
        guard data.count <= 4 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = root["schemaVersion"] as? Int, [1, 2].contains(schema),
              let monitors = root["monitors"] as? [[String: Any]], monitors.count <= 10_000 else {
            throw TaskProgressError.invalid("Task Lens 绑定文件格式无效或版本不支持。")
        }
        var result: [TaskProgressImportCandidate] = []
        var seen = Set<String>()
        for row in monitors {
            guard let monitor = row["monitor"] as? [String: Any], monitor["kind"] as? String == "thread",
                  monitor["threadId"] as? String == threadID,
                  let source = monitor["sourceId"] as? String, !source.isEmpty, source.count <= 128 else { continue }
            guard seen.insert(source).inserted else { throw TaskProgressError.invalid("导入文件包含重复的会话来源。") }
            let raw: [[String: Any]]
            if schema == 1 { raw = (row["binding"] as? [String: Any]).map { [$0] } ?? [] }
            else { guard let values = row["bindings"] as? [[String: Any]] else { throw TaskProgressError.invalid("绑定文档列表无效。") }; raw = values }
            guard raw.count <= TaskProgressParser.maximumDocuments else { throw TaskProgressError.invalid("每个会话最多绑定 16 个文档。") }
            let bindings = try raw.map { value -> TaskProgressBinding in
                guard let identity = value["monitor"] as? [String: Any], identity["kind"] as? String == "thread",
                      identity["threadId"] as? String == threadID, identity["sourceId"] as? String == source,
                      let path = value["documentRealPath"] as? String, path.hasPrefix("/"), !path.contains("\0"), path.count <= 4_096,
                      let scope = value["scope"] as? [String: Any] else {
                    throw TaskProgressError.invalid("绑定身份或文件路径不一致，已拒绝导入。")
                }
                return TaskProgressBinding(id: UUID(), path: path, scope: try decodeScope(scope))
            }
            guard Set(bindings.map(\.path)).count == bindings.count else { throw TaskProgressError.invalid("同一个文件不能重复导入。") }
            if !bindings.isEmpty { result.append(.init(sourceID: source, threadID: threadID, bindings: bindings)) }
        }
        return result
    }

    private static func decodeScope(_ value: [String: Any]) throws -> TaskProgressScope {
        if value["kind"] as? String == "document" { return .document }
        guard value["kind"] as? String == "section", let parts = value["path"] as? [[String: Any]],
              !parts.isEmpty, parts.count <= 6 else { throw TaskProgressError.invalid("章节范围无效。") }
        var previousDepth = 0
        let path = try parts.map { item -> TaskProgressHeading in
            guard let depth = item["depth"] as? Int, (1...6).contains(depth), depth > previousDepth,
                  let title = item["title"] as? String, !title.isEmpty, title.count <= 512,
                  let ordinal = item["ordinal"] as? Int, let total = item["total"] as? Int,
                  ordinal > 0, total >= ordinal, total <= 10_000 else { throw TaskProgressError.invalid("章节定位信息无效。") }
            previousDepth = depth
            return TaskProgressHeading(depth: depth, title: title, ordinal: ordinal, total: total)
        }
        return .section(path)
    }
}
