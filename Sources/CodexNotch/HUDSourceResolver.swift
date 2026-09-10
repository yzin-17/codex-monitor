import Foundation

extension HUDEntityData {
    @MainActor static func resolve(source: String, usage: UsageViewModel, remote: RemoteMonitorViewModel,
                                   newAPI: BalanceMonitorViewModel, subAPI: BalanceMonitorViewModel,
                                   accounts: CodexAccountsStore, settings: CodexNotchSettings) -> Self {
        if source == "legacy" {
            let selected = settings.notchDisplaySource
            var target = "local"
            if selected == .remoteCodex || (selected == .automatic && remote.snapshot.panelSeverity != .none) {
                target = remote.snapshot.accounts.first.map { "remote:\($0.id)" } ?? "unavailable"
            } else if selected == .newAPI || (selected == .automatic && newAPI.snapshot.panelSeverity != .none) {
                target = newAPI.snapshot.accounts.first.map { "newapi:\($0.id)" } ?? "unavailable"
            } else if selected == .subAPI || (selected == .automatic && subAPI.snapshot.panelSeverity != .none) {
                target = subAPI.snapshot.accounts.first.map { "subapi:\($0.id)" } ?? "unavailable"
            }
            return resolve(source: target, usage: usage, remote: remote, newAPI: newAPI, subAPI: subAPI, accounts: accounts, settings: settings)
        }
        var d = Self()
        if source == "local" {
            let s = usage.snapshot
            d.primary = s.primaryPercent.map(Double.init); d.weekly = s.secondaryPercent.map(Double.init)
            d.state = s.isRunning ? "RUN" : "IDLE"
            d.resetsAt = [s.primaryResetsAt, s.secondaryResetsAt].compactMap { $0 }.min()
            if usage.hasLoadedUsageTotals {
                d.todayTokens = Formatters.compactTokens(s.usageToday)
                func amount(_ u: TokenUsageSummary) -> String? {
                    u.costUSD.map { String(format: "%@%.2f USD", u.isComplete ? "≈" : "≥", $0) }
                }
                d.costToday = amount(s.usageTodaySummary); d.cost30d = amount(s.usage30dSummary)
            }
            d.warning = s.errorMessage; d.capturedAt = s.lastUpdated
            func sample(_ w: UsageQuotaWindow) -> HUDQuotaSample {
                .init(remaining: w.remainingPercent.map(Double.init), resetsAt: w.resetsAt,
                      duration: w.isFiveHourWindow ? 18000 : w.shortLabel == "7d" ? 604800 : nil, label: w.shortLabel)
            }
            d.lanes = s.displayRateLimitWindows.map(sample)
            d.primaryWindow = d.lanes.first(where: { $0.label == "5h" })
            d.weeklyWindow = d.lanes.first(where: { $0.label == "7d" })
            d.scopedWindow = s.sparkQuotaWindows.filter { $0.shortLabel.contains("7d") }.map(sample).min { ($0.remaining ?? 100) < ($1.remaining ?? 100) }
            if let extra = d.scopedWindow { d.lanes.append(extra) }
            d.costTodayUSD = usage.hasLoadedUsageTotals ? s.usageTodaySummary.costUSD : nil
            d.cost30dUSD = usage.hasLoadedUsageTotals ? s.usage30dSummary.costUSD : nil
            return d
        }
        if source.hasPrefix("codex-account:"), let id = UUID(uuidString: String(source.dropFirst(14))),
           let a = accounts.accounts.first(where: { $0.id == id }) {
            d.providerID = "codex"; d.provider = "Codex"; d.account = a.label
            guard accounts.monitoringEnabled && a.enabled else { d.state = "OFF"; d.warning = "账户监测已关闭"; return d }
            let state = accounts.states[id]
            d.state = state?.isRefreshing == true ? "…" : state?.error != nil ? "!" : state?.usage == nil ? "—" : "OK"
            d.warning = state?.error
            if let s = state?.usage {
                d.primary = s.quotas.first(where: { $0.id == "primary_window" })?.remainingPercent
                d.primaryLabel = s.quotas.first(where: { $0.id == "primary_window" })?.label ?? "会话"
                d.weekly = s.quotas.first(where: { $0.label == "7d" })?.remainingPercent
                d.resetsAt = s.quotas.compactMap(\.resetsAt).min()
                d.capturedAt = s.capturedAt
                func sample(_ w: AccountQuota) -> HUDQuotaSample { .init(remaining: w.remainingPercent, resetsAt: w.resetsAt, duration: w.durationSeconds, label: w.label) }
                d.lanes = s.quotas.map(sample)
                d.primaryWindow = s.quotas.first(where: { $0.id == "primary_window" }).map(sample)
                d.weeklyWindow = s.quotas.first(where: { $0.id == "secondary_window" }).map(sample)
                d.scopedWindow = s.quotas.filter { $0.id.hasPrefix("extra-") && $0.id.hasSuffix("secondary_window") && $0.durationSeconds == 604800 }.map(sample).min { ($0.remaining ?? 100) < ($1.remaining ?? 100) }
                d.balance = s.credits // credits 不是美元，不与本地对话估算费用混用。
                if Date().timeIntervalSince(s.capturedAt) > max(accounts.interval * 2, 600) { d.warning = "数据已过期，等待刷新" }
            }
            return d
        }
        if source.hasPrefix("remote:"), settings.remoteMonitorEnabled,
           let a = remote.snapshot.accounts.first(where: { "remote:\($0.id)" == source }) {
            d.providerID = "gateway"; d.provider = a.provider ?? "网关"; d.account = a.displayName
            d.state = a.state.label
            d.primary = a.displayQuotaWindows.first?.remainingPercent.map(Double.init)
            d.weekly = a.displayQuotaWindows.first(where: { $0.shortLabel == "7d" })?.remainingPercent.map(Double.init)
            d.warning = a.quotaError
            return d
        }
        for (prefix, vm, enabled) in [("newapi:", newAPI, settings.newAPIMonitorEnabled), ("subapi:", subAPI, settings.subAPIMonitorEnabled)] {
            if source.hasPrefix(prefix), enabled, let a = vm.snapshot.accounts.first(where: { prefix + $0.id == source }) {
                d.providerID = prefix; d.provider = a.source.title; d.account = a.displayName
                d.state = a.state.label; d.balance = a.amountText
                if a.state == .error { d.warning = "账户数据异常" }
                return d
            }
        }
        d.account = "未找到所选账户"; d.state = "—"; d.warning = "所选账户不可用；不会偷偷切换到其他账户"
        return d
    }
}
