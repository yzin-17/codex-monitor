import SwiftUI

struct PublicInsightCard: View {
    let source: PublicInsightSource
    @ObservedObject var store: PublicInsightsStore
    @State private var expandedStatusGroups: Set<String> = []

    var body: some View {
        Group {
            if source == .openAIStatus {
                openAIStatusMenu
            } else {
                forecastCard
            }
        }
    }

    private var forecastCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(source.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textPrimary)
                Spacer()
                Toggle("启用", isOn: Binding(
                    get: { store.enabled.contains(source) },
                    set: { store.setEnabled(source, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
            }

            if !store.enabled.contains(source) {
                Text("启用后每 30 分钟读取此公开预测，不发送账号凭据或本地会话数据。")
                    .font(.system(size: 11))
                    .foregroundStyle(MonitorTheme.textSecondary)
            } else if let snapshot = store.snapshots[source] {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(alignment: .leading, spacing: 6) {
                        forecastContent(snapshot, now: context.date)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(store.refreshing.contains(source) ? "正在读取公开数据…" : "尚无数据")
                    .font(.system(size: 11))
                    .foregroundStyle(MonitorTheme.textSecondary)
            }

            if let error = store.errors[source] {
                Text(error).font(.system(size: 10)).foregroundStyle(MonitorTheme.warning)
            }

            if source == .willReset {
                Link("前往网站邮件订阅 ↗", destination: source.website)
                    .font(.system(size: 11))
                    .tint(MonitorTheme.textPrimary)
            }

            HStack {
                Link("查看来源 ↗", destination: source.website).tint(MonitorTheme.textSecondary)
                Spacer()
                Button(store.refreshing.contains(source) ? "刷新中…" : "刷新") { store.refresh(source) }
                    .buttonStyle(.plain)
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .disabled(!store.enabled.contains(source) || store.refreshing.contains(source))
            }
            .font(.system(size: 10))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(MonitorTheme.sectionFill))
    }

    @ViewBuilder
    private func forecastContent(_ snapshot: PublicInsightSnapshot, now: Date) -> some View {
        if snapshot.isStale(now: now) || store.errors[source] != nil {
            Text("数据过期或来源部分不可用 · 以下为上次结果")
                .font(.system(size: 10))
                .foregroundStyle(MonitorTheme.warning)
        }

        HStack(spacing: 20) {
            ForEach(snapshot.probabilities.keys.sorted(), id: \.self) { hours in
                VStack(alignment: .leading, spacing: 4) {
                    Text("未来 \(hours) 小时")
                        .font(.system(size: 10))
                        .foregroundStyle(MonitorTheme.textSecondary)
                    Text(String(format: "%.0f%%", snapshot.probabilities[hours] ?? 0))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(MonitorTheme.textPrimary)
                }
            }
        }

        Text(snapshot.summary)
            .font(.system(size: 11))
            .foregroundStyle(MonitorTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        if let announcement = snapshot.announcement {
            Text(announcement).font(.system(size: 11)).foregroundStyle(MonitorTheme.warning)
        }

        if source == .observatory, let text = snapshot.latestTiboText {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tibo 最新动态")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textPrimary)
                Text(text)
                    .font(.system(size: 10))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .lineLimit(3)
                HStack {
                    if let date = snapshot.latestTiboAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Spacer()
                    if let url = snapshot.latestTiboURL { Link("查看原帖 ↗", destination: url) }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(MonitorTheme.textTertiary)
            }
            .padding(8)
            .background(MonitorTheme.sectionFill.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        }

        if let reset = snapshot.lastResetAt {
            Text("该站记录上次事件：\(reset.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 10))
                .foregroundStyle(MonitorTheme.textTertiary)
        }

        Text("最近获取：\(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.system(size: 10))
            .foregroundStyle(MonitorTheme.textTertiary)
        if let updated = snapshot.updatedAt {
            Text("来源生成：\(updated.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 10))
                .foregroundStyle(MonitorTheme.textTertiary)
        }
    }

    /// 性能页直接展示 CodexBar 的“状态页”二级菜单内容，不再增加额外入口层。
    private var openAIStatusMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.enabled.contains(.openAIStatus) {
                HStack {
                    Text("OpenAI 服务状态已关闭")
                        .font(.system(size: 11))
                        .foregroundStyle(MonitorTheme.textSecondary)
                    Spacer()
                    Button("启用") { store.setEnabled(.openAIStatus, true) }
                        .buttonStyle(.plain)
                        .foregroundStyle(MonitorTheme.textPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            } else if let snapshot = store.snapshots[.openAIStatus] {
                statusRows(snapshot.components)

                if snapshot.components.isEmpty {
                    Text("本次响应没有组件状态。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(MonitorTheme.warning)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }

                if snapshot.isStale() || store.errors[.openAIStatus] != nil {
                    Text("状态来源暂不可用，显示上次成功结果")
                        .font(.system(size: 10))
                        .foregroundStyle(MonitorTheme.warning)
                        .padding(.horizontal, 12)
                        .padding(.top, 7)
                }
            } else {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(store.refreshing.contains(.openAIStatus) ? "正在读取 OpenAI 服务状态…" : "尚无服务状态")
                        .font(.system(size: 11))
                        .foregroundStyle(MonitorTheme.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Divider().overlay(MonitorTheme.separator).padding(.top, 8)

            Link(destination: PublicInsightSource.openAIStatus.website) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("打开状态页")
                    Spacer()
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(MonitorTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: MonitorTheme.Radius.section, style: .continuous))
        .onAppear {
            if store.enabled.contains(.openAIStatus) { store.refreshIfNeeded() }
        }
    }

    @ViewBuilder
    private func statusRows(_ components: [PublicStatusComponent]) -> some View {
        let groups = components
            .filter { $0.isGroup == true }
            .sorted { ($0.position ?? 999) < ($1.position ?? 999) }
        let groupedIDs = Set(groups.map(\.id))
        let ungrouped = components
            .filter { $0.isGroup != true && ($0.groupID == nil || !groupedIDs.contains($0.groupID!)) }
            .sorted { ($0.position ?? 999) < ($1.position ?? 999) }

        ForEach(ungrouped) { component in
            statusLeafRow(component, indented: false)
        }

        ForEach(groups) { group in
            let children = components
                .filter { $0.groupID == group.id && $0.isGroup != true }
                .sorted { ($0.position ?? 999) < ($1.position ?? 999) }
            statusGroup(group, children: children)
        }
    }

    private func statusGroup(_ group: PublicStatusComponent, children: [PublicStatusComponent]) -> some View {
        let isExpanded = expandedStatusGroups.contains(group.id)
        return VStack(spacing: 0) {
            Button {
                if isExpanded { expandedStatusGroups.remove(group.id) }
                else { expandedStatusGroups.insert(group.id) }
            } label: {
                HStack(spacing: 8) {
                    statusDot(group)
                    Text(group.name)
                        .font(.system(size: 12))
                        .foregroundStyle(MonitorTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 16)
                    Text(statusText(group))
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor(group))
                        .lineLimit(1)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(MonitorTheme.textSecondary)
                        .frame(width: 10)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(children) { child in
                    statusLeafRow(child, indented: true)
                }
            }
        }
    }

    private func statusLeafRow(_ component: PublicStatusComponent, indented: Bool) -> some View {
        HStack(spacing: 8) {
            statusDot(component)
            Text(component.name)
                .font(.system(size: 12))
                .foregroundStyle(indented ? MonitorTheme.textSecondary : MonitorTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 16)
            Text(statusText(component))
                .font(.system(size: 11))
                .foregroundStyle(statusColor(component))
                .lineLimit(1)
            if !indented { Color.clear.frame(width: 10, height: 1) }
        }
        .padding(.leading, indented ? 29 : 12)
        .padding(.trailing, 12)
        .frame(height: 28)
    }

    private func statusDot(_ component: PublicStatusComponent) -> some View {
        Circle().fill(statusColor(component)).frame(width: 7, height: 7)
    }

    private func statusColor(_ component: PublicStatusComponent) -> Color {
        switch component.state {
        case "operational": MonitorTheme.healthy
        case "major_outage", "full_outage": MonitorTheme.critical
        case "degraded_performance", "partial_outage", "under_maintenance": MonitorTheme.warning
        default: MonitorTheme.textTertiary
        }
    }

    private func statusText(_ component: PublicStatusComponent) -> String {
        component.state == "operational" ? "正常运行" : component.label
    }
}

struct ResetPredictionPanel: View {
    @ObservedObject var store: PublicInsightsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("社区额外重置预测 · 仅供参考，不是个人 5h / 7d 重置时间。两个来源独立展示，不合并概率，也不触发自动续跑。")
                    .font(.system(size: 11))
                    .foregroundStyle(MonitorTheme.textSecondary)
                PublicInsightCard(source: .observatory, store: store)
                PublicInsightCard(source: .willReset, store: store)
            }
            .padding(.vertical, 4)
        }
        .onAppear { store.refreshIfNeeded() }
    }
}
