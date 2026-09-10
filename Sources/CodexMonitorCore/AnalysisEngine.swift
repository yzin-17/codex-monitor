import Foundation

public actor AnalysisEngine {
    private let scanner = IncrementalScanner()
    public init() {}
    public func reset() { scanner.reset() }
    public func refresh(_ configuration: LedgerConfiguration) throws -> LedgerSnapshot {
        let (files, initialProgress) = try scanner.scan(configuration, cancelled: { Task.isCancelled })
        var progress = initialProgress
        let index = SessionIndex.load(home: Paths.url(configuration.codexHome))
        progress.issues.append(contentsOf: index.issues)
        var sessions = files
        for i in sessions.indices {
            let id = sessions[i].id
            if let entry = index.entries[id] {
                if let title = entry.title, !title.isEmpty { sessions[i].title = Display.safe(title) }
                sessions[i].cwd = entry.cwd ?? sessions[i].cwd
                sessions[i].parentID = entry.parent ?? sessions[i].parentID
                sessions[i].forkedFromID = entry.fork ?? sessions[i].forkedFromID
            }
            sessions[i].parentID = index.parents[id] ?? sessions[i].parentID
            sessions[i].isSubagent = sessions[i].isSubagent || sessions[i].parentID != nil
        }
        sessions = LedgerMath.merge(sessions)
        let ids = Set(sessions.map(\.id))
        for i in sessions.indices {
            if let parent = sessions[i].parentID, !ids.contains(parent) {
                sessions[i].issues.append("父对话日志不可见，暂列为独立的未归组子代理")
            }
        }
        let catalog = configuration.skillsEnabled ? SkillCatalog.discover(config: configuration) : (skills: [Skill](), issues: [String]())
        progress.issues.append(contentsOf: catalog.issues)
        return LedgerSnapshot(sessions: sessions, skills: catalog.skills, progress: progress)
    }
}

public enum Demo {
    public static func snapshot(now: Date = Date()) -> LedgerSnapshot {
        let skill = Skill(name: "code-review", description: "检查代码变更、风险和测试证据。", path: "/demo/.agents/skills/code-review/SKILL.md", scope: "演示", state: .enabled, stateSource: "演示数据")
        let root = Session(id: "11111111-1111-4111-8111-111111111111", title: "策略回测 · 风险规则联动", cwd: "/demo/thesis-ledger",
            samples: [UsageSample(id: "demo-root", date: now.addingTimeInterval(-300), turnID: "demo-turn-1", model: "demo-planner",
                tokens: Tokens(input: 1_280_000, cached: 920_000, output: 62_000), lastInput: 188_000, contextLimit: 272_000)],
            evidence: [SkillEvidence(id: "demo-read", sessionID: "11111111-1111-4111-8111-111111111111", turnID: "demo-turn-1", name: skill.name,
                path: skill.path, kind: .fileRead, date: now.addingTimeInterval(-300))],
            quotas: [QuotaWindow(id: "codex:primary", minutes: 300, usedPercent: 28, resetsAt: now.addingTimeInterval(8000), observedAt: now)],
            status: "已完成", lastActivity: now.addingTimeInterval(-300))
        let child = Session(id: "22222222-2222-4222-8222-222222222222", title: "实现与验证", cwd: root.cwd, parentID: root.id, isSubagent: true,
            samples: [UsageSample(id: "demo-child", date: now.addingTimeInterval(-180), turnID: "demo-turn-2", model: "demo-worker",
                tokens: Tokens(input: 3_460_000, cached: 3_020_000, output: 188_000), lastInput: 140_000, contextLimit: 872_000)],
            status: "已完成", lastActivity: now.addingTimeInterval(-180))
        let another = Session(id: "33333333-3333-4333-8333-333333333333", title: "桌面持仓页 · 交互调整", cwd: "/demo/desktop",
            samples: [UsageSample(id: "demo-other", date: now.addingTimeInterval(-3600), turnID: "demo-turn-3", model: "demo-planner",
                tokens: Tokens(input: 620_000, cached: 410_000, output: 48_000))], status: "已完成", lastActivity: now.addingTimeInterval(-3600))
        var progress = ScanProgress(); progress.files = 3; progress.caughtUp = 3
        return LedgerSnapshot(sessions: [root, child, another], skills: [skill], progress: progress, createdAt: now, isDemo: true)
    }
}
