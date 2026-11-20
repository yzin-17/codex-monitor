import AppKit
import Combine
import SwiftUI

/// 任务清单是 Monitor 自己的浮窗；固定后不依赖主详情窗口的可见性。
@MainActor
final class TaskProgressFloatingPanel: NSPanel {
    var closeRequested: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if attachedSheet == nil { closeRequested?() }
    }

    static func contains(_ window: NSWindow?) -> Bool {
        var current = window
        var visited = Set<ObjectIdentifier>()
        while let candidate = current, visited.insert(ObjectIdentifier(candidate)).inserted {
            if candidate is TaskProgressFloatingPanel { return true }
            current = candidate.parent ?? candidate.sheetParent
        }
        return false
    }
}

@MainActor
final class TaskProgressPanelPresenter: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var isPinned = false
    weak var anchor: NSView?
    private(set) var panel: TaskProgressFloatingPanel?
    private weak var parentWindow: NSWindow?
    private var store: TaskProgressStore?
    private var threadID: String?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var parentObserver: NSObjectProtocol?
    // 行被列表更新移除后，已经固定的浮窗仍能操作并正确释放观察。
    private static var openPresenters: [ObjectIdentifier: TaskProgressPanelPresenter] = [:]

    func toggle(store: TaskProgressStore, threadID: String) {
        if isPresented { close(); return }
        show(store: store, threadID: threadID)
    }

    func show(store: TaskProgressStore, threadID: String) {
        guard panel == nil, let anchor, let owner = anchor.window else { return }
        for other in Array(Self.openPresenters.values) where !other.isPinned { other.close() }
        let anchorRect = owner.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = owner.screen ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = NSSize(width: min(460, available.width - 24), height: min(560, available.height - 24))
        let frame = Self.anchoredFrame(anchor: anchorRect, size: size, visibleFrame: available)
        let window = TaskProgressFloatingPanel(contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = NSWindow.Level(rawValue: max(owner.level.rawValue + 1, NSWindow.Level.floating.rawValue))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.animationBehavior = .none
        window.title = "任务清单"
        window.identifier = NSUserInterfaceItemIdentifier("task-progress-\(threadID)")
        window.closeRequested = { [weak self] in self?.close() }
        let root = TaskProgressFloatingContent(presenter: self, store: store, threadID: threadID, size: size)
        window.contentView = NSHostingView(rootView: root.preferredColorScheme(.dark))
        self.store = store
        self.threadID = threadID
        self.panel = window
        self.parentWindow = owner
        isPinned = false
        isPresented = true
        Self.openPresenters[ObjectIdentifier(self)] = self
        store.retainPanel(threadID: threadID)
        owner.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        installMonitors()
        parentObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
            object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isPinned, self.parentWindow?.isVisible == false else { return }
                    self.close()
                }
            }
    }

    func setPinned(_ pinned: Bool) {
        guard let panel, isPinned != pinned else { return }
        isPinned = pinned
        if pinned {
            panel.parent?.removeChildWindow(panel)
            panel.orderFrontRegardless()
        } else if let parentWindow, parentWindow.isVisible {
            parentWindow.addChildWindow(panel, ordered: .above)
            panel.orderFrontRegardless()
        }
    }

    func closeIfUnpinned() { if !isPinned { close() } }

    func close() {
        guard let panel else { return }
        isPresented = false
        isPinned = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) }
        localMonitor = nil; globalMonitor = nil; parentObserver = nil
        panel.parent?.removeChildWindow(panel)
        panel.closeRequested = nil
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        self.panel = nil
        if let store, let threadID { store.releasePanel(threadID: threadID) }
        store = nil; threadID = nil; parentWindow = nil
        Self.openPresenters.removeValue(forKey: ObjectIdentifier(self))
    }

    static func anchoredFrame(anchor: NSRect, size: NSSize, visibleFrame: NSRect) -> NSRect {
        let margin: CGFloat = 12
        let x = min(max(anchor.maxX - size.width, visibleFrame.minX + margin), visibleFrame.maxX - size.width - margin)
        let below = anchor.minY - size.height - 8
        let desiredY = below >= visibleFrame.minY + margin ? below : anchor.maxY + 8
        let y = min(max(desiredY, visibleFrame.minY + margin), visibleFrame.maxY - size.height - margin)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.isPinned, let panel = self.panel,
                      NSApp.modalWindow == nil, panel.attachedSheet == nil else { return }
                if Self.belongs(event.window, to: panel) { return }
                if let anchor = self.anchor, event.window === anchor.window,
                   anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return }
                self.close()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPinned, NSApp.modalWindow == nil else { return }
                self.close()
            }
        }
    }

    private static func belongs(_ window: NSWindow?, to owner: NSWindow) -> Bool {
        var current = window
        var visited = Set<ObjectIdentifier>()
        while let candidate = current, visited.insert(ObjectIdentifier(candidate)).inserted {
            if candidate === owner { return true }
            current = candidate.parent ?? candidate.sheetParent
        }
        return false
    }
}

private struct TaskProgressFloatingContent: View {
    @ObservedObject var presenter: TaskProgressPanelPresenter
    let store: TaskProgressStore
    let threadID: String
    let size: NSSize
    var body: some View {
        TaskProgressPanel(store: store, threadID: threadID,
            pinned: Binding(get: { presenter.isPinned }, set: { presenter.setPinned($0) }),
            panelSize: size, managesRetention: false, close: { presenter.close() })
    }
}

struct TaskProgressAnchor: NSViewRepresentable {
    let presenter: TaskProgressPanelPresenter
    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        presenter.anchor = view
        return view
    }
    func updateNSView(_ nsView: AnchorView, context: Context) { presenter.anchor = nsView }
    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct TaskProgressWindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("移动进度浮窗")
            setAccessibilityHelp("拖动标题栏，或聚焦后使用方向键移动；Shift 加速")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            window?.performDrag(with: event)
            constrainToScreen()
        }
        override func keyDown(with event: NSEvent) {
            guard let window else { return }
            let delta: CGFloat = event.modifierFlags.contains(.shift) ? 20 : 5
            var point = window.frame.origin
            switch event.keyCode {
            case 123: point.x -= delta
            case 124: point.x += delta
            case 125: point.y -= delta
            case 126: point.y += delta
            default: super.keyDown(with: event); return
            }
            window.setFrameOrigin(point)
            constrainToScreen()
        }
        private func constrainToScreen() {
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            window.setFrameOrigin(NSPoint(
                x: min(max(window.frame.minX, visible.minX), visible.maxX - window.frame.width),
                y: min(max(window.frame.minY, visible.minY), visible.maxY - window.frame.height)))
        }
    }
}
