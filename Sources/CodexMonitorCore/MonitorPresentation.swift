import Foundation

/// 仅用于界面的只读投影；不改变扫描器和累计 Token 口径。
public enum MonitorActivity: String, Sendable {
    case running = "RUNNING", idle = "IDLE", stale = "STALE", interrupted = "STOPPED", unknown = "UNKNOWN"
    public var rank: Int {
        switch self { case .running: 0; case .stale: 1; case .interrupted: 2; case .unknown: 3; case .idle: 4 }
    }
    public static func resolve(_ session: Session, now: Date) -> Self {
        switch session.status {
        case "日志显示运行中":
            guard let date = session.lastActivity else { return .unknown }
            let age = now.timeIntervalSince(date)
            if age < -60 { return .unknown }
            return age <= 600 ? .running : .stale
        case "已完成": return .idle
        case "已中断": return .interrupted
        default: return .unknown
        }
    }
}

public struct MonitorTaskRow: Identifiable, Sendable {
    public let task: TaskUsage
    public let activity: MonitorActivity
    public let today: Tokens
    public let share: Double?
    public var id: String { task.id }
}

public struct MonitorDashboard: Sendable {
    public let rows: [MonitorTaskRow]
    public let today: Tokens
    public let week: Tokens
    public let month: Tokens
    public let runningTasks: Int
    public let runningAgents: Int
    public let activity: MonitorActivity
    public let generatedAt: Date

    public init(sessions: [Session], now: Date = Date(), calendar: Calendar = .current) {
        generatedAt = now
        let day = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: day) ?? now
        today = LedgerMath.usage(sessions, since: day, until: end)
        week = LedgerMath.usage(sessions, since: calendar.date(byAdding: .day, value: -6, to: day) ?? day, until: end)
        month = LedgerMath.usage(sessions, since: calendar.date(byAdding: .day, value: -29, to: day) ?? day, until: end)
        let totalToday = today.total
        rows = LedgerMath.tasks(sessions).map { task in
            let members = [task.root] + task.descendants
            let states = members.map { MonitorActivity.resolve($0, now: now) }
            let activity = states.min { $0.rank < $1.rank } ?? .unknown
            let usage = LedgerMath.usage(members, since: day, until: end)
            return MonitorTaskRow(task: task, activity: activity, today: usage,
                                  share: totalToday > 0 ? Double(usage.total) / Double(totalToday) : nil)
        }.sorted {
            if $0.activity.rank != $1.activity.rank { return $0.activity.rank < $1.activity.rank }
            if $0.today.total != $1.today.total { return $0.today.total > $1.today.total }
            if $0.task.total.total != $1.task.total.total { return $0.task.total.total > $1.task.total.total }
            return $0.id < $1.id
        }
        runningTasks = rows.filter { $0.activity == .running }.count
        runningAgents = sessions.filter { $0.isSubagent && MonitorActivity.resolve($0, now: now) == .running }.count
        activity = rows.map(\.activity).min { $0.rank < $1.rank } ?? .unknown
    }
}

public enum MonitorQuota {
    /// 不把 Spark 等独立桶误当作通用 5h / 7d 额度。
    public static func generalWindow(_ windows: [QuotaWindow], minutes: Int) -> QuotaWindow? {
        windows.filter {
            $0.minutes == minutes && $0.id.lowercased().hasPrefix("codex:")
        }.max { ($0.observedAt ?? .distantPast) < ($1.observedAt ?? .distantPast) }
    }
    public static func expired(_ window: QuotaWindow, now: Date = Date()) -> Bool {
        window.resetsAt.map { $0 <= now } ?? false
    }
    public static func percentage(_ window: QuotaWindow?, now: Date = Date()) -> String {
        guard let window, window.observedAt != nil, !expired(window, now: now) else { return "—" }
        return String(format: "%.0f%%", window.remainingPercent)
    }
}
