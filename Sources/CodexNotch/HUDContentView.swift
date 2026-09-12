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
        case .primary: MonitorTheme.textPrimary
        case .secondary: MonitorTheme.textSecondary
        case .tertiary: MonitorTheme.textTertiary
        case .healthy: MonitorTheme.healthy
        case .warning: MonitorTheme.warning
        case .critical: MonitorTheme.critical
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
            if enabled {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
            }
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
        row.filter { raw in
            guard let metric = entity(raw).resolvedMetric(raw: raw, layout: layout, now: now) else { return false }
            return metric != .hidden
        }
    }

    @ViewBuilder private func cell(_ raw: String, now: Date) -> some View {
        let itemData = entity(raw)
        let metric = itemData.resolvedMetric(raw: raw, layout: layout, now: now)
        if metric == .space {
            Color.clear.frame(width: CGFloat(HUDLayout.spaceWidth(raw)), height: 1).accessibilityHidden(true)
        } else if metric == .icon {
            OpenAIKnotIcon(size: menuBar ? 11 : 12)
                .foregroundStyle(MonitorTheme.textPrimary)
                .accessibilityLabel("ChatGPT")
        } else if metric == .usageBar {
            ZStack(alignment: .leading) {
                Capsule().fill(MonitorTheme.progressTrack)
                Capsule().fill(itemData.tone(for: itemData.automatic).color)
                    .frame(width: 26 * CGFloat((remaining ? itemData.automatic : itemData.automatic.map { 100 - $0 }) ?? 0) / 100)
            }
            .frame(width: 26, height: 4)
            .accessibilityLabel("用量 \(itemData.text(.usageBar, remaining: remaining, now: now))")
        } else {
            let value = metric.map { itemData.display($0, remaining: remaining, now: now) }
                ?? HUDDisplayValue(value: "—", tone: .tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if !value.label.isEmpty {
                    Text(value.label)
                        .font(.system(size: max(7, fontSize - 1.5), weight: .semibold))
                        .foregroundStyle(MonitorTheme.textSecondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(value.value)
                    .foregroundStyle(value.tone.color)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func helpText(now: Date) -> String {
        let entries = rows.flatMap { $0 }.compactMap { raw -> String? in
            let itemData = entity(raw)
            guard let metric = itemData.resolvedMetric(raw: raw, layout: layout, now: now) else { return nil }
            if [.space, .hidden, .separatorDot].contains(metric) { return nil }
            let source = HUDLayoutToken.sourceID(raw).map { " [\($0)]" } ?? " [本机 Codex]"
            return metric.title + source + "：" + itemData.text(metric, remaining: remaining, now: now)
        }
        return (data.warning.map { "注意：\($0)\n" } ?? "")
            + entries.joined(separator: "\n")
            + "\n节奏/预计用尽仅按本窗口平均速度估算；缺少可靠窗口数据时显示 —。"
    }

    /// 与渲染使用同一字段/条件/空格宽度，避免靠整行缩放挤入菜单栏。
    @MainActor static func measuredWidth(
        layout: HUDLayout,
        data: HUDEntityData,
        remaining: Bool,
        menuBar: Bool,
        now: Date = Date(),
        dataForRaw: ((String) -> HUDEntityData)? = nil
    ) -> CGFloat {
        let rows = layout.normalized.lines
        let size: CGFloat = menuBar && rows.count == 2 ? min(9, MenuBarMetrics.height() / 2.5) : 11
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let labelFont = NSFont.systemFont(ofSize: max(7, size - 1.5), weight: .semibold)
        return rows.map { row in
            let visible = row.filter { raw in
                let itemData = dataForRaw?(raw) ?? data
                guard let metric = itemData.resolvedMetric(raw: raw, layout: layout, now: now) else { return false }
                return metric != .hidden
            }
            return visible.reduce(CGFloat(0)) { sum, raw in
                let itemData = dataForRaw?(raw) ?? data
                let metric = itemData.resolvedMetric(raw: raw, layout: layout, now: now)
                if metric == .space { return sum + CGFloat(HUDLayout.spaceWidth(raw)) }
                if metric == .icon { return sum + (menuBar ? 13 : 14) }
                if metric == .usageBar { return sum + 26 }
                let value = metric.map { itemData.display($0, remaining: remaining, now: now) } ?? .init(value: "—")
                let label = value.label.isEmpty ? 0 : (value.label as NSString).size(withAttributes: [.font: labelFont]).width + 4
                return sum + label + (value.value as NSString).size(withAttributes: [.font: font]).width
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

    /// 兼容旧测试/诊断调用：反映编辑器当前选择的数据源；HUD 运行时不会用它切换布局或改绑控件。
    var data: HUDEntityData {
        .resolve(source: preferences.value.sourceID, usage: usage, remote: remote, newAPI: newAPI, subAPI: subAPI,
                 accounts: accounts, settings: settings)
    }

    /// 布局不再拥有“当前账号”。没有绑定信息的旧 token 只回退本机 Codex。
    private var localData: HUDEntityData {
        .resolve(source: "local", usage: usage, remote: remote, newAPI: newAPI, subAPI: subAPI,
                 accounts: accounts, settings: settings)
    }
    private var forecastAlert: (PublicInsightSource, Double)? { publicInsights.forecastAlert }

    private func dataForRaw(_ raw: String) -> HUDEntityData {
        let source = HUDLayoutToken.sourceID(raw) ?? "local"
        return .resolve(source: source, usage: usage, remote: remote, newAPI: newAPI, subAPI: subAPI,
                        accounts: accounts, settings: settings)
    }

    var body: some View {
        let layout = preferences.value.activeLayout
        let data = localData
        let forecastWidth: CGFloat = forecastAlert == nil ? 0 : 66
        let rightWidth = notch.map {
            let needed = HUDMetricStrip.measuredWidth(
                layout: layout,
                data: data,
                remaining: true,
                menuBar: false,
                dataForRaw: dataForRaw
            ) + 12 + forecastWidth
            return max(
                $0.shoulderWidth,
                min(preferences.value.normalized.maximumWidth, needed)
            )
        } ?? 0

        Group {
            if let notch {
                HStack(spacing: 0) {
                    HUDRuntimeStatus(
                        isRunning: usage.snapshot.isRunning,
                        enablePulse: settings.enablePulse,
                        compact: true,
                        narrow: notch.shoulderWidth < HUDRuntimeStatus.reservedWidth
                    )
                    .frame(width: notch.shoulderWidth, alignment: .center)
                    Color.clear.frame(width: notch.notchWidth)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            HUDMetricStrip(
                                layout: layout,
                                data: data,
                                remaining: true,
                                dataForRaw: dataForRaw
                            )
                            forecastBadge
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    // 12pt 预留必须真实分到两侧：左 4pt、右 8pt，不能只缩 frame 后再单侧 padding。
                    .frame(width: rightWidth - 12, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.trailing, 8)
                }
                .frame(width: notch.shoulderWidth + notch.notchWidth + rightWidth, height: notch.collapsedHeight)
            } else {
                HStack(spacing: 9) {
                    HUDRuntimeStatus(
                        isRunning: usage.snapshot.isRunning,
                        enablePulse: settings.enablePulse,
                        compact: menuBar
                    )
                    .frame(width: HUDRuntimeStatus.reservedWidth, alignment: .leading)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            HUDMetricStrip(
                                layout: layout,
                                data: data,
                                remaining: true,
                                menuBar: menuBar,
                                dataForRaw: dataForRaw
                            )
                            forecastBadge
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, menuBar ? 0 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: menuBar ? MenuBarMetrics.height() : nil)
        .background(HUDGlassBackground(opacity: preferences.value.normalized.hudOpacity))
        .clipShape(RoundedRectangle(
            cornerRadius: CGFloat(preferences.value.normalized.cornerRadius),
            style: .continuous
        ))
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var forecastBadge: some View {
        if let alert = forecastAlert {
            Text(String(format: "预测 %.0f%%", alert.1))
                .font(.system(size: menuBar ? 9 : 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(MonitorTheme.warning)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(MonitorTheme.warning.opacity(0.12), in: Capsule())
                .help("社区重置预测超过 70%，仅供参考；不会触发续跑")
        }
    }
}
