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
            d.warning = s.errorMessage; d.capturedAt = s.rateLimitCapturedAt
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
            let now = Date()
            let currentDisplay = accounts.currentLocalAccountDisplayData(now: now)
            d.planType = currentDisplay?.remotePlan
            d.balance = currentDisplay?.remoteCredits
            switch accounts.quotaSourcePreference {
            case .localFirst, .localOnly:
                if accounts.localQuotaAvailability == .available {
                    let actualSource: CodexAccountQuotaSource = s.rateLimitOrigin == .appServer
                        ? .localAppServer
                        : .localRecords
                    d.provider = "Codex · \(actualSource.hudLabel)"
                    d.state = actualSource.hudLabel
                    d.warning = s.quotaWarning(now: now)
                } else if accounts.quotaSourcePreference == .localFirst,
                          let currentDisplay,
                          currentDisplay.quotaSource == .remoteFallback,
                          let quotaUsage = currentDisplay.quotaUsage {
                    clearQuota(in: &d)
                    applyRemoteQuota(quotaUsage, to: &d)
                    d.provider = "Codex · \(CodexAccountQuotaSource.remoteFallback.hudLabel)"
                    d.state = CodexAccountQuotaSource.remoteFallback.hudLabel
                    d.warning = currentDisplay.remoteError
                } else if accounts.localQuotaAvailability != .unknown,
                          s.canDisplayQuotaHistory(accountID: accounts.currentLocalAccountID, now: now) {
                    d.state = "旧数据"
                    d.provider = "Codex · 历史快照"
                    d.quotaIsHistorical = true
                    d.warning = s.quotaWarning(now: now) ?? "额度数据已过期"
                } else {
                    clearQuota(in: &d)
                    d.state = accounts.localQuotaAvailability == .unknown ? "…" : "—"
                    d.warning = s.rateLimitDiagnostic?.failure?.message ?? (accounts.localQuotaAvailability == .unknown
                        ? "等待首次本机额度读取"
                        : s.quotaWarning(now: now) ?? "本机额度不可用")
                    d.state = s.rateLimitDiagnostic?.failure == .authentication ? "需登录" : "不可用"
                    d.quotaUnavailableReason = accounts.localQuotaAvailability == .unknown ? "待读取" : d.warning
                }
            case .remoteOnly:
                clearQuota(in: &d)
                if let currentDisplay,
                   currentDisplay.quotaSource == .remote,
                   let quotaUsage = currentDisplay.quotaUsage {
                    applyRemoteQuota(quotaUsage, to: &d)
                    d.provider = "Codex · \(CodexAccountQuotaSource.remote.hudLabel)"
                    d.state = CodexAccountQuotaSource.remote.hudLabel
                    d.warning = currentDisplay.remoteError
                } else {
                    d.state = accounts.monitoringEnabled ? "—" : "OFF"
                    d.warning = accounts.monitoringEnabled
                        ? (currentDisplay?.localAvailability == .unknown ? "等待账号身份稳定" : "当前账号未绑定或远程额度不可用")
                        : "账户监测已关闭"
                }
            }
            return d
        }
        if source.hasPrefix("codex-account:"), let id = UUID(uuidString: String(source.dropFirst(14))),
           let a = accounts.accounts.first(where: { $0.id == id }) {
            d.providerID = "codex"; d.provider = "Codex"; d.account = a.label
            guard a.enabled else { d.state = "OFF"; d.warning = "账户已关闭"; return d }

            let now = Date()
            let display = accounts.displayData(for: a, now: now)
            d.planType = display.remotePlan
            d.balance = display.remoteCredits // Credits 只来自官方远程数据，本机额度不冒充余额。

            if let quotaUsage = display.quotaUsage {
                applyRemoteQuota(quotaUsage, to: &d)
                if let quotaSource = display.quotaSource {
                    d.provider = "Codex · \(quotaSource.hudLabel)"
                    d.state = quotaSource.hudLabel
                }
                if display.usesLocalQuota {
                    d.warning = display.localWarning
                    if display.localAvailability != .available {
                        d.state = "旧数据"; d.provider = "Codex · 历史快照"; d.quotaIsHistorical = true
                    }
                } else {
                    if let error = display.remoteError { d.warning = error }
                    else if CodexAccountQuotaFallbackPolicy.remoteIsStale(
                        quotaUsage,
                        interval: accounts.interval,
                        now: now
                    ) { d.warning = "数据已过期，等待刷新" }
                    else if !CodexAccountQuotaFallbackPolicy.remoteHasWeekly(quotaUsage) {
                        d.warning = "每周额度暂不可用"
                    }
                }
                return d
            }

            if display.isCurrentLocalAccount, display.localAvailability == .unknown {
                d.state = "…"
                d.warning = accounts.quotaSourcePreference == .remoteOnly ? "等待账号身份稳定" : "等待本机额度"
                return d
            }

            guard accounts.monitoringEnabled else {
                d.state = "OFF"
                d.warning = "账户监测已关闭"
                return d
            }

            d.state = display.isRefreshing ? "…" : display.remoteError != nil ? "!" : "—"
            d.warning = display.remoteError ?? "每周额度暂不可用"
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
        // primary_window 在部分套餐里本身就是 7d；不能仅凭字段名把它误当成 5h。
        let primary = usage.quotas.first(where: {
            $0.id == "primary_window" && CodexAccountQuotaFallbackPolicy.isFiveHourQuota($0)
        })
        let weekly = usage.quotas.first(where: {
            $0.id == "secondary_window" || CodexAccountQuotaFallbackPolicy.isWeeklyQuota($0)
        })
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

    private static func clearQuota(in data: inout Self) {
        data.primary = nil
        data.primaryLabel = "会话"
        data.weekly = nil
        data.resetsAt = nil
        data.capturedAt = nil
        data.lanes = []
        data.primaryWindow = nil
        data.weeklyWindow = nil
        data.scopedWindow = nil
    }

}
