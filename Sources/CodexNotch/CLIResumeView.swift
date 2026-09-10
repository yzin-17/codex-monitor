import SwiftUI

struct CLIResumeControl: View {
    let threadID: String
    @ObservedObject var store: CLIResumeStore
    @State private var message = "继续"
    @State private var writes = false
    @State private var consent = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("额度恢复续跑 · Codex CLI").font(.system(size: 11, weight: .semibold)).foregroundStyle(MonitorTheme.textPrimary)
                Spacer()
                if let ticket = store.tickets[threadID], [.armed, .waiting, .dispatching].contains(ticket.phase) {
                    Button("关闭 / 取消") { store.cancel(threadID) }.buttonStyle(.plain).foregroundStyle(MonitorTheme.warning)
                    if ticket.phase == .waiting || ticket.phase == .armed { Button("立即检查") { store.checkNow(threadID) }.buttonStyle(.plain).disabled(store.checking.contains(threadID)) }
                } else {
                    Button(store.checking.contains(threadID) ? "检查中…" : "检查并配置") { consent = false; store.prepare(threadID) }
                        .buttonStyle(.plain).foregroundStyle(MonitorTheme.textPrimary).disabled(store.checking.contains(threadID))
                }
            }.font(.system(size: 10))
            Text("默认关闭。仅恢复明确因额度不足停止的原会话；预测、状态页或邮件不会触发发送。")
                .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)
            if let prepared = store.prepared[threadID] {
                Text("执行账号：\(prepared.identity.label) · 工作区 \(prepared.identity.workspaceID)")
                    .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)
                Text("目录：\(prepared.context.cwd)\n模型：\(prepared.context.model) · 原审批：\(prepared.context.approval)")
                    .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary).textSelection(.enabled)
                TextField("续跑内容（不要填写秘密）", text: $message).textFieldStyle(.roundedBorder).font(.system(size: 11))
                if prepared.context.sandbox == "workspace-write" {
                    Toggle("允许 CLI 修改原工作区（不超出原沙盒）", isOn: $writes).toggleStyle(.checkbox).font(.system(size: 10))
                }
                Toggle("确认此账号用于该任务，CLI 执行时不同时在 Desktop 继续此对话", isOn: $consent)
                    .toggleStyle(.checkbox).font(.system(size: 10))
                Text("CLI 会正常消耗额度，可能执行项目命令；默认只读。工作区写入需上方明确授权。Monitor 不自动切换账号、不修改配置、不放宽原审批、不打开额外网络权限。")
                    .font(.system(size: 10)).foregroundStyle(MonitorTheme.textTertiary)
                Button("开启此对话的额度恢复续跑") {
                    do { try store.arm(threadID, message: message, allowWorkspaceWrite: writes); error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(!consent).controlSize(.small)
            }
            if let note = error ?? store.notes[threadID] { Text(note).font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(10).background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: 8))
    }
}
