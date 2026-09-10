import AppKit
import SwiftUI
import CodexMonitorCore

@MainActor
final class AppStore: ObservableObject {
    @Published var snapshot = LedgerSnapshot() {
        didSet { dashboard = MonitorDashboard(sessions: snapshot.sessions) }
    }
    @Published private(set) var dashboard = MonitorDashboard(sessions: [])
    @Published var configuration: LedgerConfiguration
    @Published var scanning = false
    @Published var lastError: String?
    @Published var autoRefresh = false
    @Published var demo = false
    @Published var privacyMode = false
    @Published var window: TimeWindow = .week
    @Published var prices = PriceBook()
    @Published var catalogImportedAt: Date?
    private let engine = AnalysisEngine()
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var epoch = 0
    private var importedSkills: [Skill] = []
    private var started = false
    let hud = HUDController()

    init(preview: Bool = false) {
        if preview {
            configuration = LedgerConfiguration(codexHome: "/__codex_monitor_preview__", cacheDirectory: nil)
            started = true
            return
        }
        let file = Paths.support.appendingPathComponent("preferences.json")
        if let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(LedgerConfiguration.self, from: data) {
            configuration = value
        } else {
            configuration = LedgerConfiguration(cacheDirectory: Paths.support.appendingPathComponent("Cache").path)
        }
        if let data = try? Data(contentsOf: Paths.support.appendingPathComponent("prices.json")), let book = try? PriceBook.decode(data) { prices = book }
        // 不自动导入旧的生效状态快照，避免把过期状态显示成当前真值。
    }
    var since: Date? { window.start() }
    var usage: Tokens { LedgerMath.usage(snapshot.sessions, since: since) }
    var tasks: [TaskUsage] { LedgerMath.tasks(snapshot.sessions) }
    var skillRows: [SkillRow] { LedgerMath.skillRows(snapshot.skills, sessions: snapshot.sessions, since: since) }
    var cost: (amount: Double, excludedTokens: Int64) { prices.estimate(LedgerMath.samples(snapshot.sessions, since: since)) }
    var quota: [QuotaWindow] {
        Dictionary(grouping: snapshot.sessions.flatMap(\.quotas), by: \.id).compactMap { _, windows in
            windows.max { ($0.observedAt ?? .distantPast) < ($1.observedAt ?? .distantPast) }
        }.sorted { $0.minutes < $1.minutes }
    }
    func startIfNeeded() {
        guard !started else { return }; started = true; refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if Date().timeIntervalSince(self.dashboard.generatedAt) >= 30 {
                    self.dashboard = MonitorDashboard(sessions: self.snapshot.sessions)
                }
                guard self.autoRefresh, !self.demo, !self.scanning else { return }
                if ProcessInfo.processInfo.isLowPowerModeEnabled { return }
                if [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) { return }
                self.refresh()
            }
        }
        timer?.tolerance = 5
    }
    func refresh() {
        guard !scanning else { return }
        if demo { snapshot = Demo.snapshot(); return }
        scanning = true; lastError = nil; epoch += 1
        let generation = epoch; let config = configuration
        task = Task { [weak self, engine] in
            do {
                var next = try await engine.refresh(config)
                guard let self, generation == self.epoch, !Task.isCancelled else { return }
                if config.skillsEnabled {
                    var skills = Dictionary(uniqueKeysWithValues: next.skills.map { ($0.path, $0) })
                    for skill in self.importedSkills { skills[skill.path] = skill }
                    next.skills = skills.values.sorted { $0.name < $1.name }
                }
                self.snapshot = next
            } catch is CancellationError { }
            catch {
                guard let self, generation == self.epoch else { return }
                self.lastError = error.localizedDescription
            }
            guard let self, generation == self.epoch else { return }
            self.scanning = false; self.task = nil
        }
    }
    func cancel() { epoch += 1; task?.cancel(); task = nil; scanning = false }
    func apply(_ value: LedgerConfiguration) {
        cancel(); configuration = value
        importedSkills = []; catalogImportedAt = nil
        do { try PrivateFile.write(JSONEncoder().encode(value), to: Paths.support.appendingPathComponent("preferences.json")) }
        catch { lastError = "设置未能保存：\(error.localizedDescription)" }
        refresh()
    }
    func toggleDemo() {
        cancel(); demo.toggle()
        snapshot = demo ? Demo.snapshot() : LedgerSnapshot()
        if !demo { refresh() }
    }
    func reindex() {
        cancel(); scanning = true
        task = Task { [weak self, engine] in
            await engine.reset()
            guard let self else { return }
            // 仅删除本应用的扫描缓存，不删除源目录。
            if let directory = self.configuration.cacheDirectory {
                let cache = Paths.url(directory).appendingPathComponent("scan-v1.json")
                if !Paths.contains(cache, in: Paths.url(self.configuration.codexHome)) { try? FileManager.default.removeItem(at: cache) }
            }
            self.scanning = false; self.refresh()
        }
    }
    func chooseCodexHome() {
        guard let path = chooseDirectory(message: "选择包含 sessions 的 Codex 数据目录，例如 ~/.codex") else { return }
        var value = configuration; value.codexHome = path; apply(value)
    }
    func addProject() {
        guard let path = chooseDirectory(message: "选择需要分析项目级 Skills 的工作目录") else { return }
        var value = configuration
        if !value.projects.contains(path) { value.projects.append(path); apply(value) }
    }
    func addSkillRoot() {
        guard let path = chooseDirectory(message: "选择可信的 Skills 目录（允许指向符号链接目标）") else { return }
        var value = configuration
        if !value.skillRoots.contains(path) { value.skillRoots.append(path); apply(value) }
    }
    private func chooseDirectory(message: String) -> String? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.showsHiddenFiles = true; panel.allowsMultipleSelection = false; panel.message = message
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    func importCatalog() {
        let panel = NSOpenPanel(); panel.message = "选择已有 skills/list 的 JSON 响应。本程序不启动 Codex，也不会登录账号。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? Int.max) < 4 * 1024 * 1024 else { throw LedgerError.invalidCatalog }
            importedSkills = try SkillCatalog.decodeSnapshot(Data(contentsOf: url)); catalogImportedAt = Date(); refresh()
        } catch { lastError = error.localizedDescription }
    }
    func importPrices() {
        let panel = NSOpenPanel(); panel.message = "选择你核实过的本地价格 JSON。不会从网络下载价格。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? Int.max) <= 1024 * 1024 else { throw LedgerError.invalidPrices }
            let data = try Data(contentsOf: url); let book = try PriceBook.decode(data)
            try PrivateFile.write(data, to: Paths.support.appendingPathComponent("prices.json")); prices = book
        } catch { lastError = error.localizedDescription }
    }
    func export(json: Bool) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "codex-monitor-report.\(json ? "json" : "md")"
        panel.message = "会隐藏标题、路径、会话 ID；Skill 与模型名称仍会导出。请确认后再分享。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try json ? Reports.json(snapshot) : Data(Reports.markdown(snapshot, since: since).utf8)
            try data.write(to: url, options: .atomic)
        } catch { lastError = error.localizedDescription }
    }
    func title(_ session: Session) -> String {
        privacyMode ? "对话 \(session.id.prefix(8))" : session.title == "未命名对话" ? "对话 \(session.id.prefix(8))" : session.title
    }
    func openSession(_ session: Session) {
        guard !demo, UUID(uuidString: session.id) != nil, let url = URL(string: "codex://threads/\(session.id)") else { return }
        NSWorkspace.shared.open(url)
    }
    func revealSource(_ path: String) {
        guard !demo else { return }
        let url = Paths.url(path)
        guard Paths.contains(url, in: Paths.url(configuration.codexHome)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

enum TimeWindow: String, CaseIterable, Identifiable {
    case today = "今日", week = "近 7 天", month = "近 30 天", all = "累计"
    var id: String { rawValue }
    func start(now: Date = Date()) -> Date? {
        let day = Calendar.current.startOfDay(for: now)
        switch self {
        case .today: return day
        case .week: return Calendar.current.date(byAdding: .day, value: -6, to: day)
        case .month: return Calendar.current.date(byAdding: .day, value: -29, to: day)
        case .all: return nil
        }
    }
}
