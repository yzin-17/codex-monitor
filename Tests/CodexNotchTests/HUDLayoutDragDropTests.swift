import AppKit
import SwiftUI
import Testing
@testable import CodexNotch

private let dragContext = HUDLayoutDragContext(sessionID: UUID(), layoutID: "fixture-layout", revision: 4)

@Test func hudPaletteDropUsesInsertionBoundaryAndSelectedAccount() throws {
    let layout = HUDLayout(lines: [["weekly@@local", "account@@local"], []])
    let payload = HUDLayoutDragPayload(context: dragContext, source: .palette(metric: .tokensPerSecond, sourceID: "remote:fixture"))
    guard case .layout(let result) = HUDLayoutDrop.apply(payload, context: dragContext, layout: layout, row: 0, before: 1) else {
        Issue.record("有效落点应产生布局"); return
    }
    #expect(result.lines == [["weekly@@local", "tokensPerSecond@@remote:fixture", "account@@local"], []])
    #expect(try JSONDecoder().decode(HUDLayoutDragPayload.self, from: JSONEncoder().encode(payload)) == payload)
}

@Test func hudPaletteExistingItemMovesWithoutShiftingTheRequestedBoundary() {
    let layout = HUDLayout(lines: [["weekly@@local", "account@@local", "tokensToday@@local"], []])
    let payload = HUDLayoutDragPayload(context: dragContext, source: .palette(metric: .weekly, sourceID: "local"))
    #expect(HUDLayoutDrop.apply(payload, context: dragContext, layout: layout, row: 0, before: 2)
        == .layout(.init(lines: [["account@@local", "weekly@@local", "tokensToday@@local"], []])))
}

@Test func hudDropMovesExactRepeatedSpaceAndRejectsStalePositions() {
    let layout = HUDLayout(lines: [["space:8", "weekly@@local", "space:8"], []])
    let payload = HUDLayoutDragPayload(context: dragContext, source: .placed(row: 0, index: 2, raw: "space:8"))
    #expect(HUDLayoutDrop.apply(payload, context: dragContext, layout: layout, row: 1, before: 0)
        == .layout(.init(lines: [["space:8", "weekly@@local"], ["space:8"]])))
    var changed = dragContext; changed.revision += 1
    #expect(HUDLayoutDrop.apply(payload, context: changed, layout: layout, row: 1, before: 0).rejection != nil)
    changed = dragContext; changed.layoutID = "another-layout"
    #expect(HUDLayoutDrop.remove(payload, context: changed, layout: layout).rejection != nil)
    changed = dragContext; changed.sessionID = UUID()
    #expect(HUDLayoutDrop.remove(payload, context: changed, layout: layout).rejection != nil)
    let wrongItem = HUDLayoutDragPayload(context: dragContext, source: .placed(row: 0, index: 1, raw: "space:8"))
    #expect(HUDLayoutDrop.remove(wrongItem, context: dragContext, layout: layout).rejection != nil)
}

@Test func hudFullRowRejectsNewAndCrossRowItemsButStillReorders() {
    let line = ["weekly@@local"] + Array(repeating: "space:8", count: 11)
    let layout = HUDLayout(lines: [line, ["tokensPerSecond@@local"]])
    let new = HUDLayoutDragPayload(context: dragContext, source: .palette(metric: .account, sourceID: "local"))
    #expect(HUDLayoutDrop.apply(new, context: dragContext, layout: layout, row: 0, before: 0)
        == .rejected(HUDLayoutDrop.fullRowMessage))
    let crossRow = HUDLayoutDragPayload(context: dragContext, source: .placed(row: 1, index: 0, raw: "tokensPerSecond@@local"))
    #expect(HUDLayoutDrop.apply(crossRow, context: dragContext, layout: layout, row: 0, before: 4)
        == .rejected(HUDLayoutDrop.fullRowMessage))
    let sameRow = HUDLayoutDragPayload(context: dragContext, source: .placed(row: 0, index: 0, raw: "weekly@@local"))
    guard case .layout(let result) = HUDLayoutDrop.apply(sameRow, context: dragContext, layout: layout, row: 0, before: 12) else {
        Issue.record("已满的一行仍应允许排序"); return
    }
    #expect(result.lines[0].last == "weekly@@local")
    #expect(result.lines[0].count == 12)
    #expect(result.lines[1] == ["tokensPerSecond@@local"])
}

@Test func hudConditionalDropKeepsRequestedRowAndBindingThroughMoveAndRemoval() throws {
    let layout = HUDLayout(lines: [["weekly@@local"], []])
    let payload = HUDLayoutDragPayload(context: dragContext, source: .palette(metric: .conditional, sourceID: "remote:fixture"))
    #expect(HUDLayoutDrop.apply(payload, context: dragContext, layout: layout, row: 0, before: 0)
        == .conditional(row: 0, index: 0, sourceID: "remote:fixture"))
    let id = UUID().uuidString
    let raw = "conditional:\(id)@@remote:fixture"
    var rule = HUDConditional(); rule.name = "保留条件"; rule.thenMetric = .tokensPerSecond
    guard case .layout(let added) = HUDLayoutDrop.insertConditional(rule, id: id, sourceID: "remote:fixture", layout: layout, row: 0, before: 0) else {
        Issue.record("条件控件应添加到指定落点"); return
    }
    #expect(added.lines == [[raw, "weekly@@local"], []])
    let placed = HUDLayoutDragPayload(context: dragContext, source: .placed(row: 0, index: 0, raw: raw))
    guard case .layout(let moved) = HUDLayoutDrop.apply(placed, context: dragContext, layout: added, row: 1, before: 0) else {
        Issue.record("条件控件应跨行移动"); return
    }
    #expect(moved.conditionals[id] == rule.normalized)
    #expect(moved.lines == [["weekly@@local"], [raw]])
    let removal = HUDLayoutDragPayload(context: dragContext, source: .placed(row: 1, index: 0, raw: raw))
    #expect(HUDLayoutDrop.remove(removal, context: dragContext, layout: moved) == .layout(layout))
}

@Test @MainActor func hudComponentWidthsGrowOnlyWithDisplayedContent() {
    let now = Date()
    let layout = HUDLayout(lines: [["tokensPerSecond"]])
    func rateWidth(_ value: Double?) -> CGFloat {
        HUDMetricStrip.measuredWidth(layout: layout,
            data: .init(tokenRate: .init(value: value, measuredAt: now, measuredCount: 1, activeCount: 1)),
            remaining: true, menuBar: true, now: now)
    }
    #expect(rateWidth(nil) < rateWidth(8.5))
    #expect(rateWidth(8.5) < rateWidth(68.4))
    #expect(rateWidth(68.4) < rateWidth(999.9))
    #expect(abs(rateWidth(68.4) - rateWidth(72.1)) < 0.001)

    let small = HUDEntityData(provider: "A", account: "本机", primary: 8, weekly: 8, balance: "1.0", todayTokens: "1K", costToday: "1.0", cost30d: "2.0")
    let large = HUDEntityData(provider: "LongProvider", account: "更长的账户名称", primary: 100, weekly: 100, balance: "9999.0", todayTokens: "999.9M", costToday: "9999.0", cost30d: "9999.0")
    for metric in [HUDMetric.provider, .account, .primary, .weekly, .balance, .tokensToday, .costToday, .cost30d] {
        let single = HUDLayout(lines: [[metric.rawValue]])
        #expect(HUDMetricStrip.measuredWidth(layout: single, data: large, remaining: true, menuBar: true)
            > HUDMetricStrip.measuredWidth(layout: single, data: small, remaining: true, menuBar: true))
    }
}

@Test @MainActor func hudHiddenItemsLeaveNoWidthAndExplicitVisualSizesStayExact() {
    let data = HUDEntityData(weekly: 42)
    let plain = HUDLayout(lines: [["weekly"]])
    let hidden = HUDLayout(lines: [["hidden", "weekly"]])
    #expect(HUDMetricStrip.measuredWidth(layout: plain, data: data, remaining: true, menuBar: true)
        == HUDMetricStrip.measuredWidth(layout: hidden, data: data, remaining: true, menuBar: true))
    #expect(HUDMetricStrip.measuredWidth(layout: .init(lines: [["icon", "space:16", "usageBar"]]), data: data, remaining: true, menuBar: true) == 63)
    let twoRows = HUDLayout(lines: [["space:8"], ["space:32", "space:16"]])
    #expect(HUDMetricStrip.measuredWidth(layout: twoRows, data: data, remaining: true, menuBar: true) == 53)
}

@Test @MainActor func hudNativeChipKeepsClickAndContextMenuActions() throws {
    _ = NSApplication.shared
    let chip = HUDLayoutDragChipView(frame: .init(x: 0, y: 0, width: 120, height: 32))
    var clicks = 0
    chip.configure(label: AnyView(Text("Token 速度").padding(6)), accessibilityLabel: "Token 速度",
                   identifier: "fixture-chip", enabled: true,
                   payload: { .init(context: dragContext, source: .palette(metric: .tokensPerSecond, sourceID: "local")) },
                   onClick: { clicks += 1 }, menu: { let menu = NSMenu(); menu.addItem(hudLayoutMenuItem("移除") {}); return menu })
    let window = NSWindow(contentRect: chip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = chip
    defer { window.contentView = nil; window.close() }
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 20, y: 16), modifierFlags: [], timestamp: 1,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: .init(x: 20, y: 16), modifierFlags: [], timestamp: 1.1,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
    chip.mouseDown(with: down)
    chip.mouseUp(with: up)
    #expect(clicks == 1)
    #expect(chip.menu(for: down)?.items.first?.title == "移除")
    #expect(chip.accessibilityPerformPress())
    #expect(clicks == 2)
}
