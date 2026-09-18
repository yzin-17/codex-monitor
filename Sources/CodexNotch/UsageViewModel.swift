import Combine
import Foundation

enum ConversationCostPrefetchPolicy {
    static let maximumTaskCount = 3

    static func prioritizedTasks(from tasks: [CodexTask]) -> [CodexTask] {
        tasks
            .filter { $0.status == .running || $0.status == .recent }
            .sorted {
                let leftPriority = $0.status == .running ? 0 : 1
                let rightPriority = $1.status == .running ? 0 : 1
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
            .prefix(maximumTaskCount)
            .map { $0 }
    }
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingUsage = false
    @Published private(set) var hasLoadedUsageTotals = false
    @Published private(set) var conversationCostDetails: [String: ConversationCostDetails] = [:]
    @Published private(set) var conversationCostLoadingKeys: Set<String> = []
    @Published private(set) var conversationCostErrors: [String: String] = [:]

    lazy var publicInsights = PublicInsightsStore(defaults: settings.preferenceStore, automatic: !isPreviewMode)
    lazy var cliResume = CLIResumeStore(home: store.conversationDataDirectory,
        defaults: settings.preferenceStore, automatic: !isPreviewMode,
        activeThreads: { [weak self] in Set(self?.snapshot.tasks.filter { $0.status == .running }.map(\.id) ?? []) })

    func shutdownExtensions() async {
        cancelConversationCostWork(clearDetails: false)
        publicInsights.stop()
        await cliResume.shutdown()
    }

    private let store: CodexUsageStore
    private let settings: CodexNotchSettings
    private let isPreviewMode: Bool
    private var conversationCostSkillsEnabled = true
    private var fastTimer: Timer?
    private var usageTimer: Timer?
    private var pendingSnapshotTimer: Timer?
    private var pendingUsageTimer: Timer?
    private var watcherRefreshTimer: Timer?
    private var settingsChangeTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var completionFollowUpTimers: [Timer] = []
    private var completionUsageRefreshTimer: Timer?
    private var fileChangeRefreshTimer: Timer?
    private var usageFileChangeTimer: Timer?
    private var fileWatchers: [CodexFileWatcher] = []
    private var watchedPaths: [String] = []
    private var isRefreshingSnapshot = false
    private var isRefreshingWatchPaths = false
    private var pendingSnapshotRefresh = false
    private var pendingSnapshotBypassFastCache = false
    private var pendingWatchPathsRefresh = false
    private var fileChangeBurstStartedAt: Date?
    private var fileChangeNeedsWatchPathRefresh = false
    private var lastUsageRefreshDuration: TimeInterval?
    private var periodUsageRefreshEnabled = false
    private var usageRefreshQueue = UsageRefreshQueue()
    private var usageRefreshTask: Task<Void, Never>?
    private var usageRefreshGeneration = 0
    private var usageLoadState = PeriodUsageLoadState()
    private var watcherRefreshGeneration = 0
    private var observedSettings: LocalUsageSettingsSnapshot?
    private struct ConversationCostLoaderCacheEntry {
        let loader: ConversationCostLoader
        var lastUsed: Date
    }
    private var conversationCostLoaders: [String: ConversationCostLoaderCacheEntry] = [:]
    private struct ConversationCostTaskMarker: Equatable, Sendable {
        let updatedAt: Date
        let tokenCount: Int
        let activeSubagentCount: Int

        init(task: CodexTask) {
            updatedAt = task.updatedAt
            tokenCount = task.tokenCount
            activeSubagentCount = task.activeSubagentCount
        }
    }
    private struct ConversationCostRequest {
        let taskID: String
        let skillsEnabled: Bool
        let taskMarker: ConversationCostTaskMarker?
        var isManual: Bool

        var key: String {
            Self.key(taskID: taskID, skillsEnabled: skillsEnabled)
        }

        static func key(taskID: String, skillsEnabled: Bool) -> String {
            "\(taskID.lowercased())|\(skillsEnabled ? "skills" : "plain")"
        }
    }
    private var conversationCostQueue: [ConversationCostRequest] = []
    private var conversationCostActiveKey: String?
    private var conversationCostWorker: Task<Void, Never>?
    private var conversationCostGeneration = 0
    private var conversationCostTaskMarkers: [String: ConversationCostTaskMarker] = [:]

    init(
        store: CodexUsageStore = CodexUsageStore(),
        settings: CodexNotchSettings = CodexNotchSettings(),
        previewSnapshot: UsageSnapshot? = nil
    ) {
        self.store = store
        self.settings = settings
        isPreviewMode = previewSnapshot != nil
        conversationCostSkillsEnabled = settings.skillInsightsEnabled
        if let previewSnapshot {
            snapshot = previewSnapshot
            hasLoadedUsageTotals = true
            return
        }
        refresh(bypassFastCache: true)
        refreshWatchPaths()
        observeSettings()
        NotificationCenter.default.publisher(for: .tokenPricingDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 恢复已经明确启用的检查，不依赖用户打开某个页面。
        _ = publicInsights
        _ = cliResume
    }

    func makeConversationCostLoader(taskID: String? = nil, skillsEnabled: Bool = true) -> ConversationCostLoader? {
        guard !isPreviewMode else { return nil }
        guard let taskID else {
            return ConversationCostLoader(codexHome: store.conversationDataDirectory)
        }
        let key = taskID.lowercased() + "|" + (skillsEnabled ? "skills" : "plain")
        if var entry = conversationCostLoaders[key] {
            entry.lastUsed = Date()
            conversationCostLoaders[key] = entry
            return entry.loader
        }
        let loader = ConversationCostLoader(codexHome: store.conversationDataDirectory)
        conversationCostLoaders[key] = ConversationCostLoaderCacheEntry(loader: loader, lastUsed: Date())
        if conversationCostLoaders.count > 8,
           let oldest = conversationCostLoaders.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            conversationCostLoaders.removeValue(forKey: oldest)
            conversationCostDetails.removeValue(forKey: oldest)
            conversationCostErrors.removeValue(forKey: oldest)
            conversationCostTaskMarkers.removeValue(forKey: oldest)
        }
        return loader
    }

    func conversationCostDetail(for taskID: String, skillsEnabled: Bool) -> ConversationCostDetails? {
        let key = ConversationCostRequest.key(taskID: taskID, skillsEnabled: skillsEnabled)
        return conversationCostDetails[key]
    }

    func isConversationCostLoading(for taskID: String, skillsEnabled: Bool) -> Bool {
        let key = ConversationCostRequest.key(taskID: taskID, skillsEnabled: skillsEnabled)
        return conversationCostLoadingKeys.contains(key)
    }

    func conversationCostError(for taskID: String, skillsEnabled: Bool) -> String? {
        let key = ConversationCostRequest.key(taskID: taskID, skillsEnabled: skillsEnabled)
        return conversationCostErrors[key]
    }

    func conversationCostDisplaySummary(for task: CodexTask,
                                        skillsEnabled: Bool) -> ConversationCostDisplaySummary {
        guard let detail = conversationCostDetail(for: task.id, skillsEnabled: skillsEnabled),
              let confidence = detail.reconciledDisplayConfidence else {
            return ConversationCostDisplaySummary(usage: task.tokenUsage, confidence: .provisional)
        }
        return ConversationCostDisplaySummary(usage: detail.usage, confidence: confidence)
    }

    func prefetchConversationCosts(for tasks: [CodexTask]) {
        guard !isPreviewMode else { return }
        let candidates = ConversationCostPrefetchPolicy.prioritizedTasks(from: tasks)
        let desiredKeys = Set(candidates.map {
            ConversationCostRequest.key(taskID: $0.id, skillsEnabled: settings.skillInsightsEnabled)
        })
        conversationCostQueue.removeAll { request in
            !request.isManual && !desiredKeys.contains(request.key)
        }

        for task in candidates {
            let key = ConversationCostRequest.key(taskID: task.id, skillsEnabled: settings.skillInsightsEnabled)
            guard shouldPrefetch(task: task, key: key) else { continue }
            enqueueConversationCost(
                taskID: task.id,
                skillsEnabled: settings.skillInsightsEnabled,
                taskMarker: ConversationCostTaskMarker(task: task),
                isManual: false
            )
        }
        pumpConversationCostQueue()
    }

    func requestConversationCostDetail(for taskID: String, skillsEnabled: Bool) {
        guard !isPreviewMode else { return }
        let key = ConversationCostRequest.key(taskID: taskID, skillsEnabled: skillsEnabled)
        if let detail = conversationCostDetails[key],
           !detail.pending || detail.scanState.isWaitingForAppend {
            return
        }
        enqueueConversationCost(taskID: taskID, skillsEnabled: skillsEnabled,
            taskMarker: taskMarker(for: taskID), isManual: true)
        pumpConversationCostQueue()
    }

    func refreshConversationCostDetail(for taskID: String, skillsEnabled: Bool) {
        guard !isPreviewMode else { return }
        enqueueConversationCost(taskID: taskID, skillsEnabled: skillsEnabled,
            taskMarker: taskMarker(for: taskID), isManual: true)
        pumpConversationCostQueue()
    }

    func cancelConversationCostPrefetch() {
        guard !isPreviewMode else { return }
        cancelConversationCostWork(clearDetails: false)
    }

    private func taskMarker(for taskID: String) -> ConversationCostTaskMarker? {
        snapshot.tasks.first { $0.id.caseInsensitiveCompare(taskID) == .orderedSame }
            .map(ConversationCostTaskMarker.init(task:))
    }

    private func shouldPrefetch(task: CodexTask, key: String) -> Bool {
        guard let detail = conversationCostDetails[key] else { return true }
        if detail.pending { return true }
        return conversationCostTaskMarkers[key] != ConversationCostTaskMarker(task: task)
    }

    private func enqueueConversationCost(taskID: String, skillsEnabled: Bool,
                                         taskMarker: ConversationCostTaskMarker?,
                                         isManual: Bool) {
        let key = ConversationCostRequest.key(taskID: taskID, skillsEnabled: skillsEnabled)
        conversationCostErrors.removeValue(forKey: key)
        guard conversationCostActiveKey != key else { return }

        if let index = conversationCostQueue.firstIndex(where: { $0.key == key }) {
            if let taskMarker {
                conversationCostQueue[index] = ConversationCostRequest(
                    taskID: conversationCostQueue[index].taskID,
                    skillsEnabled: conversationCostQueue[index].skillsEnabled,
                    taskMarker: taskMarker,
                    isManual: conversationCostQueue[index].isManual || isManual
                )
            }
            conversationCostQueue[index].isManual = conversationCostQueue[index].isManual || isManual
            if isManual && index > 0 {
                let request = conversationCostQueue.remove(at: index)
                conversationCostQueue.insert(request, at: 0)
            }
        } else {
            let request = ConversationCostRequest(
                taskID: taskID.lowercased(), skillsEnabled: skillsEnabled,
                taskMarker: taskMarker,
                isManual: isManual
            )
            if isManual {
                conversationCostQueue.insert(request, at: 0)
            } else {
                conversationCostQueue.append(request)
            }
        }
    }

    private func pumpConversationCostQueue() {
        guard !isPreviewMode, conversationCostWorker == nil,
              !conversationCostQueue.isEmpty else { return }
        let request = conversationCostQueue.removeFirst()
        let key = request.key
        conversationCostActiveKey = key
        conversationCostLoadingKeys = conversationCostLoadingKeys.union([key])
        conversationCostErrors.removeValue(forKey: key)
        let generation = conversationCostGeneration
        guard let loader = makeConversationCostLoader(taskID: request.taskID,
                                                       skillsEnabled: request.skillsEnabled) else {
            finishConversationCostRequest(key: key, generation: generation)
            return
        }
        let worker = Task { [weak self, loader] in
            guard let self else { return }
            await self.runConversationCostScan(request, loader: loader, generation: generation)
        }
        conversationCostWorker = worker
    }

    private func runConversationCostScan(_ request: ConversationCostRequest,
                                         loader: ConversationCostLoader,
                                         generation: Int) async {
        do {
            while !Task.isCancelled {
                let slice = Task.detached(priority: .utility) {
                    try loader.load(
                        rootID: request.taskID,
                        includeSkills: request.skillsEnabled,
                        shouldCancel: { Task.isCancelled }
                    )
                }
                let next = try await withTaskCancellationHandler(
                    operation: { try await slice.value },
                    onCancel: { slice.cancel() }
                )
                guard generation == conversationCostGeneration else { return }
                var details = conversationCostDetails
                details[request.key] = next
                conversationCostDetails = details
                if let taskMarker = request.taskMarker {
                    conversationCostTaskMarkers[request.key] = taskMarker
                }
                conversationCostErrors.removeValue(forKey: request.key)

                // EOF with a partial row is a stable observation point. Release
                // the serial worker and let the next snapshot or manual refresh
                // retry after the file has actually changed.
                if !next.pending || next.scanState.isWaitingForAppend { break }
                await Task.yield()
            }
        } catch is CancellationError {
            // Cancellation is expected when the candidate set or settings change.
        } catch {
            if generation == conversationCostGeneration {
                var errors = conversationCostErrors
                errors[request.key] = "读取失败；未将缺失数据当作零费用。"
                conversationCostErrors = errors
            }
        }
        finishConversationCostRequest(key: request.key, generation: generation)
    }

    private func finishConversationCostRequest(key: String, generation: Int) {
        guard generation == conversationCostGeneration else { return }
        conversationCostLoadingKeys.remove(key)
        conversationCostActiveKey = nil
        conversationCostWorker = nil
        pumpConversationCostQueue()
    }

    private func cancelConversationCostWork(clearDetails: Bool) {
        conversationCostGeneration += 1
        conversationCostWorker?.cancel()
        conversationCostWorker = nil
        conversationCostActiveKey = nil
        conversationCostQueue.removeAll()
        conversationCostLoadingKeys.removeAll()
        if clearDetails {
            conversationCostDetails.removeAll()
            conversationCostErrors.removeAll()
            conversationCostTaskMarkers.removeAll()
            conversationCostLoaders.removeAll()
        }
    }

    func refresh(bypassFastCache: Bool = false) {
        guard !isPreviewMode else {
            return
        }
        guard !isRefreshingSnapshot else {
            pendingSnapshotRefresh = true
            pendingSnapshotBypassFastCache = pendingSnapshotBypassFastCache || bypassFastCache
            return
        }
        fastTimer?.invalidate()
        fastTimer = nil
        pendingSnapshotTimer?.invalidate()
        pendingSnapshotTimer = nil
        isRefreshingSnapshot = true
        updateRefreshingState()
        let fallbackUsage = currentUsage
        let rateLimitSource = settings.rateLimitSource
        let taskHistoryRange = settings.taskHistoryRange

        Task.detached(priority: .utility) { [store, fallbackUsage, bypassFastCache, rateLimitSource, taskHistoryRange] in
            let nextSnapshot = store.loadSnapshot(
                includePeriodUsage: false,
                fallbackUsage: fallbackUsage,
                bypassFastCache: bypassFastCache,
                rateLimitSource: rateLimitSource,
                taskHistoryRange: taskHistoryRange
            )
            await MainActor.run {
                let snapshotLoadSucceeded = nextSnapshot.errorMessage == nil
                let previousTasks = self.snapshot.tasks
                var mergedSnapshot = self.stabilizedSnapshot(nextSnapshot)
                mergedSnapshot.usage24h = self.snapshot.usage24h
                mergedSnapshot.usage7d = self.snapshot.usage7d
                mergedSnapshot.usage30d = self.snapshot.usage30d
                mergedSnapshot.usageToday = self.snapshot.usageToday
                self.snapshot = mergedSnapshot
                if snapshotLoadSucceeded {
                    self.prefetchConversationCosts(for: self.snapshot.tasks)
                }
                self.isRefreshingSnapshot = false
                self.updateRefreshingState()
                let shouldRefreshAgain = self.pendingSnapshotRefresh
                let shouldBypassFastCache = self.pendingSnapshotBypassFastCache
                self.pendingSnapshotRefresh = false
                self.pendingSnapshotBypassFastCache = false
                if snapshotLoadSucceeded,
                   !TaskCompletionDetector.completedRunningTaskIDs(
                    previous: previousTasks,
                    current: self.snapshot.tasks
                ).isEmpty {
                    self.scheduleCompletionFollowUp()
                    self.scheduleCompletionUsageRefresh()
                }
                if shouldRefreshAgain {
                    self.schedulePendingSnapshotRefresh(bypassFastCache: shouldBypassFastCache)
                } else {
                    self.scheduleFastRefresh()
                }
            }
        }
    }

    func refreshAll() {
        guard !isPreviewMode else {
            return
        }
        refresh(bypassFastCache: true)
        refreshUsageTotals(scheduleNext: periodUsageRefreshEnabled)
    }

    func resumeAfterSystemActivity() {
        publicInsights.refreshIfNeeded()
        TokenPricingUpdater.shared.refreshIfDue()
        fastTimer?.invalidate()
        fastTimer = nil
        pendingSnapshotTimer?.invalidate()
        pendingSnapshotTimer = nil
        refresh(bypassFastCache: true)
        refreshWatchPaths()
        if periodUsageRefreshEnabled {
            refreshUsageTotals(scheduleNext: true)
        }
    }

    func refreshUsageTotalsIfStale(maxAge: TimeInterval = 120) {
        guard !isPreviewMode else {
            return
        }
        guard settings.showPeriodUsage else {
            disableUsageTotals()
            return
        }
        periodUsageRefreshEnabled = true
        let now = Date()
        let shouldRefresh = usageLoadState.lastSuccessfulAt.map { now.timeIntervalSince($0) >= maxAge } ?? true
        if shouldRefresh {
            refreshUsageTotals(scheduleNext: true)
        } else {
            scheduleUsageRefresh()
        }
    }

    func pausePeriodicUsageRefresh() {
        periodUsageRefreshEnabled = false
        usageTimer?.invalidate()
        usageTimer = nil
        usageFileChangeTimer?.invalidate()
        usageFileChangeTimer = nil
        usageRefreshQueue.cancelPending()
        usageRefreshGeneration += 1
        usageRefreshTask?.cancel()
    }

    func disableUsageTotals() {
        pausePeriodicUsageRefresh()
        pendingUsageTimer?.invalidate()
        pendingUsageTimer = nil
        completionUsageRefreshTimer?.invalidate()
        completionUsageRefreshTimer = nil
        usageRefreshQueue.cancelPending()
    }

    private func refreshUsageTotals(scheduleNext: Bool? = nil) {
        guard settings.showPeriodUsage else {
            disableUsageTotals()
            return
        }
        let shouldScheduleNext = scheduleNext ?? periodUsageRefreshEnabled
        guard usageRefreshQueue.request(scheduleNext: shouldScheduleNext) else {
            return
        }
        usageTimer?.invalidate()
        usageTimer = nil
        pendingUsageTimer?.invalidate()
        pendingUsageTimer = nil
        isRefreshingUsage = true
        updateRefreshingState()

        let refreshStartedAt = Date()
        usageRefreshGeneration += 1
        let generation = usageRefreshGeneration
        let task = Task.detached(priority: .utility) { [store] in
            let cancellationCheck: @Sendable () -> Bool = {
                withUnsafeCurrentTask { $0?.isCancelled ?? false }
            }
            let usage = store.loadUsageTotals(isCancelled: cancellationCheck)
            let taskWasCancelled = cancellationCheck()
            let duration = Date().timeIntervalSince(refreshStartedAt)
            await MainActor.run {
                let wasCancelled = taskWasCancelled || generation != self.usageRefreshGeneration
                self.usageRefreshTask = nil
                self.lastUsageRefreshDuration = duration
                let completion = self.usageRefreshQueue.complete()
                self.isRefreshingUsage = false
                self.updateRefreshingState()
                if wasCancelled {
                    if case .schedulePending(let scheduleNext) = completion,
                       self.settings.showPeriodUsage,
                       self.periodUsageRefreshEnabled {
                        self.schedulePendingUsageRefresh(
                            scheduleNext: scheduleNext,
                            delay: 0.1
                        )
                    }
                    return
                }

                let completedAt = Date()
                let succeeded = self.usageLoadState.record(
                    usage,
                    completedAt: completedAt
                )
                if let usage {
                    self.snapshot.usage24h = usage.day
                    self.snapshot.usage7d = usage.week
                    self.snapshot.usage30d = usage.month
                    self.snapshot.usageToday = usage.today
                    self.snapshot.usage24hSummary = usage.daySummary
                    self.snapshot.usage7dSummary = usage.weekSummary
                    self.snapshot.usage30dSummary = usage.monthSummary
                    self.snapshot.usageTodaySummary = usage.todaySummary
                }
                self.hasLoadedUsageTotals = self.usageLoadState.hasSuccessfulValue
                switch completion {
                case .schedulePending(let scheduleNext):
                    let delay = succeeded
                        ? RefreshCadence.pendingUsageDelay(for: self.settings.usageRefreshInterval)
                        : UsageRefreshCadence.failureRetryDelay(
                            consecutiveFailures: self.usageLoadState.consecutiveFailures
                        )
                    self.schedulePendingUsageRefresh(
                        scheduleNext: scheduleNext,
                        delay: delay
                    )
                case .finished(let scheduleNext):
                    if !succeeded,
                       self.usageLoadState.consecutiveFailures <= UsageRefreshCadence.maximumFailureRetries,
                       self.settings.showPeriodUsage {
                        self.schedulePendingUsageRefresh(
                            scheduleNext: scheduleNext,
                            delay: UsageRefreshCadence.failureRetryDelay(
                                consecutiveFailures: self.usageLoadState.consecutiveFailures
                            )
                        )
                    } else if scheduleNext && self.periodUsageRefreshEnabled {
                        self.scheduleUsageRefresh()
                    }
                }
            }
        }
        usageRefreshTask = task
    }

    private func scheduleFastRefresh() {
        let interval = snapshot.isRunning ? settings.activeRefreshInterval : settings.idleRefreshInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer.tolerance = interval * 0.35
        fastTimer = timer
    }

    private func schedulePendingSnapshotRefresh(bypassFastCache: Bool) {
        fastTimer?.invalidate()
        fastTimer = nil
        pendingSnapshotTimer?.invalidate()

        let interval = snapshot.isRunning ? settings.activeRefreshInterval : settings.idleRefreshInterval
        let delay = RefreshCadence.pendingSnapshotDelay(for: interval)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.pendingSnapshotTimer = nil
                self?.refresh(bypassFastCache: bypassFastCache)
            }
        }
        timer.tolerance = min(1, delay * 0.35)
        pendingSnapshotTimer = timer
    }

    private func scheduleUsageRefresh() {
        usageTimer?.invalidate()
        let interval = UsageRefreshCadence.refreshInterval(
            configured: settings.usageRefreshInterval,
            lastDuration: lastUsageRefreshDuration
        )
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUsageTotals()
            }
        }
        timer.tolerance = min(60, interval * 0.2)
        usageTimer = timer
    }

    private func schedulePendingUsageRefresh(
        scheduleNext: Bool,
        delay: TimeInterval
    ) {
        usageTimer?.invalidate()
        usageTimer = nil
        pendingUsageTimer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.pendingUsageTimer = nil
                self?.refreshUsageTotals(scheduleNext: scheduleNext)
            }
        }
        timer.tolerance = min(5, delay * 0.35)
        pendingUsageTimer = timer
    }

    private func scheduleWatcherRefresh() {
        watcherRefreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: settings.watcherRefreshInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshWatchPaths()
            }
        }
        timer.tolerance = 3
        watcherRefreshTimer = timer
    }

    private func scheduleCompletionFollowUp() {
        completionFollowUpTimers.forEach { $0.invalidate() }
        completionFollowUpTimers = [2, 6].map { delay in
            let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delay), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh(bypassFastCache: true)
                }
            }
            timer.tolerance = 1
            return timer
        }
    }

    private func scheduleCompletionUsageRefresh() {
        guard settings.showPeriodUsage else {
            return
        }
        completionUsageRefreshTimer?.invalidate()

        let delay = UsageRefreshCadence.fileChangeDelay(
            now: Date(),
            lastCompletedAt: usageLoadState.lastSuccessfulAt
        )
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.completionUsageRefreshTimer = nil
                self.refreshUsageTotals(scheduleNext: self.periodUsageRefreshEnabled)
            }
        }
        timer.tolerance = min(2, delay * 0.2)
        completionUsageRefreshTimer = timer
    }

    private func refreshWatchPaths() {
        guard !isRefreshingWatchPaths else {
            pendingWatchPathsRefresh = true
            return
        }
        isRefreshingWatchPaths = true
        watcherRefreshGeneration += 1
        let generation = watcherRefreshGeneration
        Task.detached(priority: .utility) { [store] in
            let paths = store.rateLimitWatchPaths()
            await MainActor.run {
                guard generation == self.watcherRefreshGeneration else {
                    return
                }
                self.isRefreshingWatchPaths = false
                self.installFileWatchers(for: paths)
                let shouldRefreshAgain = self.pendingWatchPathsRefresh
                self.pendingWatchPathsRefresh = false
                if shouldRefreshAgain {
                    self.refreshWatchPaths()
                } else {
                    self.scheduleWatcherRefresh()
                }
            }
        }
    }

    private func installFileWatchers(for paths: [String]) {
        let normalizedPaths = Array(Set(paths.filter { !$0.isEmpty })).sorted()
        guard normalizedPaths != watchedPaths else {
            return
        }

        fileWatchers.forEach { $0.cancel() }
        fileWatchers.removeAll()

        var installedPaths: [String] = []
        var installedWatchers: [CodexFileWatcher] = []

        for path in normalizedPaths {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            let refreshWatchPaths = isDirectory.boolValue
            guard let watcher = CodexFileWatcher(path: path, onChange: { [weak self] in
                Task { @MainActor in
                    self?.scheduleFileChangeRefresh(refreshWatchPaths: refreshWatchPaths)
                }
            }) else {
                continue
            }
            installedPaths.append(path)
            installedWatchers.append(watcher)
        }

        watchedPaths = installedPaths
        fileWatchers = installedWatchers
    }

    private func scheduleFileChangeRefresh(refreshWatchPaths: Bool) {
        let now = Date()
        let burstStartedAt = fileChangeBurstStartedAt ?? now
        fileChangeBurstStartedAt = burstStartedAt
        fileChangeNeedsWatchPathRefresh = fileChangeNeedsWatchPathRefresh || refreshWatchPaths

        let fireDate = FileChangeRefreshCadence.fireDate(
            now: now,
            burstStartedAt: burstStartedAt,
            maximumDelay: settings.fileChangeRefreshMinimumGap
        )
        let delay = max(0.05, fireDate.timeIntervalSince(now))

        fileChangeRefreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.fileChangeRefreshTimer = nil
                self.fileChangeBurstStartedAt = nil
                let shouldRefreshWatchPaths = self.fileChangeNeedsWatchPathRefresh
                self.fileChangeNeedsWatchPathRefresh = false
                self.refresh(bypassFastCache: true)
                if shouldRefreshWatchPaths {
                    self.refreshWatchPaths()
                }
            }
        }
        timer.tolerance = min(0.25, delay * 0.2)
        fileChangeRefreshTimer = timer
        scheduleUsageRefreshAfterFileChange(now: now)
    }

    private func scheduleUsageRefreshAfterFileChange(now: Date) {
        guard periodUsageRefreshEnabled, usageFileChangeTimer == nil else {
            return
        }

        let delay = UsageRefreshCadence.fileChangeDelay(
            now: now,
            lastCompletedAt: usageLoadState.lastSuccessfulAt
        )
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.usageFileChangeTimer = nil
                guard self.periodUsageRefreshEnabled else {
                    return
                }
                self.refreshUsageTotals(scheduleNext: true)
            }
        }
        timer.tolerance = min(2, delay * 0.2)
        usageFileChangeTimer = timer
    }

    private func observeSettings() {
        observedSettings = LocalUsageSettingsSnapshot(settings: settings)
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    Task { @MainActor in
                        self?.settingsMayHaveChanged()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func settingsMayHaveChanged() {
        let next = LocalUsageSettingsSnapshot(settings: settings)
        guard next != observedSettings else {
            return
        }
        observedSettings = next
        scheduleSettingsRefresh()
    }

    private func scheduleSettingsRefresh() {
        settingsChangeTimer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.settingsDidChange()
            }
        }
        timer.tolerance = 0.15
        settingsChangeTimer = timer
    }

    private func settingsDidChange() {
        let skillsChanged = conversationCostSkillsEnabled != settings.skillInsightsEnabled
        conversationCostSkillsEnabled = settings.skillInsightsEnabled
        if skillsChanged {
            cancelConversationCostWork(clearDetails: true)
        }
        settingsChangeTimer?.invalidate()
        settingsChangeTimer = nil
        fastTimer?.invalidate()
        fastTimer = nil
        usageTimer?.invalidate()
        usageTimer = nil
        pendingSnapshotTimer?.invalidate()
        pendingSnapshotTimer = nil
        usageFileChangeTimer?.invalidate()
        usageFileChangeTimer = nil
        fileChangeRefreshTimer?.invalidate()
        fileChangeRefreshTimer = nil
        fileChangeBurstStartedAt = nil
        fileChangeNeedsWatchPathRefresh = false
        watcherRefreshTimer?.invalidate()
        watcherRefreshTimer = nil

        refresh(bypassFastCache: true)
        if !settings.showPeriodUsage {
            disableUsageTotals()
        } else if periodUsageRefreshEnabled {
            refreshUsageTotals(scheduleNext: true)
        }
        refreshWatchPaths()
    }

    private var currentUsage: PeriodUsage {
        PeriodUsage(
            day: snapshot.usage24h,
            week: snapshot.usage7d,
            month: snapshot.usage30d,
            today: snapshot.usageToday,
            daySummary: snapshot.usage24hSummary,
            weekSummary: snapshot.usage7dSummary,
            monthSummary: snapshot.usage30dSummary,
            todaySummary: snapshot.usageTodaySummary
        )
    }

    private func updateRefreshingState() {
        isRefreshing = isRefreshingSnapshot || isRefreshingUsage
    }

    private func stabilizedSnapshot(_ next: UsageSnapshot) -> UsageSnapshot {
        var snapshot = next
        let previous = self.snapshot

        snapshot = snapshot.stabilizedRateLimits(against: previous)

        if snapshot.errorMessage != nil,
           snapshot.usage24h == 0,
           snapshot.usage7d == 0,
           snapshot.usage30d == 0,
           previous.usage30d > 0 {
            snapshot.usage24h = previous.usage24h
            snapshot.usage7d = previous.usage7d
            snapshot.usage30d = previous.usage30d
            snapshot.usageToday = previous.usageToday
            snapshot.usage24hSummary = previous.usage24hSummary
            snapshot.usage7dSummary = previous.usage7dSummary
            snapshot.usage30dSummary = previous.usage30dSummary
            snapshot.usageTodaySummary = previous.usageTodaySummary
        }

        if snapshot.errorMessage != nil {
            if snapshot.tasks.isEmpty {
                snapshot.tasks = previous.tasks.map { task in
                    CodexTask(
                        id: task.id,
                        title: task.title,
                        status: task.status == .running ? .recent : task.status,
                        detailPrefix: task.detailPrefix,
                        tokenCount: task.tokenCount,
                        tokenUsage: task.tokenUsage,
                        updatedAt: task.updatedAt,
                        activeSubagentCount: task.activeSubagentCount
                    )
                }
            }
            snapshot.isRunning = false
            snapshot.errorMessage = nil
        }

        return snapshot
    }
}

private struct LocalUsageSettingsSnapshot: Equatable {
    let activeRefreshInterval: TimeInterval
    let idleRefreshInterval: TimeInterval
    let usageRefreshInterval: TimeInterval
    let watcherRefreshInterval: TimeInterval
    let fileChangeRefreshMinimumGap: TimeInterval
    let skillInsightsEnabled: Bool
    let rateLimitSource: RateLimitSourcePreference
    let taskHistoryRange: TaskHistoryRange

    @MainActor
    init(settings: CodexNotchSettings) {
        activeRefreshInterval = settings.activeRefreshInterval
        idleRefreshInterval = settings.idleRefreshInterval
        usageRefreshInterval = settings.usageRefreshInterval
        watcherRefreshInterval = settings.watcherRefreshInterval
        fileChangeRefreshMinimumGap = settings.fileChangeRefreshMinimumGap
        skillInsightsEnabled = settings.skillInsightsEnabled
        rateLimitSource = settings.rateLimitSource
        taskHistoryRange = settings.taskHistoryRange
    }
}

@MainActor
final class OverlayState: ObservableObject {
    @Published var usesCompactHUD = false

    @Published var isExpanded = false
    @Published private(set) var detailPresentationPhase: DetailPresentationPhase = .hidden

    func setDetailPresentationPhase(_ phase: DetailPresentationPhase) {
        detailPresentationPhase = phase
    }
}
