import SwiftUI
import CodexMonitorCore

/// 按参考图统一设计常量。绿色仅用于运行状态与额度，不铺满页面。
enum MonitorTheme {
    static let background = Color(red: 0.038, green: 0.043, blue: 0.043)
    static let surface = Color(red: 0.095, green: 0.101, blue: 0.101)
    static let inset = Color(red: 0.068, green: 0.074, blue: 0.074)
    static let selected = Color(red: 0.184, green: 0.193, blue: 0.193)
    static let stroke = Color.white.opacity(0.055)
    static let text = Color(red: 0.90, green: 0.92, blue: 0.92)
    static let secondary = Color(red: 0.60, green: 0.63, blue: 0.63)
    static let muted = Color(red: 0.40, green: 0.44, blue: 0.44)
    static let accent = Color(red: 0.43, green: 0.77, blue: 0.55)
    static let cyan = Color(red: 0.34, green: 0.72, blue: 0.80)
    static let amber = Color(red: 0.91, green: 0.67, blue: 0.38)
    static let hud = Color(red: 0.035, green: 0.13, blue: 0.18)
    static func color(_ activity: MonitorActivity) -> Color {
        switch activity {
        case .running: accent
        case .stale, .interrupted: amber
        case .idle, .unknown: muted
        }
    }
}

struct MonitorIconButton: View {
    let icon: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 16, weight: .medium)).frame(width: 30, height: 30) }
            .buttonStyle(.plain).foregroundStyle(MonitorTheme.secondary).help(label).accessibilityLabel(label)
    }
}
struct MonitorBadge: View {
    let text: String
    var color: Color = MonitorTheme.accent
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).tracking(0.25)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color).background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
    }
}
struct Surface<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading).monitorSurface()
    }
}
extension View {
    func monitorSurface(radius: CGFloat = 14) -> some View {
        background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(MonitorTheme.stroke, lineWidth: 1))
    }
}
struct Notice: View {
    let text: String
    var warning = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(warning ? MonitorTheme.amber : MonitorTheme.muted).frame(width: 6, height: 6).padding(.top, 5)
            Text(text).font(.system(size: 11)).foregroundStyle(MonitorTheme.secondary).textSelection(.enabled)
            Spacer(minLength: 0)
        }.padding(12).background(MonitorTheme.inset, in: RoundedRectangle(cornerRadius: 9))
    }
}
struct EmptyPanel: View {
    let title: String
    let detail: String
    let icon: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(MonitorTheme.muted)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(MonitorTheme.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 370)
        }.frame(maxWidth: .infinity, minHeight: 160).padding(20)
    }
}
struct DetailShell<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer()
                MonitorIconButton(icon: "xmark", label: "关闭详情") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Rectangle().fill(MonitorTheme.stroke).frame(height: 1)
            content()
        }.frame(width: 660, height: 640).foregroundStyle(MonitorTheme.text)
            .background(MonitorTheme.background).preferredColorScheme(.dark).tint(MonitorTheme.accent)
    }
}
