import Foundation

/// 展开面板独立于物理刘海；紧凑 HUD 的几何与动画保持原版。
struct ExpandedPanelLayout: Equatable, Sendable {
    static let preferredSize = CGSize(width: 680, height: 720)
    static let readableScale: CGFloat = 1.4
    let frame: CGRect
    let contentScale: CGFloat
    var logicalSize: CGSize {
        CGSize(width: frame.width / contentScale, height: frame.height / contentScale)
    }

    static func make(screenFrame: CGRect, visibleFrame: CGRect,
                     collapsedHeight: CGFloat, overlap: CGFloat = 18) -> Self {
        let visible = visibleFrame.isEmpty ? screenFrame : visibleFrame
        let margin: CGFloat = 12
        let width = min(preferredSize.width, max(1, visible.width - 2 * margin))
        let top = screenFrame.maxY - collapsedHeight + overlap
        let height = min(preferredSize.height, max(1, top - visible.minY - margin))
        let left = min(max(screenFrame.midX - width / 2, visible.minX + margin),
                       visible.maxX - width - margin)
        return Self(frame: CGRect(x: left, y: top - height, width: width, height: height),
                    contentScale: readableScale)
    }
}
