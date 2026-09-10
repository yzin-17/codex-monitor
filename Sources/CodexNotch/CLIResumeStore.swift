import Combine
import Foundation
import Darwin

// 应用私有的进程锁，不修改 Codex 日志；只防止多个 Monitor 重复发送，不冒充 Desktop 的原子锁。
private final class CLIResumeFileLock {
    private var descriptor: Int32 = -1
    init(directory: URL, threadID: String) throws {
        guard UUID(uuidString: threadID) != nil else { throw CLIResumeError.unsupportedSession }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.appendingPathComponent(threadID + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CLIResumeError.persistence }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 { close(descriptor); descriptor = -1; throw CLIResumeError.busy }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}
@MainActor
final class CLIResumeStore: ObservableObject {
    typealias Inspector = @MainActor (URL, String, String?) async throws -> CLIResumeInspection
    typealias Runner = @MainActor (URL, CLIResumeTicket, @escaping @MainActor () -> Void) async throws -> Void
    @Published private(set) var tickets: [String: CLIResumeTicket] = [:]
    @Published private(set) var prepared: [String: CLIResumeInspection] = [:]
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var checking: Set<String> = []
    let home: URL
    private let defaults: UserDefaults
    private let inspector: Inspector
    private let runner: Runner
    private let activeThreads: () -> Set<String>
    private let lockDirectory: URL
    private let automatic: Bool
    private var handled: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var timer: Timer?
    private var lastScheduledID: String?
    init(home: URL, defaults: UserDefaults = .standard, automatic: Bool = true,
         lockDirectory: URL? = nil, activeThreads: @escaping () -> Set<String> = { [] },
         inspector: Inspector? = nil, runner: Runner? = nil) {
        self.home = home; self.defaults = defaults; self.automatic = automatic; self.activeThreads = activeThreads
        self.lockDirectory = lockDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexMonitor/CLIResumeLocks")
        self.inspector = inspector ?? { home, id, path in try await CLIResumeTransport().inspect(home: home, threadID: id, cachedPath: path) }
        self.runner = runner ?? { home, ticket, started in try await CLIResumeTransport().run(home: home, ticket: ticket, onStarted: started) }
        if automatic, let data = defaults.data(forKey: "cliResume.tickets.v1"), data.count <= 512 * 1024,
           let stored = try? JSONDecoder().decode([CLIResumeTicket].self, from: data) {
            for var ticket in stored.prefix(20) where UUID(uuidString: ticket.id) != nil {
                // 应用被终止时不猜测 CLI 是否已执行，更不能重发。
                if ticket.phase == .dispatching { ticket.phase = .attention; notes[ticket.id] = CLIResumeError.unknownOutcome.localizedDescription }
                tickets[ticket.id] = ticket
            }
            handled = Array((defaults.stringArray(forKey: "cliResume.handled.v1") ?? []).suffix(256))
            schedule()
        }
    }
    func prepare(_ id: String) {
        guard tasks[id] == nil else { notes[id] = CLIResumeError.busy.localizedDescription; return }
        checking.insert(id); notes[id] = "检查本机 CLI 身份、官方额度和原对话…"
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[id] = nil; self.checking.remove(id) }
            do {
                let value = try await self.inspector(self.home, id, self.tickets[id]?.context.path)
                try Task.checkCancellation()
                guard !value.quotaPaused || !self.handled.contains(id + ":" + value.lastTurnID) else { throw CLIResumeError.unknownOutcome }
                self.prepared[id] = value; self.notes[id] = nil
            } catch is CancellationError { self.notes[id] = "已取消检查" }
              catch { self.notes[id] = self.safeError(error) }
        }
    }
    func arm(_ id: String, message: String, allowWorkspaceWrite: Bool) throws {
        guard let check = prepared[id], Date().timeIntervalSince(check.checkedAt) < 120,
              tickets.count < 20 || tickets[id] != nil,
              (!check.quotaPaused || !handled.contains(id + ":" + check.lastTurnID)) else { throw CLIResumeError.changedSession }
        let sandbox = allowWorkspaceWrite ? "workspace-write" : "read-only"
        _ = try CLIResumePolicy.arguments(context: check.context, sandbox: sandbox)
        let ticket = CLIResumeTicket(context: check.context, identity: check.identity, turnID: check.lastTurnID,
            observedAt: Date(), blockedWindows: check.usage.quotas.filter { $0.remainingPercent == 0 }.map(\.id),
            message: try CLIResumePolicy.message(message), sandbox: sandbox, phase: check.quotaPaused ? .waiting : .armed)
        var next = tickets; next[id] = ticket
        try persist(next, handled: handled)
        tickets = next; prepared[id] = nil; notes[id] = check.quotaPaused ? "已开启：等待同一账号的官方额度恢复。" : "已开启：仅在此对话因官方额度不足停止后开始等待恢复。"
        schedule()
    }
    func cancel(_ id: String) {
        tasks[id]?.cancel(); prepared[id] = nil
        if var ticket = tickets[id] {
            ticket.phase = .cancelled; tickets[id] = ticket
            try? persist(tickets, handled: handled)
        }
        notes[id] = "已关闭续跑。已执行的操作不会回滚；仅停止 Monitor 自己启动的 CLI。"
    }
    func checkNow(_ id: String) {
        guard tasks.isEmpty, let original = tickets[id], [.waiting, .armed].contains(original.phase) else { return }
        if activeThreads().contains(id) {
            if original.phase == .waiting { cancel(id); notes[id] = "检测到对话正在执行，已取消等待，未重复发送。" }
            return
        }
        // 默认只同时处理一个续跑，避免多个 CLI 重用会话/工作目录时相互干扰。
        guard !tickets.values.contains(where: { $0.phase == .dispatching }) else { return }
        checking.insert(id)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[id] = nil; self.checking.remove(id) }
            var dispatched = false
            do {
                let check = try await self.inspector(self.home, id, original.context.path)
                try Task.checkCancellation()
                guard self.tickets[id]?.phase == original.phase else { throw CancellationError() }
                guard check.identity.key == original.identity.key else { throw CLIResumeError.changedAccount }
                if original.phase == .armed {
                    guard check.context.cwd == original.context.cwd, check.context.model == original.context.model,
                          check.context.effort == original.context.effort, check.context.sandbox == original.context.sandbox,
                          check.context.approval == original.context.approval else { throw CLIResumeError.changedSession }
                    if check.lastTurnStatus == "interrupted" { self.cancel(id); return }
                    guard check.quotaPaused, !self.activeThreads().contains(id) else { self.notes[id] = "监测已开启，尚未出现明确的额度耗尽暂停。"; return }
                    guard !self.handled.contains(id + ":" + check.lastTurnID) else { throw CLIResumeError.unknownOutcome }
                    var waiting = original; waiting.turnID = check.lastTurnID; waiting.context = check.context
                    waiting.observedAt = check.checkedAt; waiting.phase = .waiting
                    waiting.blockedWindows = check.usage.quotas.filter { $0.remainingPercent == 0 }.map(\.id)
                    var next = self.tickets; next[id] = waiting; try self.persist(next, handled: self.handled)
                    self.tickets = next; self.notes[id] = "已记录额度耗尽，等待下一份新鲜官方额度确认恢复。"; return
                }
                guard !self.activeThreads().contains(id) else { throw CLIResumeError.busy }
                guard try CLIResumePolicy.canResume(original, with: check, now: Date()) else {
                    self.notes[id] = "官方额度仍未恢复；继续等待（每分钟检查）。"; return
                }
                let lock = try CLIResumeFileLock(directory: self.lockDirectory, threadID: id)
                defer { withExtendedLifetime(lock) {} }
                guard !self.handled.contains(original.eventKey),
                      !(self.defaults.stringArray(forKey: "cliResume.handled.v1") ?? []).contains(original.eventKey) else { throw CLIResumeError.unknownOutcome }
                // 检查和发送之间再次读取，避免等待期间的人工继续/账号切换。
                let final = try await self.inspector(self.home, id, check.context.path)
                try Task.checkCancellation()
                guard !self.activeThreads().contains(id), try CLIResumePolicy.canResume(original, with: final, now: Date()) else { throw CLIResumeError.changedSession }
                var ticket = original; ticket.context = final.context; ticket.phase = .dispatching
                var next = self.tickets; next[id] = ticket
                let nextHandled = Array((self.handled + [ticket.eventKey]).suffix(256))
                try self.createDispatchReceipt(ticket)
                try self.persist(next, handled: nextHandled) // 写入先于外部执行，崩溃后不重发。
                self.tickets = next; self.handled = nextHandled; dispatched = true
                self.notes[id] = "正在启动 CLI 继续原会话；请不要同时在 Desktop 操作此对话。"
                try await self.runner(self.home, ticket) { [weak self] in self?.notes[id] = "CLI 已开始执行原会话。" }
                guard !Task.isCancelled else { throw CancellationError() }
                ticket.phase = .finished; self.tickets[id] = ticket
                try self.persist(self.tickets, handled: self.handled)
                self.notes[id] = "CLI 回合已完成；本次额度事件不会重复续跑。"
            } catch is CancellationError { self.notes[id] = "已停止监测或取消本次 CLI，未执行自动重试。" }
              catch {
                if dispatched || (error as? CLIResumeError).map({ [.changedAccount, .changedSession, .unknownOutcome, .notQuotaPaused, .unsupportedSession].contains($0) }) == true {
                    if var ticket = self.tickets[id] { ticket.phase = .attention; self.tickets[id] = ticket; try? self.persist(self.tickets, handled: self.handled) }
                }
                self.notes[id] = self.safeError(error)
            }
        }
    }
    func shutdown() async {
        let active = Array(tasks.values)
        stop()
        for task in active { await task.value }
    }
    private func createDispatchReceipt(_ ticket: CLIResumeTicket) throws {
        guard !ticket.turnID.isEmpty, ticket.turnID.count < 200,
              ticket.turnID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }) else { throw CLIResumeError.incompatible }
        let path = lockDirectory.appendingPathComponent(ticket.id + "_" + ticket.turnID + ".sent").path
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw errno == EEXIST ? CLIResumeError.unknownOutcome : CLIResumeError.persistence }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CLIResumeError.persistence }
    }
    func stop() { timer?.invalidate(); timer = nil; for task in tasks.values { task.cancel() }; tasks.removeAll() }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard automatic, tickets.values.contains(where: { [.waiting, .armed].contains($0.phase) }) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // 批次串行，防止一个计时器同时启动多个恢复进程。
                guard self.tasks.isEmpty else { return }
                let ids = self.tickets.keys.sorted().filter { self.tickets[$0].map { [.waiting, .armed].contains($0.phase) } == true }
                guard let next = ids.first(where: { $0 > (self.lastScheduledID ?? "") }) ?? ids.first else { return }
                self.lastScheduledID = next
                self.checkNow(next)
            }
        }
    }
    private func persist(_ tickets: [String: CLIResumeTicket], handled: [String]) throws {
        guard let data = try? JSONEncoder().encode(Array(tickets.values)), data.count <= 512 * 1024 else { throw CLIResumeError.persistence }
        defaults.set(data, forKey: "cliResume.tickets.v1"); defaults.set(handled, forKey: "cliResume.handled.v1")
        guard defaults.synchronize() else { throw CLIResumeError.persistence }
    }
    private func safeError(_ error: Error) -> String {
        (error as? CLIResumeError)?.localizedDescription ?? (error as? CodexAccountError)?.localizedDescription ?? "本次检查失败，未发送续跑请求。请检查 CLI、账号登录和网络。"
    }
}
