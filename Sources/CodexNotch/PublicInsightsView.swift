import SwiftUI

struct PublicInsightCard: View {
    let source: PublicInsightSource
    @ObservedObject var store: PublicInsightsStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(source.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(MonitorTheme.textPrimary)
                Spacer()
                Toggle("启用", isOn: Binding(get: { store.enabled.contains(source) }, set: { store.setEnabled(source, $0) }))
                    .toggleStyle(.switch).controlSize(.mini).fixedSize()
            }
            if !store.enabled.contains(source) {
                Text("启用后每 5 分钟读取此公开网站，不发送账号凭据或本地会话数据。")
                    .font(.system(size: 11)).foregroundStyle(MonitorTheme.textSecondary)
            } else if let snapshot = store.snapshots[source] {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(alignment: .leading, spacing: 6) {
                        content(snapshot, now: context.date)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(store.refreshing.contains(source) ? "正在读取公开数据…" : "尚无数据")
                    .font(.system(size: 11)).foregroundStyle(MonitorTheme.textSecondary)
            }
            if let error = store.errors[source] { Text(error).font(.system(size: 10)).foregroundStyle(MonitorTheme.warning) }
            if source == .willReset {
                Text("邮件提醒：可前往网站自行订阅。订阅与退订由网站管理，本工具不读取邮箱或接收邮件通知。")
                    .font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)
                Link("前往网站订阅 ↗", destination: source.website).font(.system(size: 11)).tint(MonitorTheme.textPrimary)
            }
            HStack {
                Link("查看来源 ↗", destination: source.website).tint(MonitorTheme.textSecondary)
                Spacer()
                Button(store.refreshing.contains(source) ? "刷新中…" : "刷新") { store.refresh(source) }
                    .buttonStyle(.plain).foregroundStyle(MonitorTheme.textSecondary)
                    .disabled(!store.enabled.contains(source) || store.refreshing.contains(source))
            }.font(.system(size: 10))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(MonitorTheme.sectionFill))
    }
    @ViewBuilder private func content(_ snapshot: PublicInsightSnapshot, now: Date) -> some View {
        if snapshot.isStale(now: now) || store.errors[source] != nil {
            Text("数据过期或来源部分不可用 · 以下为上次结果")
                .font(.system(size: 10)).foregroundStyle(MonitorTheme.warning)
        }
        if snapshot.isForecast {
            HStack(spacing: 20) {
                ForEach(snapshot.probabilities.keys.sorted(), id: \.self) { hours in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("未来 \(hours) 小时").font(.system(size: 10)).foregroundStyle(MonitorTheme.textSecondary)
                        Text(String(format: "%.0f%%", snapshot.probabilities[hours] ?? 0))
                            .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(MonitorTheme.textPrimary)
                    }
                }
            }
            Text(snapshot.summary).font(.system(size: 11)).foregroundStyle(MonitorTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let announcement = snapshot.announcement { Text(announcement).font(.system(size: 11)).foregroundStyle(MonitorTheme.warning) }
            if let reset = snapshot.lastResetAt { Text("该站记录上次事件：\(reset.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(MonitorTheme.textTertiary) }
        } else {
            HStack(spacing: 6) {
                Circle().fill(snapshot.overallIndicator == "none" ? MonitorTheme.healthy : MonitorTheme.warning).frame(width: 6, height: 6)
                Text("OpenAI 总体：\(snapshot.summary)").font(.system(size: 11)).foregroundStyle(MonitorTheme.textPrimary)
            }
            ForEach(snapshot.components) { component in
                HStack {
                    Text(component.name).foregroundStyle(MonitorTheme.textSecondary)
                    Spacer()
                    Text(component.label).foregroundStyle(component.affected ? MonitorTheme.warning : MonitorTheme.healthy)
                }.font(.system(size: 11))
            }
            if snapshot.components.isEmpty { Text("本次响应没有可识别的 Codex 组件，不推断其状态。").font(.system(size: 10)).foregroundStyle(MonitorTheme.warning) }
            ForEach(Array(snapshot.incidents.enumerated()), id: \.offset) { _, text in
                Text("官方事件：\(text)").font(.system(size: 10)).foregroundStyle(MonitorTheme.warning)
            }
            Text("官方聚合状态不代表你的网络、账号或单次请求一定正常。")
                .font(.system(size: 10)).foregroundStyle(MonitorTheme.textTertiary)
        }
        Text("最近获取：\(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.system(size: 10)).foregroundStyle(MonitorTheme.textTertiary)
        if let updated = snapshot.updatedAt {
            Text("\(snapshot.isForecast ? "来源生成" : "官方状态变更")：\(updated.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 10)).foregroundStyle(MonitorTheme.textTertiary)
        }
    }
}
struct ResetPredictionPanel: View {
    @ObservedObject var store: PublicInsightsStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("社区额外重置预测 · 仅供参考，不是个人 5h / 7d 重置时间。两个来源独立展示，不合并概率，也不触发自动续跑。")
                    .font(.system(size: 11)).foregroundStyle(MonitorTheme.textSecondary)
                PublicInsightCard(source: .observatory, store: store)
                PublicInsightCard(source: .willReset, store: store)
            }.padding(.vertical, 4)
        }.onAppear { store.refreshIfNeeded() }
    }
}
