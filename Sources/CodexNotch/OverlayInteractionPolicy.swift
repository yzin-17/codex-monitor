import AppKit

/// 详情弹层及其文件选择框拥有独立窗口，不能只用详情窗口矩形判断外部点击。
@MainActor
enum OverlayInteractionPolicy {
    static func isAuxiliaryWindow(_ eventWindow: NSWindow?, hud: NSWindow, detail: NSWindow,
                                  modal: NSWindow?) -> Bool {
        guard let eventWindow, eventWindow !== hud, eventWindow !== detail else { return false }
        if let modal, belongs(eventWindow, to: modal) { return true }
        return belongs(eventWindow, to: detail) || belongs(eventWindow, to: hud)
    }

    static func shouldDismissForClick(at location: NSPoint, eventWindow: NSWindow?,
                                      hud: NSWindow, detail: NSWindow, modal: NSWindow?) -> Bool {
        if isAuxiliaryWindow(eventWindow, hud: hud, detail: detail, modal: modal) { return false }
        return !hud.frame.contains(location) && !detail.frame.contains(location)
    }

    static func shouldHandleEscape(eventWindow: NSWindow?, hud: NSWindow, detail: NSWindow,
                                   modal: NSWindow?) -> Bool {
        // 弹层先关闭自己，文件选择框先取消；不抢走其他应用窗口的按键。
        guard modal == nil, let eventWindow else { return false }
        return eventWindow === hud || eventWindow === detail
    }

    private static func belongs(_ window: NSWindow, to owner: NSWindow) -> Bool {
        var current: NSWindow? = window
        var visited = Set<ObjectIdentifier>()
        while let candidate = current, visited.insert(ObjectIdentifier(candidate)).inserted {
            if candidate === owner { return true }
            current = candidate.parent ?? candidate.sheetParent
        }
        return false
    }
}
