import AppKit
import SwiftUI

// 使用原版中性黑底，不使用会吸收壁纸色的 behindWindow/hudWindow 材质。
// 透明度只影响背景，正文与状态色始终取 MonitorTheme。
struct HUDGlassBackground: View {
    var opacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Color.black.opacity(reduceTransparency ? 1 : min(1, max(0, opacity)))
    }
}
extension HUDTone {
    var color: Color {
        switch self {
        case .primary: MonitorTheme.textPrimary; case .secondary: MonitorTheme.textSecondary
        case .tertiary: MonitorTheme.textTertiary; case .healthy: MonitorTheme.healthy
        case .warning: MonitorTheme.warning; case .critical: MonitorTheme.critical
        }
    }
}

/// 固定区域：只表达本机 Codex 是否在执行，不能从布局删除，也不跟随远程来源切换。
struct HUDRuntimeStatus: View {
    let isRunning: Bool
    var enablePulse = false
    var compact = false
    var narrow = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    private var activePulse: Bool { isRunning && enablePulse && !reduceMotion }
    static let reservedWidth: CGFloat = 47
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(isRunning ? MonitorTheme.running : MonitorTheme.neutral)
                .frame(width: 8, height: 8)
                .shadow(color: isRunning ? MonitorTheme.running.opacity(0.40) : .clear, radius: 4)
                .opacity(activePulse && pulse ? 0.60 : 1)
            Text(isRunning ? "RUN" : "IDLE")
                .font(.system(size: narrow ? 8.5 : compact ? 10 : 10.5, weight: .bold))
                .foregroundStyle(isRunning ? MonitorTheme.textPrimary : MonitorTheme.textSecondary)
        }
        .fixedSize().layoutPriority(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRunning ? "本机 Codex 正在运行" : "本机 Codex 空闲")
        .help("本机 Codex 运行状态（固定显示，不随右侧账户选择改变）")
        .onChange(of: activePulse, initial: true) { _, enabled in
            withAnimation(nil) { pulse = false }
            if enabled { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true } }
        }
    }
}
struct HUDMetricStrip: View {
    let layout: HUDLayout
    let data: HUDEntityData
    var remaining = true
    var menuBar = false
    var dataForRaw: ((String) -> HUDEntityData)? = nil
    private var rows: [[String]] { layout.normalized.lines }
    private func entity(_ raw: String) -> HUDEntityData { dataForRaw?(raw) ?? data }
    private var fontSize: CGFloat { menuBar && rows.count == 2 ? min(9, MenuBarMetrics.height() / 2.5) : 11 }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: menuBar && rows.count == 2 ? 0 : 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        ForEach(Array(visible(row, at: context.date).enumerated()), id: \.offset) { _, raw in
                            cell(raw, now: context.date)
                        }
                    }
                }
            }
            .font(.system(size: fontSize, weight: .semibold)).monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
            .help(helpText(now: context.date))
        }
    }
    private func visible(_ row: [String], at now: Date) -> [String] {
        row.filter { entity($0).resolvedMetric(raw: $0, layout: layout, now: now) != .hidden }
    }
    @ViewBuilder private func cell(_ raw: String, now: Date) -> some View {
        let itemData = entity(raw)
        let metric = itemData.resolvedMetric(raw: raw, layout: layout, now: now)
        if metric == .space { Color.clear.frame(width: CGFloat(HUDLayout.spaceWidth(raw)), height: 1).accessibilityHidden(true) }
        else if metric == .icon { Image(systemName: "scope").foregroundStyle(MonitorTheme.textPrimary).accessibilityLabel(itemData.provider) }
        else if metric == .usageBar {
            ZStack(alignment: .leading) {
                Capsule().fill(MonitorTheme.progressTrack)
                Capsule().fill(itemData.tone(for: itemData.automatic).color)
                    .frame(width: 26 * CGFloat((remaining ? itemData.automatic : itemData.automatic.map { 100 - $0 }) ?? 0) / 100)
            }.frame(width: 26, height: 4)
                .accessibilityLabel("用量 \(itemData.text(.usageBar, remaining: remaining, now: now))")
        } else {
            let value = metric.map { itemData.display($0, remaining: remaining, now: now) } ?? HUDDisplayValue(value: "—", tone: .tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if !value.label.isEmpty {
                    Text(value.label).font(.system(size: max(7, fontSize - 1.5), weight: .semibold))
                        .foregroundStyle(MonitorTheme.textSecondary)
                }
                Text(value.value).foregroundStyle(value.tone.color)
            }.lineLimit(1)
        }
    }
    private func helpText(now: Date) -> String {
        let entries = rows.flatMap { $0 }.compactMap { raw -> String? in
            let itemData = entity(raw)
            guard let metric = itemData.resolvedMetric(raw: raw, layout: layout, now: now) else { return "条件：数据不足（—）" }
            if [.space, .hidden, .separatorDot].contains(metric) { return nil }
            let source = HUDLayoutToken.sourceID(raw).map { " [\($0)]" } ?? ""
            return metric.title + source + "：" + itemData.text(metric, remaining: remaining, now: now)
        }
        return (data.warning.map { "注意：\($0)\n" } ?? "") + entries.joined(separator: "\n") + "\n节奏/预计用尽仅按本窗口平均速度估算；缺少可靠窗口数据时显示 —。"
    }
    /// 与渲染使用同一字段/条件/空格宽度，避免靠整行缩放挤入菜单栏。
    @MainActor static func measuredWidth(layout: HUDLayout, data: HUDEntityData, remaining: Bool, menuBar: Bool,
                                         now: Date = Date(), dataForRaw: ((String) -> HUDEntityData)? = nil) -> CGFloat {
        let rows = layout.normalized.lines
        let size: CGFloat = menuBar && rows.count == 2 ? min(9, MenuBarMetrics.height() / 2.5) : 11
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: max(7, size - 1.5), weight: .semibold)
        return rows.map { row in
            let visible = row.filter { (dataForRaw?($0) ?? data).resolvedMetric(raw: $0, layout: layout, now: now) != .hidden }
            return visible.reduce(CGFloat(0)) { sum, raw in
                let itemData = dataForRaw?(raw) ?? data
                let metric = itemData.resolvedMetric(raw: raw, layout: layout, now: now)
                if metric == .space { return sum + CGFloat(HUDLayout.spaceWidth(raw)) }
                if metric == .icon { return sum + 12 }
                if metric == .usageBar { return sum + 26 }
                let v = metric.map { itemData.display($0, remaining: remaining, now: now) } ?? .init(value: "—")
                let label = v.label.isEmpty ? 0 : (v.label as NSString).size(withAttributes: [.font: labelFont]).width + 4
                return sum + label + (v.value as NSString).size(withAttributes: [.font: font]).width
            } + CGFloat(max(0, visible.count - 1)) * 5
        }.max() ?? 0
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
    @ObservedObject var publicInsights: PublicInsightsStore
    var menuBar = false
    var notch: IslandLayout? = nil
    var data: HUDEntityData { .resolve(source: preferences.value.sourceID, usage: usage, remote: remote, newAPI: newAPI, subAPI: subAPI, accounts: accounts, settings: settings) }
    private var forecastAlert: (PublicInsightSource, Double)? { publicInsights.forecastAlert }
    private var layoutKey: String { preferences.value.providerLayouts[preferences.value.sourceID] != nil ? preferences.value.sourceID : data.providerID }
    private func dataForRaw(_ raw: String) -> HUDEntityData {
        let source = HUDLayoutToken.sourceID(raw) ?? preferences.value.sourceID
        return .resolve(source: source, usage: usage, remote: remote, newAPI: newAPI, subAPI: subAPI, accounts: accounts, settings: settings)
    }
    var body: some View {
        let layout = preferences.value.layout(for: layoutKey)
        let rightWidth = notch.map { max($0.shoulderWidth, min(preferences.value.normalized.maximumWidth, HUDMetricStrip.measuredWidth(layout: layout, data: data, remaining: preferences.value.showRemaining, menuBar: false, dataForRaw: dataForRaw) + 12)) } ?? 0
        Group {
            if let notch {
                HStack(spacing: 0) {
                    HUDRuntimeStatus(isRunning: usage.snapshot.isRunning, enablePulse: settings.enablePulse, compact: true, narrow: notch.shoulderWidth < HUDRuntimeStatus.reservedWidth)
                        .frame(width: notch.shoulderWidth, alignment: .center)
                    Color.clear.frame(width: notch.notchWidth)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            HUDMetricStrip(layout: layout, data: data, remaining: preferences.value.showRemaining, dataForRaw: dataForRaw)
                            forecastBadge
                        }.fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(width: max(1, rightWidth - 8), alignment: .leading).padding(.leading, 8)
                }.frame(width: notch.shoulderWidth + notch.notchWidth + rightWidth, height: notch.collapsedHeight)
            } else {
                HStack(spacing: 9) {
                    HUDRuntimeStatus(isRunning: usage.snapshot.isRunning, enablePulse: settings.enablePulse, compact: menuBar)
                        .frame(width: HUDRuntimeStatus.reservedWidth, alignment: .leading)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            HUDMetricStrip(layout: layout, data: data, remaining: preferences.value.showRemaining, menuBar: menuBar, dataForRaw: dataForRaw)
                            forecastBadge
                        }.fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(0)
                }
                .padding(.horizontal, 8).padding(.vertical, menuBar ? 0 : 4)
                .frame(maxWidth: preferences.value.normalized.maximumWidth)
            }
        }
        .frame(height: menuBar ? MenuBarMetrics.height() : nil)
        .background(HUDGlassBackground(opacity: preferences.value.normalized.hudOpacity))
        .clipShape(RoundedRectangle(cornerRadius: menuBar ? 5 : 14))
        .preferredColorScheme(.dark)
    }
    @ViewBuilder private var forecastBadge: some View {
        if let alert = forecastAlert {
            Text(String(format: "预测 %.0f%%", alert.1))
                .font(.system(size: menuBar ? 9 : 10, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(MonitorTheme.warning)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(MonitorTheme.warning.opacity(0.12), in: Capsule())
                .help("社区重置预测超过 70%，仅供参考；不会触发续跑")
        }
    }
}
