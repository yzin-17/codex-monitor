import Foundation

// 任务语义移植自 yzin-17/codex-task-lens；文档始终只读。
struct TaskProgressHeading: Codable, Hashable, Sendable {
    let depth: Int
    let title: String
    let ordinal: Int
    let total: Int
}

enum TaskProgressScope: Codable, Hashable, Sendable {
    case document
    case section([TaskProgressHeading])

    var label: String {
        switch self {
        case .document: "整篇文档"
        case .section(let path):
            path.map { $0.title + ($0.total > 1 ? " (\($0.ordinal)/\($0.total))" : "") }.joined(separator: " / ")
        }
    }
}

struct TaskProgressSection: Equatable, Sendable, Identifiable {
    let scope: TaskProgressScope
    let line: Int
    let endLine: Int
    var id: TaskProgressScope { scope }
}

struct TaskProgressItem: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let checked: Bool
    let line: Int
    let groups: [String]
    var status: String? = nil
    var conflict = false
    var rawText = ""
    var endLine: Int? = nil
    var explicitID: String? = nil
}

struct TaskProgressTasks: Equatable, Sendable {
    let items: [TaskProgressItem]
    let sections: [TaskProgressSection]
    let diagnostics: [String]
    var completed: Int { items.filter(\.checked).count }
    var total: Int { items.count }
}

enum TaskProgressBindingOrigin: String, Codable, Sendable {
    case manual, automatic
}

struct TaskProgressBinding: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let path: String
    let scope: TaskProgressScope
    var origin: TaskProgressBindingOrigin = .manual
    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    init(id: UUID, path: String, scope: TaskProgressScope, origin: TaskProgressBindingOrigin = .manual) {
        self.id = id; self.path = path; self.scope = scope; self.origin = origin
    }

    private enum CodingKeys: String, CodingKey { case id, path, scope, origin }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        path = try values.decode(String.self, forKey: .path)
        scope = try values.decode(TaskProgressScope.self, forKey: .scope)
        origin = try values.decodeIfPresent(TaskProgressBindingOrigin.self, forKey: .origin) ?? .manual
    }
}

struct TaskProgressThreadSettings: Codable, Equatable, Sendable {
    var autoBind = true
    var scanWorkspace = true
}

struct TaskProgressCandidate: Equatable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    let origins: [TaskProgressDiscoveryOrigin]
    let suggestedScope: TaskProgressScope
    let tasks: TaskProgressTasks?
    let status: TaskProgressSourceStatus
    let message: String?
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var canBind: Bool { status == .ready && (tasks?.total ?? 0) > 0 }
    var reason: String {
        origins.map { origin in
            switch origin {
            case .written: "任务创建或更新"
            case .mentioned: "任务消息引用"
            case .read: "任务读取过"
            case .workspace: "项目任务目录"
            }
        }.joined(separator: " · ")
    }
}

struct TaskProgressScanState: Equatable, Sendable {
    var isScanning = false
    var candidates: [TaskProgressCandidate] = []
    var workspacePath: String? = nil
    var message: String? = nil
    var lastScannedAt: Date? = nil
    var hasMore = false
}

enum TaskProgressSourceStatus: String, Sendable {
    case loading, ready, missing, permissionDenied, unsupported, scopeMissing, unstable, error
}

struct TaskProgressDocumentState: Equatable, Sendable {
    let bindingID: UUID
    var tasks: TaskProgressTasks?
    var status: TaskProgressSourceStatus
    var lastReadAt: Date? = nil
    var message: String? = nil
    var cached: Bool { tasks != nil && status != .ready }
}

struct TaskProgressSummary: Equatable, Sendable {
    let completed: Int
    let total: Int
    let documentCount: Int
    let knownDocumentCount: Int
    let stale: Bool
    var partial: Bool { knownDocumentCount < documentCount }
    var fraction: Double? { total > 0 && !partial ? Double(completed) / Double(total) : nil }
    var label: String {
        if documentCount == 0 { return "进度 —" }
        if knownDocumentCount == 0 { return "进度 —" }
        if total == 0 { return "无任务" + (partial ? " · 部分" : stale ? " · 缓存" : "") }
        return "\(completed)/\(total)" + (partial ? " · 部分" : stale ? " · 缓存" : "")
    }

    static func summarize(bindings: [TaskProgressBinding], snapshots: [UUID: TaskProgressDocumentState]) -> Self {
        let known = bindings.compactMap { snapshots[$0.id] }.filter { $0.tasks != nil }
        return Self(completed: known.reduce(0) { $0 + ($1.tasks?.completed ?? 0) },
                    total: known.reduce(0) { $0 + ($1.tasks?.total ?? 0) },
                    documentCount: bindings.count, knownDocumentCount: known.count,
                    stale: known.contains { $0.status != .ready })
    }
}

enum TaskProgressError: Error, LocalizedError, Equatable {
    case invalid(String)
    case scopeMissing
    case unstable
    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .scopeMissing: "章节已变化，请重新选择范围。"
        case .unstable: "文档持续写入中，暂时保留上次进度。"
        }
    }
}
