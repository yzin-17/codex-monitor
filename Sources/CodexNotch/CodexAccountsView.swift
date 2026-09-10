import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CodexAccountsSettingsView: View {
    @ObservedObject var store: CodexAccountsStore
    @Binding var addRequest: UUID?
    init(store: CodexAccountsStore, addRequest: Binding<UUID?> = .constant(nil)) {
        self.store = store; self._addRequest = addRequest
    }
    @State private var loginProgress = ""
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
            Text("点击添加后使用系统浏览器登录 Codex，授权完成后自动验证额度并保存。使用独立临时登录目录，不切换桌面端当前账号；长期凭据仅存本应用钥匙串。高级导入仍保留。")
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
            Button("添加 Codex 账号 · 网页授权", action: beginAdding)
            if let error = store.lastError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: addRequest, initial: true) { _, request in
            if request != nil { beginAdding(); addRequest = nil }
        }
        .onDisappear(perform: cancelOperation)
        .sheet(isPresented: $editing, onDismiss: cancelOperation) {
            VStack(alignment: .leading, spacing: 14) {
                Text("验证 Codex 账号").font(.headline)
                TextField("账户标签（例如工作 / 个人）", text: $draft.label).disabled(busy)
                Button(action: browserLogin) {
                    Label("打开浏览器登录 Codex", systemImage: "safari")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).disabled(busy)
                if busy && !loginProgress.isEmpty { Text(loginProgress).font(.caption).foregroundStyle(.secondary) }
                Text("浏览器中完成 ChatGPT 授权后将自动返回验证。不会读取浏览器 Cookie，也不会修改 ~/.codex 的登录状态。临时目录内的 CLI 登录材料结束后删除，只保留已验证的 Access Token；到期后可再次网页登录。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("高级：导入已有凭据") {
                    VStack(alignment: .leading, spacing: 10) {
                        SecureField("OAuth Access Token（编辑时留空保留）", text: $token)
                        Button("选择 auth.json 导入…", action: importAuth)
                        TextField("工作区 Account ID（可选，导入时自动填写）", text: $draft.workspaceID)
                        Text("高级导入完成后点击右下角验证并保存。只读请求发送至 ChatGPT 官方额度接口，验证失败不保存新凭据。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }.disabled(busy)
                Toggle("启用此账户", isOn: $draft.enabled).disabled(busy)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("取消") { cancelOperation(); editing = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("验证并保存") { verify() }.keyboardShortcut(.defaultAction)
                        .disabled(busy || draft.label.trimmingCharacters(in: .whitespaces).isEmpty || (token.isEmpty && draft.verifiedAt == nil))
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
    private func beginAdding() {
        cancelOperation()
        draft = .init(label: "Codex 账号 \(store.accounts.count + 1)")
        token = ""; error = nil; loginProgress = ""; editing = true
    }
    private func browserLogin() {
        busy = true; error = nil; loginProgress = "正在准备独立登录环境…"
        let account = draft
        operation = Task { @MainActor in
            do {
                let credential = try await CodexBrowserLoginClient().login { url in
                    loginProgress = "已打开浏览器，等待完成授权（最长 5 分钟）…"
                    return NSWorkspace.shared.open(url)
                }
                try Task.checkCancellation()
                loginProgress = "网页授权完成，正在验证 Codex 额度…"
                var next = account
                next.workspaceID = credential.workspaceID
                if next.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { next.label = "Codex 账号" }
                try await store.verifyAndSave(next, token: credential.accessToken)
                try Task.checkCancellation()
                busy = false; editing = false; token = ""; loginProgress = ""
            } catch is CancellationError { }
            catch {
                self.error = (error as? CodexBrowserLoginError)?.errorDescription
                    ?? (error as? CodexAccountError)?.errorDescription ?? "网页登录失败，未保存账号；可重试或使用高级导入。"
                busy = false; loginProgress = ""
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
        token = ""; busy = false; loginProgress = ""
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
                .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)
        }.foregroundStyle(MonitorTheme.textPrimary).environment(\.colorScheme, .dark)
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
