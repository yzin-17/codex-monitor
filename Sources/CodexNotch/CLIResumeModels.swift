import Foundation

// 与预测模型/邮件完全无依赖。只接受官方结构化失败和新鲜的同账号额度。
struct CLIResumeIdentity: Codable, Equatable, Sendable {
    var workspaceID: String
    var subject: String
    var label: String
    var key: String { workspaceID + ":" + subject }
}
struct CLIResumeContext: Codable, Equatable, Sendable {
    var threadID: String
    var path: String
    var cwd: String
    var model: String
    var effort: String?
    var sandbox: String
    var approval: String
    var fileSize: UInt64
    var modifiedAt: Date
}
struct CLIResumeInspection: Equatable, Sendable {
    var context: CLIResumeContext
    var identity: CLIResumeIdentity
    var lastTurnID: String
    var quotaPaused: Bool
    var lastTurnStatus: String
    var usage: CodexAccountUsage
    var checkedAt: Date
}
struct CLIResumeTicket: Codable, Equatable, Sendable, Identifiable {
    var id: String { context.threadID }
    var context: CLIResumeContext
    var identity: CLIResumeIdentity
    var turnID: String
    var observedAt: Date
    var blockedWindows: [String]
    var message: String
    var sandbox: String
    var phase: Phase = .waiting
    enum Phase: String, Codable, Sendable { case armed, waiting, dispatching, finished, attention, cancelled }
    var eventKey: String { context.threadID + ":" + turnID }
}
enum CLIResumeError: Error, LocalizedError, Equatable {
    case missingCLI, missingAuth, unknownIdentity, unsupportedSession, invalidMessage, notQuotaPaused
    case changedAccount, changedSession, busy, timedOut, incompatible, outputTooLarge, persistence, unknownOutcome
    var errorDescription: String? {
        switch self {
        case .missingCLI: "未找到本机 Codex CLI。"
        case .missingAuth: "续跑需要本机 Codex 的文件型 ChatGPT 登录。请在原 CODEX_HOME 登录；不会借用远程账号或 API Key。"
        case .unknownIdentity: "无法确认 CLI 的账号和工作区，已停止。"
        case .unsupportedSession: "原会话、模型、工作目录或权限记录不完整；不能安全续跑，请手动处理。"
        case .invalidMessage: "续跑内容须为 1～500 字符的单行文本，不能包含控制字符。"
        case .notQuotaPaused: "原对话当前不是明确的额度耗尽暂停状态，不会自动发送。"
        case .changedAccount: "CLI 账号或工作区发生变化，已暂停等待；请重新确认。"
        case .changedSession: "原对话、模型、权限或工作目录已变化，已停止此轮自动发送。"
        case .busy: "该对话正在执行或另一个 Monitor 正在处理，未重复启动。"
        case .timedOut: "CLI 检查超时；保留等待，不视为额度恢复。"
        case .incompatible: "当前 CLI 的只读会话接口不兼容，已停止；请更新或手动继续。"
        case .outputTooLarge: "CLI 响应超过读取预算，已停止并等待人工检查。"
        case .persistence: "无法保存续跑检查点，已阻止发送。"
        case .unknownOutcome: "上次 CLI 发送结果未确认，不会自动重试；请检查原对话后重新开启。"
        }
    }
}
enum CLIResumePolicy {
    static func message(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CLIResumeError.invalidMessage }
        return text
    }
    static func isQuotaError(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return ["usagelimitexceeded", "usage_limit_exceeded"].contains(value.lowercased())
    }
    static func lastTurn(_ root: [String: Any], threadID: String) throws -> (String, Bool, String) {
        guard let thread = root["thread"] as? [String: Any], thread["id"] as? String == threadID,
              let turns = thread["turns"] as? [[String: Any]], let last = turns.last,
              let id = last["id"] as? String, !id.isEmpty else { throw CLIResumeError.incompatible }
        let status = last["status"] as? String ?? "unknown"
        let active = (thread["status"] as? [String: Any])?["type"] as? String == "active"
        let error = last["error"] as? [String: Any]
        return (id, !active && status == "failed" && isQuotaError(error?["codexErrorInfo"]), active ? "inProgress" : status)
    }
    static func canResume(_ ticket: CLIResumeTicket, with check: CLIResumeInspection, now: Date) throws -> Bool {
        guard ticket.phase == .waiting else { return false }
        guard check.identity.key == ticket.identity.key else { throw CLIResumeError.changedAccount }
        guard check.context.threadID == ticket.id, check.lastTurnID == ticket.turnID, check.quotaPaused,
              check.context.cwd == ticket.context.cwd, check.context.model == ticket.context.model,
              check.context.effort == ticket.context.effort, check.context.sandbox == ticket.context.sandbox,
              check.context.approval == ticket.context.approval else { throw CLIResumeError.changedSession }
        guard check.checkedAt > ticket.observedAt, now.timeIntervalSince(check.checkedAt) >= 0,
              now.timeIntervalSince(check.checkedAt) < 60, !check.usage.quotas.isEmpty else { return false }
        let quotas = check.usage.quotas
        guard quotas.allSatisfy({ $0.remainingPercent > 0 && $0.remainingPercent <= 100 }) else { return false }
        return ticket.blockedWindows.allSatisfy { key in quotas.contains { $0.id == key && $0.remainingPercent > 0 } }
    }
    static func arguments(context: CLIResumeContext, sandbox: String) throws -> [String] {
        guard UUID(uuidString: context.threadID) != nil, context.cwd.hasPrefix("/"),
              ["read-only", "workspace-write"].contains(context.sandbox),
              ["read-only", "workspace-write"].contains(sandbox),
              !(context.sandbox == "read-only" && sandbox != "read-only"),
              ["untrusted", "on-failure", "on-request", "never"].contains(context.approval),
              !context.model.isEmpty, !context.model.hasPrefix("-"), context.model.utf8.count < 150,
              context.model.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-/".contains($0)) }) else { throw CLIResumeError.unsupportedSession }
        // 不更改原审批策略，不启用全权限，不禁用项目规则；额外写目录与网络保持收紧。
        var args = ["exec", "--json", "--color", "never", "-C", context.cwd,
                    "--sandbox", sandbox, "-m", context.model, "-c", "cli_auth_credentials_store=\"file\"",
                    "-c", "model_provider=\"openai\"", "-c", "approval_policy=\"\(context.approval)\"",
                    "-c", "sandbox_workspace_write.network_access=false",
                    "-c", "sandbox_workspace_write.writable_roots=[]"]
        if let effort = context.effort {
            guard ["minimal", "low", "medium", "high", "xhigh", "max"].contains(effort) else { throw CLIResumeError.unsupportedSession }
            args += ["-c", "model_reasoning_effort=\"\(effort)\""]
        }
        args += ["resume", context.threadID, "-"] // 文案从 stdin 输入，不拼接 Shell、不用 --last。
        return args
    }
}
