import AppKit

/// 菜单栏高度随屏幕缩放、刘海与系统配置变化，不能固定为 22 pt。
@MainActor enum MenuBarMetrics {
    static func height(for screen: NSScreen? = NSScreen.main ?? NSScreen.screens.first) -> CGFloat {
        guard let screen else { return max(1, NSStatusBar.system.thickness) }
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY
        // 菜单栏自动隐藏时 visibleFrame 无顶边留白，退回系统报告的高度。
        if topInset.isFinite, topInset > 0, topInset <= 100 { return topInset }
        return max(1, min(100, NSStatusBar.system.thickness))
    }
}
