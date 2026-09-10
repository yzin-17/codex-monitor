import AppKit
import SwiftUI

// Jackie 的 NSVisualEffectView / hudWindow / behindWindow 组合；不对文字设置透明度。
struct MonitorGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .hudWindow
        view.blendingMode = .behindWindow; view.state = .active; view.isEmphasized = false
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
struct HUDGlassBackground: View {
    var opacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if !reduceTransparency { MonitorGlass() }
            Color.black.opacity(reduceTransparency ? 0.96 : opacity)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.10), lineWidth: 0.5))
    }
}
struct HUDEntityData: Equatable {
    var providerID = "codex"
    var provider = "Codex"
    var account = "本机"
    var state = "IDLE"
    var primary: Double?
    var weekly: Double?
    var resetsAt: Date?
    var balance: String?
    var todayTokens: String?
    var costToday: String?
    var cost30d: String?
    var warning: String?
    var primaryLabel = "5h"
    var automatic: Double? { [primary, weekly].compactMap { $0 }.min() }
    func text(_ metric: HUDMetric, remaining: Bool, now: Date = Date()) -> String {
        func percent(_ number: Double?) -> String {
            guard let number, number.isFinite else { return "—" }
            return "\(Int((remaining ? number : 100 - number).rounded()))%"
        }
        switch metric {
        case .icon: return "◉"
        case .provider: return provider
        case .account: return account
        case .state: return state
        case .primary: return "\(primaryLabel) \(percent(primary))"
        case .weekly: return "7d \(percent(weekly))"
        case .automatic: return percent(automatic)
        case .usageBar: return percent(automatic)
        case .tokensToday: return todayTokens.map { "T \($0)" } ?? "T —"
        case .balance: return balance ?? "余额 —"
        case .costToday: return costToday.map { "今日 \($0)" } ?? "今日 —"
        case .cost30d: return cost30d.map { "30天 \($0)" } ?? "30天 —"
        case .resetCountdown:
            guard let resetsAt else { return "重置 —" }
            let seconds = max(0, resetsAt.timeIntervalSince(now))
            if seconds == 0 { return "待刷新" }
            if seconds >= 86400 { return "\(Int(seconds / 86400))d \(Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600))h" }
            return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m"
        case .resetTime:
            guard let resetsAt else { return "重置 —" }
            let formatter = DateFormatter(); formatter.dateFormat = "M/d HH:mm"; return formatter.string(from: resetsAt)
        }
    }
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
            d.warning = s.errorMessage; return d
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
struct HUDMetricStrip: View {
    let layout: HUDLayout
    let data: HUDEntityData
    var remaining = true
    var menuBar = false
    var side: Int? = nil
    private var lines: [[HUDMetric]] {
        let full = layout.metrics
        guard let side else { return full }
        return full.map { line in
            let split = max(1, (line.count + 1) / 2)
            return Array(side == 0 ? line.prefix(split) : line.dropFirst(split))
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: menuBar && lines.count == 2 ? 0 : 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 5) {
                        ForEach(row) { metric in
                            if metric == .icon { Image(systemName: "scope").accessibilityLabel(data.provider) }
                            else if metric == .usageBar {
                                Gauge(value: data.automatic ?? 0, in: 0...100) { EmptyView() }
                                    .gaugeStyle(.linearCapacity).frame(width: 26)
                                    .opacity(data.automatic == nil ? 0.3 : 1)
                            } else {
                                Text(data.text(metric, remaining: remaining, now: context.date)).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .font(.system(size: menuBar && lines.count == 2 ? min(9, NSStatusBar.system.thickness / 2.5) : 11, weight: .medium))
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
            .overlay(alignment: .topTrailing) {
                if data.warning != nil { Image(systemName: "exclamationmark.circle.fill").font(.system(size: 8)).foregroundStyle(.orange).offset(x: 9) }
            }
            .help((data.warning.map { "注意：\($0)\n" } ?? "") + layout.metrics.flatMap { $0 }.map { "\($0.title)：\(data.text($0, remaining: remaining, now: context.date))" }.joined(separator: "\n"))
        }
    }
}
struct ConfigurableHUDView: View {
    @ObservedObject var preferences: HUDPreferences
    @ObservedObject var accounts: CodexAccountsStore
    @ObservedObject var usage: UsageViewModel
    @ObservedObject var remote: RemoteMonitorViewModel
    @ObservedObject var newAPI: BalanceMonitorViewModel
    @ObservedObject var subAPI: BalanceMonitorViewModel
    @ObservedObject var settings: CodexNotchSettings
    var menuBar = false
    var notch: IslandLayout? = nil
    var data: HUDEntityData { .resolve(source: preferences.value.sourceID, usage: usage, remote: remote, newAPI: newAPI, subAPI: subAPI, accounts: accounts, settings: settings) }
    var body: some View {
        let layout = preferences.value.layout(for: data.providerID)
        Group {
            if let notch {
                HStack(spacing: 0) {
                    HUDMetricStrip(layout: layout, data: data, remaining: preferences.value.showRemaining, side: 0)
                        .frame(width: notch.shoulderWidth).clipped()
                    Color.clear.frame(width: notch.notchWidth)
                    HUDMetricStrip(layout: layout, data: data, remaining: preferences.value.showRemaining, side: 1)
                        .frame(width: notch.shoulderWidth).clipped()
                }.frame(width: notch.width, height: notch.collapsedHeight)
            } else {
                HUDMetricStrip(layout: layout, data: data, remaining: preferences.value.showRemaining, menuBar: menuBar)
                    .padding(.horizontal, 8).padding(.vertical, menuBar ? 0 : 4)
                    .frame(maxWidth: preferences.value.normalized.maximumWidth)
                    .clipped()
            }
        }
        .frame(height: menuBar ? min(22, NSStatusBar.system.thickness) : nil)
        .background(HUDGlassBackground(opacity: preferences.value.normalized.hudOpacity))
        .clipShape(RoundedRectangle(cornerRadius: menuBar ? 5 : 14))
        .preferredColorScheme(.dark).foregroundStyle(.white)
    }
}
