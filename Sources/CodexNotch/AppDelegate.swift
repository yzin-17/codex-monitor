import AppKit
import Combine
import QuartzCore
import SwiftUI

@main
struct CodexNotchApp {
    static func main() {
        let arguments = CommandLine.arguments
        let shouldPrintHumanSnapshot = arguments.contains("--print-snapshot") || arguments.contains("--print-fast-snapshot")
        let shouldPrintJSONSnapshot = arguments.contains("--print-snapshot-json") || arguments.contains("--print-fast-snapshot-json")
        if shouldPrintHumanSnapshot || shouldPrintJSONSnapshot {
            _ = TokenPricingUpdater.shared // Load disk prices without making a network request.
            let includePeriodUsage = !(arguments.contains("--print-fast-snapshot") || arguments.contains("--print-fast-snapshot-json"))
            let snapshot = CodexUsageStore().loadSnapshot(includePeriodUsage: includePeriodUsage)
            if shouldPrintJSONSnapshot {
                FileHandle.standardOutput.write(SnapshotOutputFormatter.jsonData(for: snapshot))
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                for line in SnapshotOutputFormatter.humanLines(for: snapshot) {
                    print(line)
                }
            }
            return
        }

        if !arguments.contains("--qa-static-preview") { TokenPricingUpdater.shared.start() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("codex监测 runs as a persistent notch overlay")
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayController: NotchOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        overlayController = NotchOverlayController()
        overlayController?.show(
            expanded: CommandLine.arguments.contains("--qa-expanded")
        )
    }

    private var shutdownRequested = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shutdownRequested else { return .terminateLater }
        shutdownRequested = true
        Task { @MainActor in
            await overlayController?.shutdownAutomation()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "codex监测")
        appMenu.addItem(withTitle: "退出 codex监测", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(editMenuItem("撤销", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(editMenuItem("重做", action: Selector(("redo:")), key: "Z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(editMenuItem("剪切", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(editMenuItem("拷贝", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(editMenuItem("粘贴", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(editMenuItem("全选", action: #selector(NSText.selectAll(_:)), key: "a"))
        editItem.submenu = editMenu

        return mainMenu
    }

    private static func editMenuItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }
}

final class TopAnchoredClippingView: NSView {
    private let hostedView: NSView
    private var targetContentSize: NSSize

    init(hostedView: NSView, contentSize: NSSize) {
        self.hostedView = hostedView
        targetContentSize = contentSize
        super.init(frame: NSRect(origin: .zero, size: contentSize))

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostedView.autoresizingMask = []
        addSubview(hostedView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func updateContentSize(_ size: NSSize) {
        targetContentSize = size
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        hostedView.frame = NSRect(
            x: (bounds.width - targetContentSize.width) / 2,
            y: bounds.maxY - targetContentSize.height,
            width: targetContentSize.width,
            height: targetContentSize.height
        )
    }
}

@MainActor
private final class InteractiveDetailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchOverlayController {
    func shutdownAutomation() async { await viewModel.shutdownExtensions() }
    private let settings = CodexNotchSettings(loadSecretsSynchronously: false)
    private lazy var viewModel = UsageViewModel(
        settings: settings,
        previewSnapshot: CommandLine.arguments.contains("--qa-static-preview")
            ? Self.visualQASnapshot()
            : nil
    )
    private lazy var remoteViewModel = RemoteMonitorViewModel(settings: settings)
    private lazy var newAPIViewModel = BalanceMonitorViewModel(source: .newAPI, settings: settings)
    private lazy var subAPIViewModel = BalanceMonitorViewModel(source: .subAPI, settings: settings)
    private lazy var codexRadarViewModel = CodexRadarViewModel(settings: settings)
    private lazy var performanceViewModel = PerformanceMonitorViewModel(settings: settings)
    private lazy var skillInsights = SkillInsightsFeatureCoordinator(settings: settings)
    private let overlayState = OverlayState()
    private var lastCompactMode: Bool?
    private var usesCompactOverlay: Bool {
        settings.hudPreferences.value.mode.usesCompactOverlay(hasNotch: (presentationScreen?.safeAreaInsets.top ?? 0) > 0)
    }
    private var presentationScreen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    private let window: NSPanel
    private let detailWindow: InteractiveDetailPanel
    private var detailContentContainer: TopAnchoredClippingView?
    private lazy var settingsController = SettingsWindowController(
        settings: settings,
        remoteViewModel: remoteViewModel,
        newAPIViewModel: newAPIViewModel,
        subAPIViewModel: subAPIViewModel,
        codexRadarViewModel: codexRadarViewModel,
        onRefresh: { [weak self] in
            self?.viewModel.refreshAll()
        }
    )
    private var cancellables: Set<AnyCancellable> = []
    private var eventMonitors: [Any] = []
    private var detailTransition = DetailTransitionState()
    private var pendingDetailWorkItems: [DispatchWorkItem] = []
    private var latestDetailExpandedFrame: NSRect?
    private var isTopShellAnimating = false
    private var systemActivityResumeTimer: Timer?

    private static let detailSettleDuration: TimeInterval = 0.12

    static func visualQASnapshot() -> UsageSnapshot {
        func usage(
            input: Int,
            cached: Int,
            output: Int,
            reasoning: Int
        ) -> TokenUsageSummary {
            let breakdown = TokenUsageBreakdown(
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output,
                reasoningOutputTokens: reasoning,
                totalTokens: input + output
            )
            var summary = TokenUsageSummary.zero
            summary.add(breakdown, model: "gpt-5.6-sol")
            return summary
        }

        let first = usage(input: 149_661, cached: 148_352, output: 943, reasoning: 512)
        let second = usage(input: 294_400, cached: 281_600, output: 7_600, reasoning: 4_900)
        let today = usage(input: 1_420_000, cached: 1_310_000, output: 68_000, reasoning: 39_000)
        var week = today
        week.add(usage(input: 4_800_000, cached: 4_300_000, output: 205_000, reasoning: 121_000))
        var month = week
        month.add(usage(input: 9_100_000, cached: 8_250_000, output: 430_000, reasoning: 245_000))
        let now = Date()

        return UsageSnapshot(
            primaryPercent: 82,
            secondaryPercent: 64,
            primaryResetsAt: now.addingTimeInterval(2 * 60 * 60),
            secondaryResetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
            usage24h: today.totalTokens,
            usage7d: week.totalTokens,
            usage30d: month.totalTokens,
            usageToday: today.totalTokens,
            usage24hSummary: today,
            usage7dSummary: week,
            usage30dSummary: month,
            usageTodaySummary: today,
            tasks: [
                CodexTask(
                    id: "qa-task-1",
                    title: "设计 Codex Token 花费估算",
                    status: .running,
                    detailPrefix: "gpt-5.6-sol · 超高推理",
                    tokenCount: first.totalTokens,
                    tokenUsage: first,
                    updatedAt: now.addingTimeInterval(-2 * 60 * 60)
                ),
                CodexTask(
                    id: "qa-task-2",
                    title: "优化监测页面交互",
                    status: .recent,
                    detailPrefix: "gpt-5.6-sol · 高推理",
                    tokenCount: second.totalTokens,
                    tokenUsage: second,
                    updatedAt: now.addingTimeInterval(-3 * 60 * 60)
                )
            ],
            isRunning: true,
            lastUpdated: now,
            errorMessage: nil
        )
    }

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: IslandMetrics.width, height: IslandMetrics.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        detailWindow = InteractiveDetailPanel(
            contentRect: NSRect(x: 0, y: 0, width: IslandMetrics.width, height: IslandMetrics.detailHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureWindow()
        configureContent()
        observeState()
        observeScreenChanges()
        observeSystemActivity()
        installEventMonitors()
        synchronizeFramesForGeometryChange()
    }

    func show(expanded: Bool = false) {
        applyPresentationMode()
        window.orderFrontRegardless()
        if expanded {
            DispatchQueue.main.async { [weak self] in
                self?.overlayState.isExpanded = true
            }
        }
    }

    private func configureWindow() {
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        detailWindow.backgroundColor = .clear
        detailWindow.isOpaque = false
        detailWindow.hasShadow = false
        detailWindow.level = .statusBar
        detailWindow.ignoresMouseEvents = false
        detailWindow.isMovableByWindowBackground = false
        detailWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }

    private func configureContent() {
        let view = NotchIslandView(
            viewModel: viewModel,
            remoteViewModel: remoteViewModel,
            newAPIViewModel: newAPIViewModel,
            subAPIViewModel: subAPIViewModel,
            overlayState: overlayState,
            settings: settings,
            onSettings: { [weak self] in
                self?.showSettings()
            },
            preferences: settings.hudPreferences,
            codexAccounts: settings.codexAccounts
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.sizingOptions = [] // 窗口几何由 HUD 决定，内容不得反向撑大菜单栏浮窗。
        hostingView.frame = NSRect(x: 0, y: 0, width: IslandMetrics.width, height: IslandMetrics.collapsedHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView

        let detailView = DetailPanelView(
            viewModel: viewModel,
            remoteViewModel: remoteViewModel,
            newAPIViewModel: newAPIViewModel,
            subAPIViewModel: subAPIViewModel,
            codexRadarViewModel: codexRadarViewModel,
            performanceViewModel: performanceViewModel,
            skillInsights: skillInsights,
            overlayState: overlayState,
            settings: settings,
            onSettings: { [weak self] in
                self?.showSettings()
            },
            onLocalRefresh: { [weak self] in
                self?.viewModel.refreshAll()
            },
            onRemoteRefresh: { [weak self] in
                self?.remoteViewModel.refreshNow()
            },
            onNewAPIRefresh: { [weak self] in
                self?.newAPIViewModel.refreshNow()
            },
            onSubAPIRefresh: { [weak self] in
                self?.subAPIViewModel.refreshNow()
            },
            onCodexRadarRefresh: { [weak self] in
                self?.codexRadarViewModel.refreshNow()
            }
        )
        let detailHostingView = NSHostingView(rootView: detailView)
        detailHostingView.sizingOptions = []
        let detailContentSize = expandedPanelLayout().frame.size
        detailHostingView.frame = NSRect(origin: .zero, size: detailContentSize)
        detailHostingView.wantsLayer = true
        detailHostingView.layer?.backgroundColor = NSColor.clear.cgColor
        let detailContentContainer = TopAnchoredClippingView(
            hostedView: detailHostingView,
            contentSize: detailContentSize
        )
        self.detailContentContainer = detailContentContainer
        detailWindow.contentView = detailContentContainer
    }

    private func observeState() {
        settings.hudPreferences.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyPresentationMode(); self?.updateFrames() }
            }.store(in: &cancellables)
        settings.codexAccounts.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateFrames() } }
            .store(in: &cancellables)
        overlayState.$isExpanded
            .removeDuplicates()
            .sink { [weak self] isExpanded in
                guard let self else {
                    return
                }
                self.setDetailVisible(isExpanded)
                if isExpanded, self.settings.showPeriodUsage {
                    self.viewModel.refreshUsageTotalsIfStale()
                } else if self.settings.showPeriodUsage {
                    self.viewModel.pausePeriodicUsageRefresh()
                } else {
                    self.viewModel.disableUsageTotals()
                }
            }
            .store(in: &cancellables)

        settings.$taskHistoryRange
            .combineLatest(settings.$showPeriodUsage, settings.$showSparkQuota)
            .sink { [weak self] _, showPeriodUsage, _ in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    if self.overlayState.isExpanded {
                        if showPeriodUsage {
                            self.viewModel.refreshUsageTotalsIfStale()
                        } else {
                            self.viewModel.disableUsageTotals()
                        }
                    } else if showPeriodUsage {
                        self.viewModel.pausePeriodicUsageRefresh()
                    } else {
                        self.viewModel.disableUsageTotals()
                    }
                    self.updateFrames()
                }
            }
            .store(in: &cancellables)

        settings.$notchWidthAdjustment
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.synchronizeFramesForGeometryChange()
                }
            }
            .store(in: &cancellables)

        settings.$notchDisplaySize
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.synchronizeFramesForGeometryChange()
                }
            }
            .store(in: &cancellables)

        viewModel.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateFrames()
                }
            }
            .store(in: &cancellables)

        remoteViewModel.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateFrames()
                }
            }
            .store(in: &cancellables)

        newAPIViewModel.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateFrames()
                }
            }
            .store(in: &cancellables)

        subAPIViewModel.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateFrames()
                }
            }
            .store(in: &cancellables)
    }

    private func observeScreenChanges() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                self.synchronizeFramesForGeometryChange()
            }
            .store(in: &cancellables)
    }

    private func observeSystemActivity() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ] {
            notificationCenter.publisher(for: name)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.scheduleSystemActivityResume()
                    }
                }
                .store(in: &cancellables)
        }
    }

    private func scheduleSystemActivityResume() {
        systemActivityResumeTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: SystemActivityRefreshCadence.debounceDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.systemActivityResumeTimer = nil
                self?.viewModel.resumeAfterSystemActivity()
            }
        }
        timer.tolerance = 0.25
        systemActivityResumeTimer = timer
    }

    private func installEventMonitors() {
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in
                self?.closeIfClickIsOutside()
            }
        }) {
            eventMonitors.append(globalMonitor)
        }

        if let localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.overlayState.isExpanded = false
                }
                return nil
            }
            if self?.shouldSuppressTextInputShortcut(event) == true {
                return nil
            }
            return event
        }) {
            eventMonitors.append(localKeyMonitor)
        }

        if let localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            Task { @MainActor in
                self?.closeIfClickIsOutside()
                self?.restorePanelOrdering()
            }
            return event
        }) {
            eventMonitors.append(localMouseMonitor)
        }
    }

    private func closeIfClickIsOutside() {
        guard overlayState.isExpanded else {
            return
        }

        let location = NSEvent.mouseLocation
        if window.frame.contains(location) || detailWindow.frame.contains(location) {
            return
        }
        overlayState.isExpanded = false
    }

    private func setDetailVisible(_ visible: Bool) {
        cancelPendingDetailWorkItems()
        guard let screen = presentationScreen else { return }
        let generation = detailTransition.begin(expanded: visible)
        let frames = detailFrames(for: screen)
        updateDetailContentSize(for: frames.expanded)
        latestDetailExpandedFrame = frames.expanded
        let animated = settings.hudPreferences.value.animation == .anchoredReveal
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if visible {
            if settings.codexRadarEnabled { codexRadarViewModel.refreshIfNeeded() }
            let wasVisible = detailWindow.isVisible
            overlayState.setDetailPresentationPhase(animated ? .revealing : .visible)
            if !wasVisible { detailWindow.setFrame(frames.collapsed, display: false) }
            detailWindow.alphaValue = 1
            presentDetailWindow()
            if animated {
                scheduleDetailWork(after: 0.04, generation: generation) { [weak self] in
                    self?.overlayState.setDetailPresentationPhase(.visible)
                }
            }
        } else {
            overlayState.setDetailPresentationPhase(.hiding)
        }
        // 窗口的宽高从 HUD 的下缘向外展开 / 原路收回，内容只裁剪不缩放。
        // 快速反向操作从当前尺寸继续，过期 completion 不得隐藏新的窗口。
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? (visible ? 0.28 : 0.20) : 0
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeInEaseOut)
            detailWindow.animator().setFrame(visible ? frames.expanded : frames.collapsed, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.detailTransition.isCurrent(generation) else { return }
                if visible {
                    _ = self.detailTransition.completeShow(generation: generation)
                    self.overlayState.setDetailPresentationPhase(.visible)
                    self.updateFrames()
                } else {
                    _ = self.detailTransition.completeHide(generation: generation)
                    self.overlayState.setDetailPresentationPhase(.hidden)
                    self.window.removeChildWindow(self.detailWindow)
                    self.detailWindow.orderOut(nil)
                }
            }
        }
    }

    private func applyPresentationMode() {
        let compact = usesCompactOverlay
        overlayState.usesCompactHUD = compact
        guard lastCompactMode != compact else { updateHUDFrame(); return }
        lastCompactMode = compact
        cancelPendingDetailWorkItems()
        overlayState.isExpanded = false
        let generation = detailTransition.begin(expanded: false)
        _ = detailTransition.completeHide(generation: generation)
        overlayState.setDetailPresentationPhase(.hidden)
        window.removeChildWindow(detailWindow); detailWindow.orderOut(nil)
        detailWindow.alphaValue = 1
        updateHUDFrame()
        window.orderFrontRegardless()
    }

    private func compactHUDFrame(on screen: NSScreen) -> NSRect {
        let data = HUDEntityData.resolve(source: settings.hudPreferences.value.sourceID, usage: viewModel,
            remote: remoteViewModel, newAPI: newAPIViewModel, subAPI: subAPIViewModel,
            accounts: settings.codexAccounts, settings: settings)
        let layoutKey = settings.hudPreferences.value.providerLayouts[settings.hudPreferences.value.sourceID] != nil ? settings.hudPreferences.value.sourceID : data.providerID
        let width = HUDMetricStrip.measuredWidth(layout: settings.hudPreferences.value.layout(for: layoutKey),
            data: data, remaining: settings.hudPreferences.value.showRemaining, menuBar: true)
        let alertWidth: CGFloat = viewModel.publicInsights.forecastAlert == nil ? 0 : 66
        return FloatingHUDGeometry.frame(screen: screen.frame, menuBarHeight: MenuBarMetrics.height(for: screen),
            contentSize: .init(width: width + alertWidth + 16 + 9 + HUDRuntimeStatus.reservedWidth, height: 20),
            maximumWidth: settings.hudPreferences.value.normalized.maximumWidth,
            position: settings.hudPreferences.value.normalized.horizontalPosition)
    }

    private func updateHUDFrame() {
        guard let screen = presentationScreen else { return }
        let frame = islandFrame(for: screen)
        guard window.frame != frame else { return }
        window.setFrame(frame, display: true, animate: false)
        window.contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func presentDetailWindow() {
        if window.childWindows?.contains(detailWindow) != true {
            window.addChildWindow(detailWindow, ordered: .below)
        }
        detailWindow.order(.below, relativeTo: window.windowNumber)
        window.orderFrontRegardless()
    }

    private func scheduleDetailWork(
        after delay: TimeInterval,
        generation: UInt,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.detailTransition.isCurrent(generation) else {
                    return
                }
                action()
            }
        }
        pendingDetailWorkItems.append(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelPendingDetailWorkItems() {
        pendingDetailWorkItems.forEach { $0.cancel() }
        pendingDetailWorkItems.removeAll()
    }

    private func restorePanelOrdering() {
        guard overlayState.isExpanded else {
            return
        }

        if window.childWindows?.contains(detailWindow) != true {
            window.addChildWindow(detailWindow, ordered: .below)
        }
        detailWindow.order(.below, relativeTo: window.windowNumber)
        window.orderFrontRegardless()
    }

    private func updateFrames() {
        updateHUDFrame()
        guard let screen = presentationScreen else {
            return
        }

        let islandFrame = islandFrame(for: screen)
        let detailFrames = detailFrames(for: screen)

        if !isTopShellAnimating {
            window.setFrame(islandFrame, display: true, animate: false)
            window.contentView?.frame = NSRect(origin: .zero, size: islandFrame.size)
        }
        latestDetailExpandedFrame = detailFrames.expanded
        switch detailTransition.phase {
        case .hidden:
            updateDetailContentSize(for: detailFrames.expanded)
            detailWindow.setFrame(detailFrames.collapsed, display: false)
        case .visible:
            updateDetailContentSize(for: detailFrames.expanded)
            detailWindow.setFrame(detailFrames.expanded, display: true)
        case .revealing, .hiding:
            break
        }
    }

    private func synchronizeFramesForGeometryChange() {
        applyPresentationMode()
        guard let screen = presentationScreen else {
            return
        }

        cancelPendingDetailWorkItems()
        isTopShellAnimating = false
        let generation = detailTransition.begin(expanded: overlayState.isExpanded)
        overlayState.setDetailPresentationPhase(overlayState.isExpanded ? .visible : .hidden)
        let frames = detailFrames(for: screen)
        let islandFrame = islandFrame(for: screen)

        window.setFrame(islandFrame, display: true, animate: false)
        window.contentView?.frame = NSRect(origin: .zero, size: islandFrame.size)
        latestDetailExpandedFrame = frames.expanded
        updateDetailContentSize(for: frames.expanded)

        if overlayState.isExpanded {
            if window.childWindows?.contains(detailWindow) != true {
                window.addChildWindow(detailWindow, ordered: .below)
            }
            detailWindow.setFrame(frames.expanded, display: true)
            detailWindow.order(.below, relativeTo: window.windowNumber)
            window.orderFrontRegardless()
            guard detailTransition.completeShow(generation: generation) else {
                return
            }
            overlayState.setDetailPresentationPhase(.visible)
        } else {
            detailWindow.setFrame(frames.collapsed, display: false)
            guard detailTransition.completeHide(generation: generation) else {
                return
            }
            overlayState.setDetailPresentationPhase(.hidden)
            window.removeChildWindow(detailWindow)
            detailWindow.orderOut(nil)
        }
    }

    private func detailFrames(
        for screen: NSScreen,
        layout: IslandLayout? = nil
    ) -> DetailWindowFrames {
        let anchor = islandFrame(for: screen)
        let expanded = FloatingHUDGeometry.panel(screen: screen.frame, visibleFrame: screen.visibleFrame, anchor: anchor).frame
        return DetailWindowFrames(collapsed: FloatingHUDGeometry.collapsedFrame(anchor: anchor, expanded: expanded), expanded: expanded)
    }

    private func updateDetailContentSize(for expandedFrame: NSRect) {
        detailContentContainer?.updateContentSize(expandedFrame.size)
    }

    private func currentIslandLayout(for screen: NSScreen? = NSScreen.main ?? NSScreen.screens.first) -> IslandLayout {
        ScreenNotchGeometry.layout(
            for: screen,
            adjustment: CGFloat(settings.notchWidthAdjustment),
            displaySize: NotchPresentationGeometry.displaySize(
                configured: settings.notchDisplaySize,
                phase: overlayState.detailPresentationPhase
            )
        )
    }

    private func islandFrame(for screen: NSScreen) -> NSRect {
        if usesCompactOverlay { return compactHUDFrame(on: screen) }
        return notchHUDFrame(on: screen, layout: currentIslandLayout(for: screen))
    }

    private func islandFrame(for screen: NSScreen, displaySize: NotchDisplaySize) -> NSRect {
        notchHUDFrame(on: screen, layout: ScreenNotchGeometry.layout(for: screen,
            adjustment: CGFloat(settings.notchWidthAdjustment), displaySize: displaySize))
    }

    private func notchHUDFrame(on screen: NSScreen, layout: IslandLayout) -> NSRect {
        let data = HUDEntityData.resolve(source: settings.hudPreferences.value.sourceID, usage: viewModel,
            remote: remoteViewModel, newAPI: newAPIViewModel, subAPI: subAPIViewModel,
            accounts: settings.codexAccounts, settings: settings)
        let layoutKey = settings.hudPreferences.value.providerLayouts[settings.hudPreferences.value.sourceID] != nil ? settings.hudPreferences.value.sourceID : data.providerID
        let needed = HUDMetricStrip.measuredWidth(layout: settings.hudPreferences.value.layout(for: layoutKey),
            data: data, remaining: settings.hudPreferences.value.showRemaining, menuBar: false) + 12
            + (viewModel.publicInsights.forecastAlert == nil ? 0 : 66)
        let right = max(layout.shoulderWidth, min(settings.hudPreferences.value.normalized.maximumWidth, needed))
        // 物理刘海仍严格居中；只向右增加自定义区域，不挤占固定状态或改变遮挡区。
        return NSRect(x: screen.frame.midX - layout.notchWidth / 2 - layout.shoulderWidth,
            y: screen.frame.maxY - layout.collapsedHeight,
            width: layout.shoulderWidth + layout.notchWidth + right, height: layout.collapsedHeight)
    }

    private func currentDetailIslandLayout(for screen: NSScreen? = NSScreen.main ?? NSScreen.screens.first) -> IslandLayout {
        ScreenNotchGeometry.layout(
            for: screen,
            adjustment: CGFloat(settings.notchWidthAdjustment),
            displaySize: .standard
        )
    }

    private func showSettings() {
        overlayState.isExpanded = false
        settingsController.show()
    }

    private func shouldSuppressTextInputShortcut(_ event: NSEvent) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSTextView else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return SettingsShortcutFilter.shouldSuppressTextInputKey(
            characters: event.characters,
            hasCommand: flags.contains(.command),
            hasControl: flags.contains(.control),
            hasOption: flags.contains(.option),
            hasShift: flags.contains(.shift)
        )
    }

    private func expandedPanelLayout(
        for screen: NSScreen? = NSScreen.main ?? NSScreen.screens.first,
        layout: IslandLayout? = nil
    ) -> ExpandedPanelLayout {
        ExpandedPanelLayout.make(
            screenFrame: screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: screen?.visibleFrame ?? .zero,
            collapsedHeight: (layout ?? currentDetailIslandLayout(for: screen)).collapsedHeight,
            overlap: IslandMetrics.detailOverlap
        )
    }

}

@MainActor
final class SettingsWindowController {
    private let settings: CodexNotchSettings
    private let remoteViewModel: RemoteMonitorViewModel
    private let newAPIViewModel: BalanceMonitorViewModel
    private let subAPIViewModel: BalanceMonitorViewModel
    private let codexRadarViewModel: CodexRadarViewModel
    private let onRefresh: () -> Void
    private var window: NSWindow?

    init(
        settings: CodexNotchSettings,
        remoteViewModel: RemoteMonitorViewModel,
        newAPIViewModel: BalanceMonitorViewModel,
        subAPIViewModel: BalanceMonitorViewModel,
        codexRadarViewModel: CodexRadarViewModel,
        onRefresh: @escaping () -> Void
    ) {
        self.settings = settings
        self.remoteViewModel = remoteViewModel
        self.newAPIViewModel = newAPIViewModel
        self.subAPIViewModel = subAPIViewModel
        self.codexRadarViewModel = codexRadarViewModel
        self.onRefresh = onRefresh
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(
            settings: settings,
            remoteViewModel: remoteViewModel,
            newAPIViewModel: newAPIViewModel,
            subAPIViewModel: subAPIViewModel,
            codexRadarViewModel: codexRadarViewModel,
            onRefresh: onRefresh
        )
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 660),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "codex监测设置"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        return window
    }
}
