import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CodexAccountsSettingsView: View {
    @ObservedObject var store: CodexAccountsStore
    @State private var draft = CodexAccount()
    @State private var editing = false
    @State private var token = ""
    @State private var error: String?
    @State private var deleting: CodexAccount?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    var body: some View {
        Section("Codex 账号 · 官方额度验证") {
            Toggle("启用多 Codex 账号监测", isOn: $store.monitoringEnabled)
            Picker("刷新间隔", selection: $store.interval) {
                Text("1 分钟").tag(60.0); Text("5 分钟").tag(300.0); Text("15 分钟").tag(900.0); Text("30 分钟").tag(1800.0)
            }
            Text("只监测 Codex，不增加其他提供商。使用已有 Access Token 或显式导入 auth.json，向 ChatGPT 官方额度接口实际验证后才保存。新凭据只存本应用钥匙串，不切换 Codex 当前登录，不保留 Refresh Token。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(store.accounts) { account in
                HStack {
                    Toggle(account.label, isOn: Binding(get: { account.enabled }, set: { store.setEnabled($0, id: account.id) }))
                    if account.verifiedAt != nil { Text("已验证读取权限").font(.caption).foregroundStyle(.secondary) }
                    Button("重新验证") { store.refresh(id: account.id, interactive: true) }
                        .disabled(!store.monitoringEnabled || !account.enabled)
                    Button("编辑") { draft = account; token = ""; error = nil; editing = true }
                    Button("删除", role: .destructive) { deleting = account }
                }
            }
            Button("添加 Codex 账号") { draft = .init(); token = ""; error = nil; editing = true }
            if let error = store.lastError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .sheet(isPresented: $editing, onDismiss: cancelOperation) {
            VStack(alignment: .leading, spacing: 14) {
                Text("验证 Codex 账号").font(.headline)
                TextField("账户标签（例如工作 / 个人）", text: $draft.label).disabled(busy)
                SecureField("OAuth Access Token（编辑时留空保留）", text: $token).disabled(busy)
                Button("选择 auth.json 导入…", action: importAuth).disabled(busy)
                TextField("工作区 Account ID（可选，导入时自动填写）", text: $draft.workspaceID).disabled(busy)
                Text("验证请求只发往 chatgpt.com/backend-api/wham/usage。不读取密码/Cookie，不自动扫描登录文件；401/403 不会冒充成功。换工作区需重新提供凭据。Access Token 到期后，在 Codex 重新登录再导入。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("启用此账户", isOn: $draft.enabled).disabled(busy)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("取消") { cancelOperation(); editing = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("验证并保存") { verify() }.keyboardShortcut(.defaultAction)
                        .disabled(busy || draft.label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding(24).frame(width: 500).interactiveDismissDisabled(busy)
        }
        .alert("删除 Codex 账号及其凭据？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let deleting { do { try store.remove(deleting) } catch { store.lastError = "钥匙串删除失败；账户保留，可重试。" } }
                deleting = nil
            }
        }
    }
    private func verify() {
        error = nil; busy = true
        let account = draft, secret = token
        operation = Task { @MainActor in
            do {
                try await store.verifyAndSave(account, token: secret)
                try Task.checkCancellation()
                token = ""; busy = false; editing = false
            } catch is CancellationError { }
            catch { self.error = (error as? CodexAccountError)?.errorDescription ?? "网络验证失败；未保存凭据。"; busy = false }
        }
    }
    private func cancelOperation() {
        operation?.cancel(); operation = nil
        store.cancelVerification(id: draft.id)
        token = ""; busy = false
    }
    private func importAuth() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        panel.message = "选择已登录 Codex 的 auth.json；只读取所选文件，不改写，也不保留 Refresh Token。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; error = nil
        operation = Task { @MainActor in
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard properties.isRegularFile == true, (properties.fileSize ?? Int.max) <= CodexCredentialImport.maximumBytes else { throw CodexAccountError.tooLarge }
                    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                    let data = try handle.read(upToCount: CodexCredentialImport.maximumBytes + 1) ?? Data()
                    return try CodexCredentialImport.parse(data)
                }.value
                try Task.checkCancellation()
                token = imported.accessToken; draft.workspaceID = imported.workspaceID
                error = "已读取所选文件；尚未验证，请点击“验证并保存”。"
                busy = false
            } catch is CancellationError { }
            catch { self.error = (error as? CodexAccountError)?.errorDescription ?? "无法读取所选凭据文件。"; busy = false }
        }
    }
}

struct CodexAccountsPanel: View {
    @ObservedObject var store: CodexAccountsStore
    @ObservedObject var preferences: HUDPreferences
    @State private var selected = "all"
    let onSettings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Codex 账号").font(.system(size: 12, weight: .bold))
                Picker("账户", selection: $selected) {
                    Text("堆叠显示全部账号").tag("all")
                    ForEach(store.accounts) { Text($0.label).tag($0.id.uuidString) }
                }.labelsHidden().frame(width: 190)
                Spacer()
                Button("刷新") { store.refreshAll(interactive: true) }.disabled(!store.monitoringEnabled)
                Button("管理", action: onSettings)
            }
            if !store.monitoringEnabled { Text("Codex 账号监测未启用；原网关账号不受影响。").font(.caption).foregroundStyle(.secondary) }
            if store.accounts.isEmpty { Text("在设置 → 远程账号中添加并验证 Codex 账号。未配置时不请求任何额度接口。").font(.caption).foregroundStyle(.secondary) }
            ForEach(store.accounts.filter { selected == "all" || $0.id.uuidString == selected }) { account in
                card(account)
            }
            Text("订阅额度与 credits 不是美元余额；不会与本地对话估算费用混合或跨账号合计。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func card(_ account: CodexAccount) -> some View {
        let state = store.states[account.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(account.label).fontWeight(.semibold)
                if let plan = state?.usage?.plan { Text(plan).foregroundStyle(.secondary) }
                if state?.isRefreshing == true { ProgressView().controlSize(.small) }
                if !account.enabled { Text("已关闭").foregroundStyle(.secondary) }
                Spacer()
                Button("验证") { store.refresh(id: account.id, interactive: true) }.disabled(!store.monitoringEnabled || !account.enabled)
                Button(preferences.value.sourceID == account.hudID ? "HUD 正在展示" : "显示到 HUD") { preferences.value.sourceID = account.hudID }
            }
            if let usage = state?.usage {
                if let error = state?.error { Text("旧数据 · \(error)").foregroundStyle(.orange).font(.caption) }
                ForEach(usage.quotas) { quota in
                    HStack {
                        Text(quota.label).frame(width: 110, alignment: .leading)
                        ProgressView(value: quota.remainingPercent, total: 100)
                        Text("剩余 \(Int(quota.remainingPercent.rounded()))%").monospacedDigit().frame(width: 85, alignment: .trailing)
                        if let date = quota.resetsAt { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary).frame(width: 95) }
                    }
                }
                if let credits = usage.credits { Text("Credits：\(credits)").monospacedDigit() }
                Text("读取于 \(usage.capturedAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if let error = state?.error { Text(error).foregroundStyle(.orange).font(.caption) }
            else { Text(account.enabled && store.monitoringEnabled ? "等待读取" : "未读取").foregroundStyle(.secondary) }
        }.font(.system(size: 11)).padding(12)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
