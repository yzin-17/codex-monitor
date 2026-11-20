import AppKit
import SwiftUI


/// 拖动只在当前设置窗口、当前布局和当前草稿版本中生效。
struct HUDLayoutDragContext: Codable, Equatable, Sendable {
    var sessionID: UUID
    var layoutID: String
    var revision: UInt64
}

struct HUDLayoutDragPayload: Codable, Equatable, Sendable {
    enum Source: Codable, Equatable, Sendable {
        case palette(metric: HUDMetric, sourceID: String)
        case placed(row: Int, index: Int, raw: String)
    }
    var context: HUDLayoutDragContext
    var source: Source

    static let pasteboardType = NSPasteboard.PasteboardType("app.codexmonitor.hud-layout-item")
    var operation: NSDragOperation {
        if case .palette = source { return .copy }
        return .move
    }

    @MainActor static func read(from pasteboard: NSPasteboard) -> Self? {
        guard let data = pasteboard.data(forType: pasteboardType), data.count <= 8_192 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum HUDLayoutDropResult: Equatable, Sendable {
    case layout(HUDLayout)
    case conditional(row: Int, index: Int, sourceID: String)
    case rejected(String)

    var rejection: String? {
        if case .rejected(let reason) = self { return reason }
        return nil
    }
}

enum HUDLayoutDrop {
    static let fullRowMessage = "每行最多 12 个控件，请移到另一行或先移除一个控件。"
    static let staleMessage = "布局已变化，请重新拖动。"

    static func apply(_ payload: HUDLayoutDragPayload, context: HUDLayoutDragContext,
                      layout: HUDLayout, row: Int, before: Int) -> HUDLayoutDropResult {
        let current = layout.normalized
        guard payload.context == context else { return .rejected(staleMessage) }
        guard current.lines.indices.contains(row), (0...current.lines[row].count).contains(before) else {
            return .rejected(staleMessage)
        }
        switch payload.source {
        case .placed(let sourceRow, let index, let raw):
            guard current.lines.indices.contains(sourceRow), current.lines[sourceRow].indices.contains(index),
                  current.lines[sourceRow][index] == raw else { return .rejected(staleMessage) }
            guard sourceRow == row || current.lines[row].count < HUDLayout.maximumItemsPerLine else {
                return .rejected(fullRowMessage)
            }
            return .layout(current.moving(from: .init(row: sourceRow, index: index), toRow: row, before: before))
        case .palette(let metric, let sourceID):
            guard HUDMetric.palette.contains(metric) else { return .rejected("这个控件不能添加到布局。") }
            if metric == .conditional {
                guard current.lines[row].count < HUDLayout.maximumItemsPerLine else { return .rejected(fullRowMessage) }
                return .conditional(row: row, index: before, sourceID: sourceID)
            }
            let raw = metric == .space ? "space:8" : HUDLayoutToken.applying(sourceID: sourceID, to: metric.rawValue)
            if metric != .space && metric != .separatorDot {
                for sourceRow in current.lines.indices {
                    if let index = current.lines[sourceRow].firstIndex(of: raw) {
                        guard sourceRow == row || current.lines[row].count < HUDLayout.maximumItemsPerLine else {
                            return .rejected(fullRowMessage)
                        }
                        return .layout(current.moving(from: .init(row: sourceRow, index: index), toRow: row, before: before))
                    }
                }
            }
            guard current.lines[row].count < HUDLayout.maximumItemsPerLine else { return .rejected(fullRowMessage) }
            var next = current.inserting(metric, row: row, sourceID: sourceID)
            next = next.moving(from: .init(row: row, index: next.lines[row].count - 1), toRow: row, before: before)
            return .layout(next)
        }
    }

    static func remove(_ payload: HUDLayoutDragPayload, context: HUDLayoutDragContext,
                       layout: HUDLayout) -> HUDLayoutDropResult {
        let current = layout.normalized
        guard payload.context == context,
              case .placed(let row, let index, let raw) = payload.source,
              current.lines.indices.contains(row), current.lines[row].indices.contains(index),
              current.lines[row][index] == raw else { return .rejected(staleMessage) }
        return .layout(current.removing(at: .init(row: row, index: index)))
    }

    static func insertConditional(_ rule: HUDConditional, id: String, sourceID: String,
                                  layout: HUDLayout, row: Int, before: Int) -> HUDLayoutDropResult {
        var next = layout.normalized
        guard next.lines.indices.contains(row), (0...next.lines[row].count).contains(before),
              UUID(uuidString: id) != nil else { return .rejected(staleMessage) }
        guard next.lines[row].count < HUDLayout.maximumItemsPerLine else { return .rejected(fullRowMessage) }
        next.conditionals[id] = rule.normalized
        next.lines[row].insert(HUDLayoutToken.applying(sourceID: sourceID, to: "conditional:" + id), at: before)
        return .layout(next.normalized)
    }
}

/// 芯片使用原生鼠标事件区分点击和拖拽，避免 SwiftUI Button 抢占拖动。
struct HUDNativeDragChip: NSViewRepresentable {
    var label: AnyView
    var accessibilityLabel: String
    var identifier: String
    var payload: () -> HUDLayoutDragPayload
    var onClick: () -> Void
    var menu: (() -> NSMenu)? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> HUDLayoutDragChipView { HUDLayoutDragChipView() }
    func updateNSView(_ view: HUDLayoutDragChipView, context: Context) {
        view.configure(label: label, accessibilityLabel: accessibilityLabel, identifier: identifier,
                       enabled: isEnabled, payload: payload, onClick: onClick, menu: menu)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HUDLayoutDragChipView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

struct HUDLayoutChipDescription {
    var id: String
    var label: AnyView
    var accessibilityLabel: String
    var payload: () -> HUDLayoutDragPayload
    var onClick: () -> Void
    var menu: () -> NSMenu
}

struct HUDNativeLayoutRow: NSViewRepresentable {
    var row: Int
    var items: [HUDLayoutChipDescription]
    var evaluate: (HUDLayoutDragPayload, Int) -> HUDLayoutDropResult
    var commit: (HUDLayoutDropResult) -> Bool
    var feedback: (String?) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> HUDLayoutRowView { HUDLayoutRowView() }
    func updateNSView(_ view: HUDLayoutRowView, context: Context) {
        view.configure(row: row, items: items, enabled: isEnabled, evaluate: evaluate, commit: commit, feedback: feedback)
    }
}

struct HUDNativeRemovalTarget: NSViewRepresentable {
    var evaluate: (HUDLayoutDragPayload) -> HUDLayoutDropResult
    var commit: (HUDLayoutDropResult) -> Bool
    var feedback: (String?) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> HUDLayoutRemovalView { HUDLayoutRemovalView() }
    func updateNSView(_ view: HUDLayoutRemovalView, context: Context) {
        view.enabled = isEnabled
        view.evaluate = evaluate
        view.commit = commit
        view.feedback = feedback
    }
}

@MainActor
final class HUDLayoutDragChipView: NSView, NSDraggingSource {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var downEvent: NSEvent?
    private var startedDrag = false
    private var dragOperation: NSDragOperation = []
    private var payload: (() -> HUDLayoutDragPayload)?
    private var clickAction: (() -> Void)?
    private var menuBuilder: (() -> NSMenu)?
    private var enabled = true

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { enabled }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize { hosting.fittingSize }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hosting.sizingOptions = [.intrinsicContentSize]
        addSubview(hosting)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { return nil }

    func configure(label: AnyView, accessibilityLabel: String, identifier: String, enabled: Bool,
                   payload: @escaping () -> HUDLayoutDragPayload, onClick: @escaping () -> Void,
                   menu: (() -> NSMenu)?) {
        hosting.rootView = label
        self.enabled = enabled
        self.payload = payload
        self.clickAction = onClick
        menuBuilder = menu
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityEnabled(enabled)
        alphaValue = enabled ? 1 : 0.45
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() { super.layout(); hosting.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        window?.makeFirstResponder(self)
        downEvent = event
        startedDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard enabled, !startedDrag, let downEvent, let payload else { return }
        let distance = hypot(event.locationInWindow.x - downEvent.locationInWindow.x,
                             event.locationInWindow.y - downEvent.locationInWindow.y)
        guard distance >= 4 else { return }
        let value = payload()
        guard let data = try? JSONEncoder().encode(value) else { return }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: HUDLayoutDragPayload.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        item.setDraggingFrame(bounds, contents: image)
        startedDrag = true
        dragOperation = value.operation
        beginDraggingSession(with: [item], event: downEvent, source: self).animatesToStartingPositionsOnCancelOrFail = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard enabled, !startedDrag, downEvent != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        clickAction?()
    }
    override func keyDown(with event: NSEvent) {
        if enabled && (event.keyCode == 49 || event.keyCode == 36) { clickAction?() }
        else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { enabled ? menuBuilder?() : nil }
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        clickAction?()
        return true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? dragOperation : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        downEvent = nil
        // mouseUp 即使随后到达，也不能把已经结束/取消的拖动当成单击。
        startedDrag = true
        dragOperation = []
    }
}

@MainActor
final class HUDLayoutRowView: NSScrollView {
    private let content = HUDLayoutDropContentView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        documentView = content
    }
    required init?(coder: NSCoder) { return nil }
    func configure(row: Int, items: [HUDLayoutChipDescription], enabled: Bool,
                   evaluate: @escaping (HUDLayoutDragPayload, Int) -> HUDLayoutDropResult,
                   commit: @escaping (HUDLayoutDropResult) -> Bool, feedback: @escaping (String?) -> Void) {
        identifier = NSUserInterfaceItemIdentifier("hud-row:\(row)")
        setAccessibilityLabel("自定义区域第 \(row + 1) 行")
        content.enabled = enabled
        content.evaluate = evaluate
        content.commit = commit
        content.feedback = feedback
        content.setItems(items)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        content.frame = NSRect(x: 0, y: 0, width: max(contentSize.width, content.requiredWidth), height: contentSize.height)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class HUDLayoutDropContentView: NSView {
    var enabled = true
    var evaluate: ((HUDLayoutDragPayload, Int) -> HUDLayoutDropResult)?
    var commit: ((HUDLayoutDropResult) -> Bool)?
    var feedback: ((String?) -> Void)?
    private var chips: [(String, HUDLayoutDragChipView)] = []
    private var insertion: Int?
    private var valid = false
    private var lastFeedback: String?
    override var isFlipped: Bool { true }
    var requiredWidth: CGFloat { chips.reduce(16) { $0 + $1.1.intrinsicContentSize.width + 5 } + 22 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([HUDLayoutDragPayload.pasteboardType])
    }
    required init?(coder: NSCoder) { return nil }
    func setItems(_ items: [HUDLayoutChipDescription]) {
        let old = Dictionary(uniqueKeysWithValues: chips)
        let ids = Set(items.map(\.id))
        for (id, view) in chips where !ids.contains(id) { view.removeFromSuperview() }
        chips = items.map { item in
            let view = old[item.id] ?? HUDLayoutDragChipView()
            view.configure(label: item.label, accessibilityLabel: item.accessibilityLabel, identifier: "hud-placed:" + item.id,
                           enabled: enabled, payload: item.payload, onClick: item.onClick, menu: item.menu)
            if view.superview == nil { addSubview(view) }
            return (item.id, view)
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        var x: CGFloat = 8
        for (_, view) in chips {
            let size = view.intrinsicContentSize
            view.frame = NSRect(x: x, y: max(2, (bounds.height - size.height) / 2), width: size.width, height: size.height)
            x += size.width + 5
        }
    }
    private func index(at point: NSPoint) -> Int { chips.firstIndex { point.x < $0.1.frame.midX } ?? chips.count }
    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard enabled, let payload = HUDLayoutDragPayload.read(from: sender.draggingPasteboard), let evaluate else {
            clear(); return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        let index = index(at: point)
        let result = evaluate(payload, index)
        insertion = index
        valid = result.rejection == nil
        if lastFeedback != result.rejection { lastFeedback = result.rejection; feedback?(result.rejection) }
        needsDisplay = true
        if let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: sender.draggingLocation, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                                         context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            _ = autoscroll(with: event)
        }
        return valid ? payload.operation : []
    }
    private func clear() { insertion = nil; valid = false; needsDisplay = true }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = update(sender)
        feedback?(lastFeedback)
        return operation
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { clear() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !update(sender).isEmpty }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { clear() }
        guard enabled, let payload = HUDLayoutDragPayload.read(from: sender.draggingPasteboard), let evaluate else { return false }
        let result = evaluate(payload, index(at: convert(sender.draggingLocation, from: nil)))
        return commit?(result) ?? false
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { clear() }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let insertion else { return }
        let x = insertion < chips.count ? chips[insertion].1.frame.minX - 3 : (chips.last?.1.frame.maxX ?? 8) + 3
        (valid ? NSColor.controlAccentColor : NSColor.systemRed).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: 8, width: 3, height: max(8, bounds.height - 16)), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

@MainActor
final class HUDLayoutRemovalView: NSView {
    var enabled = true
    var evaluate: ((HUDLayoutDragPayload) -> HUDLayoutDropResult)?
    var commit: ((HUDLayoutDropResult) -> Bool)?
    var feedback: ((String?) -> Void)?
    private var targeted = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([HUDLayoutDragPayload.pasteboardType])
        identifier = NSUserInterfaceItemIdentifier("hud-trash")
        setAccessibilityElement(true)
        setAccessibilityLabel("拖到此处移除")
    }
    required init?(coder: NSCoder) { return nil }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard enabled, let payload = HUDLayoutDragPayload.read(from: sender.draggingPasteboard),
              case .placed = payload.source, let evaluate else { return [] }
        let result = evaluate(payload)
        targeted = result.rejection == nil
        needsDisplay = true
        return targeted ? .move : []
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { targeted = false; needsDisplay = true }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !draggingUpdated(sender).isEmpty }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { targeted = false; needsDisplay = true }
        guard enabled, let payload = HUDLayoutDragPayload.read(from: sender.draggingPasteboard), let evaluate else { return false }
        let result = evaluate(payload)
        feedback?(result.rejection)
        return commit?(result) ?? false
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        (targeted ? NSColor.systemRed.withAlphaComponent(0.16) : NSColor.quaternaryLabelColor.withAlphaComponent(0.25)).setFill()
        path.fill()
        let title = "拖到此处移除" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: targeted ? NSColor.systemRed : NSColor.secondaryLabelColor]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

@MainActor
func hudLayoutMenuItem(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
    let handler = HUDLayoutMenuAction(action)
    let item = NSMenuItem(title: title, action: #selector(HUDLayoutMenuAction.invoke), keyEquivalent: "")
    item.target = handler
    item.representedObject = handler
    item.isEnabled = enabled
    return item
}

@MainActor
private final class HUDLayoutMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
