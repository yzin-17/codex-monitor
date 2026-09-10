import SwiftUI
import CodexMonitorCore

struct OverviewView: View {
    @ObservedObject var store: AppStore
    @State private var usageShown = false
    var body: some View {
        VStack(spacing: 12) {
            quotaCard
            SessionsView(store: store)
            Button { usageShown = true } label: {
                HStack(spacing: 0) {
                    period("今日", store.dashboard.today.total)
                    Rectangle().fill(MonitorTheme.stroke).frame(width: 1, height: 36)
                    period("7 天", store.dashboard.week.total)
                    Rectangle().fill(MonitorTheme.stroke).frame(width: 1, height: 36)
                    period("30 天", store.dashboard.month.total)
                }.padding(.vertical, 11).monitorSurface()
            }.buttonStyle(.plain).help("查看用量构成、分模型统计与本地价格估算")
        }
        .sheet(isPresented: $usageShown) {
            DetailShell(title: "用量与参考费用") { UsageBreakdownView(store: store) }
        }
    }
    private var quotaCard: some View {
        HStack(spacing: 20) {
            QuotaMeter(title: "5h Quota", quota: MonitorQuota.generalWindow(store.quota, minutes: 300))
            QuotaMeter(title: "7d Quota", quota: MonitorQuota.generalWindow(store.quota, minutes: 10080))
            VStack(alignment: .trailing, spacing: 12) {
                HStack {
                    Text("Running").foregroundStyle(MonitorTheme.text)
                    Spacer()
                    Text("\(store.dashboard.runningTasks)").monospacedDigit()
                }
                Text("\(store.dashboard.rows.count) sessions").font(.system(size: 11)).foregroundStyle(MonitorTheme.secondary)
            }.font(.system(size: 13, weight: .semibold)).frame(width: 118)
                .help("日志仍显示运行中的任务数；超过 10 分钟未更新会标记 STALE，并非进程探测。")
        }.padding(16).monitorSurface()
    }
    private func period(_ title: String, _ value: Int64) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(MonitorTheme.secondary)
            Text(Display.tokens(value)).font(.system(size: 19, weight: .bold)).monospacedDigit()
        }.frame(maxWidth: .infinity)
    }
}

struct QuotaMeter: View {
    let title: String
    let quota: QuotaWindow?
    private var expired: Bool { quota.map { MonitorQuota.expired($0) } ?? false }
    private var valid: Bool { quota?.observedAt != nil && !expired }
    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Text(MonitorQuota.percentage(quota)).font(.system(size: 19, weight: .bold))
                    .monospacedDigit().foregroundStyle(valid ? MonitorTheme.accent : MonitorTheme.muted)
            }
            GeometryReader { geometry in
                Capsule().fill(Color.white.opacity(0.10))
                    .overlay(alignment: .leading) {
                        Capsule().fill(MonitorTheme.accent)
                            .frame(width: valid ? geometry.size.width * CGFloat((quota?.remainingPercent ?? 0) / 100) : 0)
                    }
            }.frame(height: 5)
            HStack {
                Spacer(minLength: 0)
                Text(caption).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    .foregroundStyle(expired ? MonitorTheme.amber : MonitorTheme.muted)
            }
        }.frame(maxWidth: .infinity)
            .help(quota?.observedAt.map { "本地快照记录于 \($0.formatted())；不代表实时账户余额。" } ?? "没有对应通用额度的本地日志。")
    }
    private var caption: String {
        guard let quota, quota.observedAt != nil else { return "暂无本地记录" }
        if expired { return "已到期 · 待新快照" }
        if let date = quota.resetsAt { return "日志重置 " + date.formatted(date: .abbreviated, time: .shortened) }
        return "日志快照 · 重置时间未知"
    }
}

struct UsageBreakdownView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("统计范围", selection: $store.window) {
                    ForEach(TimeWindow.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Surface {
                    HStack {
                        component("未缓存输入", store.usage.uncached)
                        component("缓存输入", store.usage.cached)
                        component("输出（含推理）", store.usage.output)
                    }
                }
                Surface {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("分模型用量").font(.headline)
                        let models = LedgerMath.models(store.snapshot.sessions, since: store.since)
                        ForEach(models) { model in
                            VStack(spacing: 7) {
                                HStack { Text(model.model).lineLimit(1); Spacer(); Text(Display.tokens(model.tokens.total)).monospacedDigit() }
                                GeometryReader { proxy in
                                    Capsule().fill(MonitorTheme.stroke).overlay(alignment: .leading) {
                                        Capsule().fill(MonitorTheme.accent.opacity(0.8)).frame(width: proxy.size.width * CGFloat(Double(model.tokens.total) / Double(max(1, models.first?.tokens.total ?? 1))))
                                    }
                                }.frame(height: 4)
                            }.font(.system(size: 12))
                        }
                        if models.isEmpty { Text("这个范围内暂无可归属的用量。").foregroundStyle(MonitorTheme.secondary) }
                    }
                }
                Surface {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("API 参考估算").font(.headline); Spacer()
                            Text(store.prices.models.isEmpty ? "未配置价格" : String(format: "%@ %.4f", store.prices.currency, store.cost.amount)).monospacedDigit()
                        }
                        Text("不是订阅账单。未知费率、无法归属的历史基线及超出适用范围的请求不猜价；本期未计价 \(Display.tokens(store.cost.excludedTokens)) Token。")
                            .font(.caption).foregroundStyle(MonitorTheme.secondary)
                        Button("导入本地价格…") { store.importPrices() }
                    }
                }
                if !store.snapshot.progress.issues.isEmpty {
                    Notice(text: store.snapshot.progress.issues.joined(separator: "\n"), warning: true)
                }
            }.padding(20)
        }
    }
    private func component(_ title: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(MonitorTheme.secondary)
            Text(Display.tokens(value)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
