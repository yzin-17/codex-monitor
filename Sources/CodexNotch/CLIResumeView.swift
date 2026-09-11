import SwiftUI

struct CLIResumeControl: View {
    let threadID: String
    @ObservedObject var store: CLIResumeStore
    var knownAccounts: [CodexAccount] = []
    @State private var message = "继续"
    @State private var writes = false
    @State private var consent = false
    @State private var error: String?
    @State private var detailsExpanded = false
    @State private var editingMessage = false

    private var ticket: CLIResumeTicket? { store.tickets[threadID] }
    private var prepared: CLIResumeInspection? { store.prepared[threadID] }
    private var activeTicket: Bool {
        ticket.map { [.armed, .waiting, .dispatching, .attention].contains($0.phase) } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("额度恢复续跑 · Codex CLI")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textPrimary)
                if let ticket {
                    Text(phaseLabel(ticket.phase))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ticket.phase == .attention ? MonitorTheme.warning : MonitorTheme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.white.opacity(0.06), in: Capsule())
                }
                Spacer()
                if prepared != nil || activeTicket {
                    Button(detailsExpanded ? "收起配置" : "展开配置") { detailsExpanded.toggle() }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
                if activeTicket {
                    if ticket?.phase == .waiting || ticket?.phase == .armed {
                        Button("立即检查") { store.checkNow(threadID) }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .disabled(store.checking.contains(threadID))
                    }
                    Button("关闭续跑") { store.cancel(threadID) }
                        .buttonStyle(.bordered).controlSize(.mini).tint(MonitorTheme.warning)
                } else {
                    Button(store.checking.contains(threadID) ? "检查中…" : "检查并配置") {
                        consent = false; error = nil; detailsExpanded = true; store.prepare(threadID)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.mini)
                    .disabled(store.checking.contains(threadID))
                }
            }

            Text("默认关闭。仅恢复明确因额度不足停止的原会话；预测、状态页或邮件不会触发发送。")
                .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)

            if detailsExpanded {
                if let prepared { preparedDetails(prepared) }
                else if let ticket { ticketDetails(ticket) }
            }

            if let note = error ?? store.notes[threadID] {
                Text(note).font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: 8))
        .onAppear { syncFromTicket() }
        .onChange(of: ticket?.message) { _, _ in syncFromTicket() }
        .onChange(of: prepared != nil) { _, exists in if exists { detailsExpanded = true } }
    }

    @ViewBuilder private func preparedDetails(_ prepared: CLIResumeInspection) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            identityRows(prepared.identity)
            Text("目录：\(prepared.context.cwd)\n模型：\(prepared.context.model) · 原审批：\(prepared.context.approval)")
                .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary).textSelection(.enabled)
            TextField("续跑内容（不要填写秘密）", text: $message)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            if prepared.context.sandbox == "workspace-write" {
                Toggle("允许 CLI 修改原工作区（不超出原沙盒）", isOn: $writes)
                    .toggleStyle(.checkbox).font(.system(size: 10))
            }
            Toggle("确认 CLI 执行账号就是此任务的账号，执行时不同时在 Desktop 继续此对话", isOn: $consent)
                .toggleStyle(.checkbox).font(.system(size: 10))
            Text("HUD 展示账号、远程额度账号与 CLI 执行账号彼此独立。续跑只使用本机 CODEX_HOME 的 CLI 身份，不会借用 Monitor 中添加的远程账号。")
                .font(.system(size: 10)).foregroundStyle(MonitorTheme.textTertiary)
            HStack {
                Button("开启此对话的额度恢复续跑") {
                    do { try store.arm(threadID, message: message, allowWorkspaceWrite: writes); error = nil; detailsExpanded = false }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).controlSize(.small).disabled(!consent)
                Button("收起") { detailsExpanded = false }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    @ViewBuilder private func ticketDetails(_ ticket: CLIResumeTicket) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            identityRows(ticket.identity)
            Text("目录：\(ticket.context.cwd)\n模型：\(ticket.context.model) · 沙盒：\(ticket.sandbox) · 原审批：\(ticket.context.approval)")
                .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary).textSelection(.enabled)
            if editingMessage {
                TextField("续跑内容（不要填写秘密）", text: $message)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                HStack {
                    Button("保存提示词") {
                        do { try store.updateMessage(threadID, message: message); editingMessage = false; error = nil }
                        catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button("取消") { message = ticket.message; editingMessage = false }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("续跑提示词").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(MonitorTheme.textTertiary)
                        Text(ticket.message).font(.system(size: 10.5)).foregroundStyle(MonitorTheme.textPrimary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("编辑提示词") { message = ticket.message; editingMessage = true }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .disabled(ticket.phase == .dispatching || ticket.phase == .finished)
                }
            }
            Text("修改提示词不会切换账号、模型、权限或工作区；正在分发的 CLI 不允许改写提示词。")
                .font(.system(size: 9.5)).foregroundStyle(MonitorTheme.textTertiary)
        }
    }

    @ViewBuilder private func identityRows(_ identity: CLIResumeIdentity) -> some View {
        Text("CLI 执行账号：\(identity.label) · 工作区 \(identity.workspaceID)")
            .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)
        let matches = knownAccounts.filter { !$0.workspaceID.isEmpty && $0.workspaceID == identity.workspaceID }
        if matches.count == 1 {
            Text("Monitor 中对应账号：\(matches[0].label)（仅用于对照，不提供 CLI 凭据）")
                .font(.system(size: 9.5)).foregroundStyle(MonitorTheme.textTertiary)
        } else if matches.count > 1 {
            Text("Monitor 中有多个账号使用同一工作区 ID；续跑仍以 CLI 身份为准。")
                .font(.system(size: 9.5)).foregroundStyle(MonitorTheme.warning)
        } else if !knownAccounts.isEmpty {
            Text("Monitor 远程账号中没有匹配工作区；这不会自动切换 CLI 身份。")
                .font(.system(size: 9.5)).foregroundStyle(MonitorTheme.textTertiary)
        }
    }

    private func syncFromTicket() {
        if let ticket { message = ticket.message; writes = ticket.sandbox == "workspace-write" }
    }
    private func phaseLabel(_ phase: CLIResumeTicket.Phase) -> String {
        switch phase {
        case .armed: "监测中"; case .waiting: "等待额度"; case .dispatching: "续跑中"
        case .finished: "已完成"; case .attention: "需确认"; case .cancelled: "已关闭"
        }
    }
}
