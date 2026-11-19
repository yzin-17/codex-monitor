import AppKit
import Testing
@testable import CodexNotch

@Test @MainActor func overlayKeepsNativePopoverAndFilePickerInteractionLocal() throws {
    _ = NSApplication.shared
    let hud = NSPanel(contentRect: NSRect(x: 80, y: 500, width: 120, height: 24),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let detail = NSPanel(contentRect: NSRect(x: 80, y: 320, width: 320, height: 180),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let unrelated = NSWindow(contentRect: NSRect(x: 600, y: 100, width: 180, height: 120),
                             styleMask: [.borderless], backing: .buffered, defer: false)
    let picker = NSOpenPanel()
    let windows: [NSWindow] = [hud, detail, unrelated, picker]
    for window in windows { window.isReleasedWhenClosed = false }
    defer { for window in windows { window.orderOut(nil); window.close() } }
    hud.addChildWindow(detail, ordered: .below)
    defer { hud.removeChildWindow(detail) }
    let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    detail.contentView = anchor
    detail.orderFrontRegardless()
    let content = NSViewController()
    content.view = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 100))
    let popover = NSPopover()
    popover.contentViewController = content
    popover.contentSize = content.view.frame.size
    popover.animates = false
    popover.show(relativeTo: NSRect(x: 280, y: 5, width: 20, height: 20), of: anchor, preferredEdge: .maxX)
    defer { popover.close() }
    let popoverWindow = try #require(content.view.window)
    let outside = NSPoint(x: 900, y: 50)
    #expect(!OverlayInteractionPolicy.shouldDismissForClick(at: outside, eventWindow: popoverWindow,
        hud: hud, detail: detail, modal: nil))
    #expect(!OverlayInteractionPolicy.shouldHandleEscape(eventWindow: popoverWindow,
        hud: hud, detail: detail, modal: nil))
    #expect(!OverlayInteractionPolicy.shouldDismissForClick(at: outside, eventWindow: picker,
        hud: hud, detail: detail, modal: picker))
    #expect(!OverlayInteractionPolicy.shouldHandleEscape(eventWindow: picker,
        hud: hud, detail: detail, modal: picker))
    #expect(OverlayInteractionPolicy.shouldDismissForClick(at: outside, eventWindow: unrelated,
        hud: hud, detail: detail, modal: nil))
    #expect(OverlayInteractionPolicy.shouldDismissForClick(at: outside, eventWindow: nil,
        hud: hud, detail: detail, modal: picker))
    #expect(OverlayInteractionPolicy.shouldHandleEscape(eventWindow: detail,
        hud: hud, detail: detail, modal: nil))
    #expect(!OverlayInteractionPolicy.shouldHandleEscape(eventWindow: unrelated,
        hud: hud, detail: detail, modal: nil))
}
