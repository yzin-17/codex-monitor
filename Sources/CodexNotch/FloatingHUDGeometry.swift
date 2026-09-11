import Foundation

/// 非刘海模式仍是覆盖菜单栏的 NSPanel，而不是系统状态栏项目。
/// 只改变窗口的裁剪区域；展开时内容保持最终尺寸和原字号，不缩放文字。
enum FloatingHUDGeometry {
    static func frame(screen: CGRect, menuBarHeight: CGFloat, contentSize: CGSize,
                      maximumWidth _: CGFloat, position: Double) -> CGRect {
        let barHeight = menuBarHeight.isFinite && menuBarHeight > 0 ? menuBarHeight : 24
        let height = max(1, min(100, barHeight))
        // 浮窗宽度完全跟随 HUD 内容，只在接近屏幕边缘时保留 12 pt 边距。
        let width = min(max(1, screen.width - 24), max(70, contentSize.width))
        let available = max(0, screen.width - width - 24)
        let fraction = position.isFinite ? min(1, max(0, position)) : 0.5
        return CGRect(x: screen.minX + 12 + available * fraction,
                      y: screen.maxY - height, width: width, height: height)
    }

    static func panel(screen: CGRect, visibleFrame: CGRect, anchor: CGRect) -> ExpandedPanelLayout {
        let visible = visibleFrame.isEmpty ? screen : visibleFrame
        let margin: CGFloat = 12
        let width = min(ExpandedPanelLayout.preferredSize.width, max(1, visible.width - margin * 2))
        // 顶边进入 HUD 2 pt，窗口层级放在 HUD 下面，避免看起来与浮窗脱离。
        let top = min(screen.maxY, anchor.minY + min(2, anchor.height))
        let height = min(ExpandedPanelLayout.preferredSize.height, max(1, top - visible.minY - margin))
        let x = min(max(anchor.midX - width / 2, visible.minX + margin), visible.maxX - width - margin)
        return .init(frame: CGRect(x: x, y: top - height, width: width, height: height), contentScale: 1)
    }

    static func collapsedFrame(anchor: CGRect, expanded: CGRect) -> CGRect {
        let width = min(anchor.width, expanded.width)
        return CGRect(x: anchor.midX - width / 2, y: expanded.maxY - 2, width: width, height: 2)
    }
}
