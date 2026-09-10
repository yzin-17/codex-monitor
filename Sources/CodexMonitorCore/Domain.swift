import Foundation

public enum Quality: String, Codable, Sendable { case complete, partial, unavailable }

/// 缓存输入属于 input；reasoning 属于 output，不再累加一次。
public struct Tokens: Codable, Equatable, Sendable {
    public var input: Int64
    public var cached: Int64
    public var output: Int64
    public var reasoning: Int64
    public init(input: Int64 = 0, cached: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0) {
        self.input = max(0, input); self.cached = min(max(0, cached), max(0, input))
        self.output = max(0, output); self.reasoning = min(max(0, reasoning), max(0, output))
    }
    public static let zero = Tokens()
    public var total: Int64 { Self.safeAdd(input, output) }
    public var uncached: Int64 { max(0, input - cached) }
    public var cacheRatio: Double? { input > 0 ? Double(cached) / Double(input) : nil }
    public static func + (a: Tokens, b: Tokens) -> Tokens {
        Tokens(input: safeAdd(a.input, b.input), cached: safeAdd(a.cached, b.cached),
               output: safeAdd(a.output, b.output), reasoning: safeAdd(a.reasoning, b.reasoning))
    }
    static func safeAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (v, overflow) = a.addingReportingOverflow(b); return overflow ? Int64.max : v
    }
    func delta(from old: Tokens) -> Tokens {
        Tokens(input: max(0, input - old.input), cached: max(0, cached - old.cached),
               output: max(0, output - old.output), reasoning: max(0, reasoning - old.reasoning))
    }
    func isAtLeast(_ old: Tokens) -> Bool {
        input >= old.input && cached >= old.cached && output >= old.output && reasoning >= old.reasoning
    }
}

public struct UsageSample: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var date: Date?
    public var turnID: String
    public var model: String
    public var tokens: Tokens
    public var cumulative: Tokens?
    public var lastInput: Int64?
    public var contextLimit: Int64?
    public var isBaseline: Bool
    public var sourceOffset: UInt64
    public init(id: String, date: Date?, turnID: String, model: String, tokens: Tokens,
                cumulative: Tokens? = nil, lastInput: Int64? = nil, contextLimit: Int64? = nil,
                isBaseline: Bool = false, sourceOffset: UInt64 = 0) {
        self.id = id; self.date = date; self.turnID = turnID; self.model = model; self.tokens = tokens
        self.cumulative = cumulative; self.lastInput = lastInput; self.contextLimit = contextLimit
        self.isBaseline = isBaseline; self.sourceOffset = sourceOffset
    }
}

public enum EvidenceKind: String, Codable, Sendable, CaseIterable {
    case requested, readAttempt, fileRead, declared
    public var label: String {
        switch self {
        case .requested: "用户明确指定"
        case .readAttempt: "尝试读取指令"
        case .fileRead: "读取返回成功"
        case .declared: "助手声称使用"
        }
    }
}
public struct SkillEvidence: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sessionID: String
    public var turnID: String
    public var name: String
    public var path: String?
    public var kind: EvidenceKind
    public var date: Date?
    public var sourceOffset: UInt64
    public var sourceFile: String
    public var cwd: String?
    public init(id: String, sessionID: String, turnID: String, name: String, path: String? = nil,
                kind: EvidenceKind, date: Date? = nil, sourceOffset: UInt64 = 0,
                sourceFile: String = "", cwd: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.turnID = turnID; self.name = name; self.path = path
        self.kind = kind; self.date = date; self.sourceOffset = sourceOffset
        self.sourceFile = sourceFile; self.cwd = cwd
    }
}
public struct QuotaWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var minutes: Int
    public var usedPercent: Double
    public var resetsAt: Date?
    public var observedAt: Date?
    public var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

public struct Session: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var cwd: String?
    public var parentID: String?
    public var forkedFromID: String?
    public var isSubagent: Bool
    public var files: [String]
    public var samples: [UsageSample]
    public var evidence: [SkillEvidence]
    public var quotas: [QuotaWindow]
    public var issues: [String]
    public var compactions: Int
    public var status: String
    public var lastActivity: Date?
    public init(id: String, title: String = "未命名对话", cwd: String? = nil, parentID: String? = nil,
                forkedFromID: String? = nil, isSubagent: Bool = false, files: [String] = [],
                samples: [UsageSample] = [], evidence: [SkillEvidence] = [], quotas: [QuotaWindow] = [],
                issues: [String] = [], compactions: Int = 0, status: String = "未知", lastActivity: Date? = nil) {
        self.id = id; self.title = title; self.cwd = cwd; self.parentID = parentID
        self.forkedFromID = forkedFromID; self.isSubagent = isSubagent; self.files = files
        self.samples = samples; self.evidence = evidence; self.quotas = quotas; self.issues = issues
        self.compactions = compactions; self.status = status; self.lastActivity = lastActivity
    }
    public var ownTokens: Tokens { samples.reduce(.zero) { $0 + $1.tokens } }
    public var models: [String] { Array(Set(samples.map(\.model))).sorted() }
    public var quality: Quality { samples.isEmpty ? .unavailable : issues.isEmpty ? .complete : .partial }
}
public struct TaskUsage: Identifiable, Sendable {
    public var root: Session
    public var descendants: [Session]
    public var id: String { root.id }
    public var childrenTokens: Tokens { descendants.reduce(.zero) { $0 + $1.ownTokens } }
    public var total: Tokens { root.ownTokens + childrenTokens }
}
public struct ModelUsage: Identifiable, Sendable {
    public var model: String
    public var tokens: Tokens
    public var id: String { model }
}

public enum SkillState: String, Codable, Sendable { case enabled, disabled, unknown }
public struct Skill: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public var name: String
    public var description: String
    public var path: String
    public var scope: String
    public var cwd: String?
    public var state: SkillState
    public var stateSource: String
    public var catalogCharacters: Int { name.count + description.count + path.count }
    public var catalogTokenEstimate: Int { max(1, (catalogCharacters + 3) / 4) }
    public init(name: String, description: String, path: String, scope: String,
                cwd: String? = nil, state: SkillState = .unknown, stateSource: String = "本地发现，不代表当前生效") {
        self.name = name; self.description = description; self.path = path; self.scope = scope
        self.cwd = cwd; self.state = state; self.stateSource = stateSource
    }
}
public struct SkillRow: Identifiable, Sendable {
    public var skill: Skill
    public var evidence: [SkillEvidence]
    public var id: String { skill.id }
    public func count(_ kind: EvidenceKind) -> Int { evidence.filter { $0.kind == kind }.count }
    public var sessions: Int { Set(evidence.map(\.sessionID)).count }
    public var lastSeen: Date? { evidence.compactMap(\.date).max() }
}

public struct ScanProgress: Codable, Sendable {
    public var files: Int = 0
    public var caughtUp: Int = 0
    public var bytesRead: Int = 0
    public var pendingFiles: Int = 0
    public var issues: [String] = []
    public init() {}
}
public struct LedgerSnapshot: Sendable {
    public var sessions: [Session]
    public var skills: [Skill]
    public var progress: ScanProgress
    public var createdAt: Date
    public var isDemo: Bool
    public init(sessions: [Session] = [], skills: [Skill] = [], progress: ScanProgress = .init(),
                createdAt: Date = Date(), isDemo: Bool = false) {
        self.sessions = sessions; self.skills = skills; self.progress = progress
        self.createdAt = createdAt; self.isDemo = isDemo
    }
    public var total: Tokens { sessions.reduce(.zero) { $0 + $1.ownTokens } }
}

/// 只读取用户指定的本机目录，缓存必须放在另一个目录。
public struct LedgerConfiguration: Codable, Equatable, Sendable {
    public var codexHome: String
    public var projects: [String]
    public var skillRoots: [String]
    public var skillsEnabled: Bool
    public var cacheDirectory: String?
    public var byteBudget: Int
    public var timeBudget: Double
    public init(codexHome: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path,
                projects: [String] = [], skillRoots: [String] = [], skillsEnabled: Bool = true,
                cacheDirectory: String? = nil, byteBudget: Int = 32 * 1024 * 1024, timeBudget: Double = 2) {
        self.codexHome = codexHome; self.projects = projects; self.skillRoots = skillRoots
        self.skillsEnabled = skillsEnabled; self.cacheDirectory = cacheDirectory
        self.byteBudget = max(4096, byteBudget); self.timeBudget = max(0.05, timeBudget)
    }
}
