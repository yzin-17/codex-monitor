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
            guard a.enabled else { d.state = "OFF"; d.warning = "账户已关闭"; return d }

            let state = accounts.states[id]
            let remoteUsage = state?.usage
            if let remoteUsage {
                d.planType = remoteUsage.plan
                d.balance = remoteUsage.credits // credits 只来自官方远程数据，本地额度不冒充余额。
            }

            let now = Date()
            let remoteIsStale = remoteUsage.map {
                now.timeIntervalSince($0.capturedAt) > max(accounts.interval * 2, 600)
            } ?? true
            let remoteHasWeekly = remoteUsage?.quotas.contains(where: {
                ($0.id == "secondary_window" || $0.label == "7d") && (0...100).contains($0.remainingPercent)
            }) == true
            let remoteQuotaHealthy = accounts.monitoringEnabled
                && state?.error == nil
                && remoteUsage != nil
                && !remoteIsStale
                && remoteHasWeekly

            if remoteQuotaHealthy, let remoteUsage {
                applyRemoteQuota(remoteUsage, to: &d)
                d.state = state?.isRefreshing == true ? "…" : "OK"
                return d
            }

            let local = resolve(source: "local", usage: usage, remote: remote, newAPI: newAPI, subAPI: subAPI, accounts: accounts, settings: settings)
            let localHasWeekly = local.weeklyWindow?.remaining != nil || local.weekly != nil
            if localHasWeekly, accounts.canUseLocalFallback(for: a, localCapturedAt: local.capturedAt) {
                applyLocalQuota(local, to: &d)
                d.state = "LOCAL"
                d.warning = nil
                return d
            }

            if let remoteUsage {
                applyRemoteQuota(remoteUsage, to: &d)
                d.state = state?.isRefreshing == true ? "…" : state?.error != nil ? "!" : "OK"
                if let error = state?.error { d.warning = error }
                else if remoteIsStale { d.warning = "数据已过期，等待刷新" }
                else if !remoteHasWeekly { d.warning = "每周额度暂不可用" }
                else if !accounts.monitoringEnabled { d.warning = "账户监测已关闭" }
                return d
            }

            d.state = accounts.monitoringEnabled ? (state?.isRefreshing == true ? "…" : state?.error != nil ? "!" : "—") : "OFF"
            d.warning = state?.error ?? (accounts.monitoringEnabled ? "每周额度暂不可用" : "账户监测已关闭")
            // 5h 没有有效数据时由 HUDEntityData 自动隐藏；7d 不隐藏，因此会明确显示 “7d —”。
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

    private static func applyRemoteQuota(_ usage: CodexAccountUsage, to data: inout Self) {
        func sample(_ w: AccountQuota) -> HUDQuotaSample {
            .init(remaining: w.remainingPercent, resetsAt: w.resetsAt, duration: w.durationSeconds, label: w.label)
        }
        let primary = usage.quotas.first(where: { $0.id == "primary_window" })
        let weekly = usage.quotas.first(where: { $0.id == "secondary_window" || $0.label == "7d" })
        data.primary = primary?.remainingPercent
        data.primaryLabel = primary?.label ?? "会话"
        data.weekly = weekly?.remainingPercent
        data.resetsAt = usage.quotas.compactMap(\.resetsAt).min()
        data.capturedAt = usage.capturedAt
        data.lanes = usage.quotas.map(sample)
        data.primaryWindow = primary.map(sample)
        data.weeklyWindow = weekly.map(sample)
        data.scopedWindow = usage.quotas
            .filter { $0.id.hasPrefix("extra-") && $0.id.hasSuffix("secondary_window") && $0.durationSeconds == 604800 }
            .map(sample)
            .min { ($0.remaining ?? 100) < ($1.remaining ?? 100) }
    }

    private static func applyLocalQuota(_ local: Self, to data: inout Self) {
        data.primary = local.primary
        data.primaryLabel = local.primaryLabel
        data.weekly = local.weekly
        data.resetsAt = local.resetsAt
        data.capturedAt = local.capturedAt
        data.lanes = local.lanes
        data.primaryWindow = local.primaryWindow
        data.weeklyWindow = local.weeklyWindow
        data.scopedWindow = local.scopedWindow
    }
}
