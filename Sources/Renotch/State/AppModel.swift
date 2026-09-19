import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: NotchSettings {
        didSet {
            settingsStore.save(settings)
            applyLaunchAtLoginIfNeeded(oldValue: oldValue.launchAtLogin)
            if mode == .compact {
                selectedSection = compactDestination
            }
            onPanelConfigurationChanged?()
            updateSystemMetricsActivity()
            updateAIUsageActivity()
        }
    }
    @Published private(set) var mode: NotchMode {
        didSet {
            updateSystemMetricsActivity()
            updateAIUsageActivity()
        }
    }
    @Published private(set) var isDraggingFileOver = false
    @Published var selectedSection: NotchSection {
        didSet {
            updateSystemMetricsActivity()
            updateAIUsageActivity()
        }
    }
    @Published private(set) var isPinned: Bool
    @Published var customTimerMinutes = 30
    @Published var transientMessage: String?
    @Published var authGlance: AuthGlance? {
        didSet { updateAIUsageActivity() }
    }
    @Published var settingsError: String?
    @Published private(set) var expandedSectionOverride: NotchSection? {
        didSet {
            updateSystemMetricsActivity()
            updateAIUsageActivity()
        }
    }
    @Published private(set) var focusTakeoverSite: String = ""
    @Published private(set) var focusTakeoverAppName: String = ""
    @Published private(set) var focusTakeoverTargetApp: NSRunningApplication?

    /// Delay before the file drop success state collapses back to compact.
    var successDismissalDelay: TimeInterval = 1.2

    let timer: TimerService
    let music: MusicService
    let browser: BrowserActivityService
    let calendar: AppleCalendarService
    let shelf: ShelfStore
    let todos: TodoStore
    let activity: DeveloperActivityService
    let focusBlocker: FocusBlockerService
    let systemMetrics: SystemMetricsState
    let aiUsage: AIUsageModel

    var onPanelConfigurationChanged: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?

    private let settingsStore: SettingsStore
    private let defaults: UserDefaults
    private var collapseWorkItem: DispatchWorkItem?
    private var dropExitWorkItem: DispatchWorkItem?
    private var successWorkItem: DispatchWorkItem?
    private var messageWorkItem: DispatchWorkItem?
    private var browserActivityCancellable: AnyCancellable?
    private var browserDownloadsCancellable: AnyCancellable?
    private var musicActivityCancellable: AnyCancellable?
    private var timerActivityCancellable: AnyCancellable?
    private var activityGlanceCancellable: AnyCancellable?
    private var focusBlockerCancellable: AnyCancellable?
    private var modeBeforeFileDrop: NotchMode = .compact
    private var modeBeforeFocusTakeover: NotchMode = .compact
    private var isApplyingLoginSetting = false
    private let systemHistoryURL: URL
    // Created on first use so the history database is only opened once the
    // System section or compact System view is actually shown.
    private var systemCollector: SystemMetricsCollector?
    private var systemProcessSampler: SystemProcessSampler?
    private var areSystemMetricsSuspended = false
    private var isAIUsageSuspended = false

    init(
        defaults: UserDefaults = .standard,
        systemHistoryURL: URL = HistoryStore.defaultDatabaseURL,
        aiUsageEnvironment: AIUsageEnvironment = .live,
        activityService: DeveloperActivityService? = nil
    ) {
        self.defaults = defaults
        self.systemHistoryURL = systemHistoryURL
        settingsStore = SettingsStore(defaults: defaults)
        let loadedSettings = settingsStore.load()
        settings = loadedSettings
        timer = TimerService(defaults: defaults)
        music = MusicService()
        browser = BrowserActivityService()
        calendar = AppleCalendarService()
        shelf = ShelfStore()
        todos = TodoStore(defaults: defaults)
        activity = activityService ?? DeveloperActivityService()
        focusBlocker = FocusBlockerService()
        systemMetrics = SystemMetricsState()
        // Constructing the monitors reads nothing; they start with the AI 用量 section.
        aiUsage = AIUsageModel(environment: aiUsageEnvironment)
        FocusBlockerOverlayController.shared.blockerService = focusBlocker

        let didOnboard = defaults.bool(forKey: "virtualNotch.didCompleteOnboarding")
        mode = didOnboard ? .compact : .expanded
        selectedSection = didOnboard ? loadedSettings.resolvedCompactContent.section : .welcome
        expandedSectionOverride = nil
        isPinned = !didOnboard

        focusBlocker.start(appModel: self)
        timer.onCompletion = { [weak self] completedMode in
            Task { @MainActor in
                self?.handleTimerCompletion(completedMode: completedMode)
            }
        }
        browserActivityCancellable = browser.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        browserDownloadsCancellable = browser.$downloads
            .dropFirst()
            .sink { [weak self] _ in
                // @Published emits before the stored value changes. Resolve the
                // presentation on the next main-loop turn, after the mutation.
                DispatchQueue.main.async { self?.updateAIUsageActivity() }
            }
        musicActivityCancellable = music.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        timerActivityCancellable = timer.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        focusBlockerCancellable = focusBlocker.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        activityGlanceCancellable = activity.$glance
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                    self?.onPanelConfigurationChanged?()
                    self?.updateAIUsageActivity()
                }
            }
        setupPowerManagementObservers()
        activity.setRefreshInterval(isExpanded ? 4.0 : 15.0)
        updateSystemMetricsActivity()
        updateAIUsageActivity()
    }

    var isExpanded: Bool {
        switch mode {
        case .expanded, .fileDrop, .success, .focusTakeover:
            return true
        case .compact:
            return false
        }
    }

    private var compactDestination: NotchSection {
        activity.glance == nil ? settings.resolvedCompactContent.section : .activity
    }

    var activeMediaSource: AdaptiveMediaSource? {
        AdaptiveMediaArbitrator.resolve(
            browserAvailable: browser.media != nil,
            browserIsPlaying: browser.media?.isPlaying == true,
            browserActivation: browser.playbackActivationDate,
            musicIsPlaying: music.isPlaying,
            musicActivation: music.playbackActivationDate
        )
    }

    /// Shared with the view so collection and presentation use the same priority.
    var compactPresentation: AdaptiveCompactPresentation {
        AdaptiveCompactArbitrator.resolve(
            authGlance: authGlance,
            downloadAvailable: browser.activeDownload != nil,
            codingGlanceAvailable: activity.glance != nil,
            mediaSource: activeMediaSource,
            configuredContent: settings.resolvedCompactContent,
            isTimerActive: timer.isActive
        )
    }

    var currentSize: NSSize {
        switch mode {
        case .compact:
            if authGlance != nil {
                return NSSize(
                    width: max(settings.compactWidth, 320),
                    height: max(settings.compactHeight, 44)
                )
            }
            if browser.activeDownload != nil {
                return NSSize(
                    width: max(settings.compactWidth, 340),
                    height: max(settings.compactHeight, 64)
                )
            }
            if activity.glance != nil {
                return NSSize(
                    width: max(settings.compactWidth, 310),
                    height: max(settings.compactHeight, 48)
                )
            }
            if transientMessage != nil {
                return NSSize(
                    width: max(settings.compactWidth, 340),
                    height: settings.compactHeight
                )
            }
            return NSSize(width: settings.compactWidth, height: settings.compactHeight)
        case .expanded:
            let notchHeightOffset: CGFloat = settings.isHardwareNotchSafeActive ? 26 : 0
            if isShowingCodingSection {
                return NSSize(
                    width: max(
                        settings.expandedWidth,
                        NotchSettings.codingExpandedWidth,
                        NotchSettings.expandedMinWidth
                    ),
                    height: max(settings.expandedHeight + notchHeightOffset, NotchSettings.codingExpandedHeight)
                )
            }
            if isShowingSystemSection {
                return NSSize(
                    width: max(
                        settings.expandedWidth,
                        NotchSettings.systemExpandedWidth,
                        NotchSettings.expandedMinWidth
                    ),
                    height: max(settings.expandedHeight, NotchSettings.systemExpandedHeight) + notchHeightOffset
                )
            }
            if isShowingAIUsageSection {
                return NSSize(
                    width: max(
                        settings.expandedWidth,
                        NotchSettings.aiUsageExpandedWidth,
                        NotchSettings.expandedMinWidth
                    ),
                    height: max(settings.expandedHeight, settings.resolvedAIUsageExpandedHeight) + notchHeightOffset
                )
            }
            return NSSize(
                width: max(settings.expandedWidth, NotchSettings.expandedMinWidth),
                height: settings.expandedHeight + notchHeightOffset
            )
        case .fileDrop, .success:
            return NSSize(width: NotchSettings.dragWidth, height: NotchSettings.dragHeight)
        case .focusTakeover:
            let screen = NSScreen.main?.frame.size ?? NSSize(width: 1440, height: 900)
            return screen
        }
    }

    func triggerFaceIDGlance(title: String = "面容 ID", subtitle: String = "已验证", duration: TimeInterval = 2.2) {
        authGlance = AuthGlance(title: title, subtitle: subtitle, isSuccess: true)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        onPanelConfigurationChanged?()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            self.authGlance = nil
            self.onPanelConfigurationChanged?()
        }
    }

    func hoverChanged(_ hovering: Bool) {
        collapseWorkItem?.cancel()
        guard !isDraggingFileOver else { return }
        guard mode != .fileDrop, mode != .success, mode != .focusTakeover else { return }
        guard settings.expandOnHover else { return }
        if hovering {
            if mode == .compact {
                expand(
                    section: compactDestination,
                    preferSelectedSection: true
                )
            }
        } else if !isPinned {
            scheduleCollapse()
        }
    }

    func notchClicked() {
        guard settings.expandOnClick else { return }
        collapseWorkItem?.cancel()
        switch mode {
        case .expanded:
            isPinned.toggle()
            if !isPinned { scheduleCollapse() }
        case .compact:
            expand(
                section: compactDestination,
                pin: true,
                preferSelectedSection: true
            )
        case .fileDrop, .success, .focusTakeover:
            break
        }
    }

    func triggerFocusTakeover(site: String, appName: String, targetApp: NSRunningApplication?) {
        guard mode != .focusTakeover else { return }
        collapseWorkItem?.cancel()
        modeBeforeFocusTakeover = (mode == .focusTakeover ? .compact : mode)
        focusTakeoverSite = site
        focusTakeoverAppName = appName
        focusTakeoverTargetApp = targetApp
        mode = .focusTakeover
        onPanelConfigurationChanged?()
    }

    func closeTabAndResume() {
        let app = focusTakeoverTargetApp
        dismissFocusTakeover()
        focusBlocker.closeTabAndResume(for: app)
    }

    func bypassFocusTakeover(minutes: Int = 5) {
        dismissFocusTakeover()
        focusBlocker.bypass(minutes: minutes)
    }

    func dismissFocusTakeover() {
        guard mode == .focusTakeover else { return }
        mode = modeBeforeFocusTakeover
        focusTakeoverSite = ""
        focusTakeoverAppName = ""
        focusTakeoverTargetApp = nil
        onPanelConfigurationChanged?()
    }

    func expand(
        section: NotchSection? = nil,
        pin: Bool = false,
        preferSelectedSection: Bool = false
    ) {
        collapseWorkItem?.cancel()
        if preferSelectedSection {
            expandedSectionOverride = section
        } else if mode != .expanded {
            expandedSectionOverride = nil
        }
        if let section { selectedSection = section }
        if pin { isPinned = true }
        guard mode != .expanded else { return }
        mode = .expanded
        activity.setRefreshInterval(4.0)
        onPanelConfigurationChanged?()
    }

    func collapse(force: Bool = false) {
        collapseWorkItem?.cancel()
        guard force || !isDraggingFileOver else { return }
        guard force || !isPinned else { return }
        isPinned = false
        expandedSectionOverride = nil
        guard mode != .compact else { return }
        mode = .compact
        activity.setRefreshInterval(15.0)
        onPanelConfigurationChanged?()
    }

    func closeFromOutsideClick() {
        guard mode != .compact, mode != .fileDrop, mode != .success, mode != .focusTakeover, isPinned else { return }
        collapse(force: true)
    }

    func showShelf(pin: Bool = false) {
        let removedCount = shelf.removeMissingFiles()
        if removedCount > 0 {
            showMessage("已移除 \(removedCount) 个找不到的文件")
        }
        guard !shelf.items.isEmpty else {
            collapse(force: true)
            return
        }
        collapseWorkItem?.cancel()
        if pin { isPinned = true }
        selectedSection = .shelf
        expandedSectionOverride = .shelf
        guard mode != .expanded else { return }
        mode = .expanded
        onPanelConfigurationChanged?()
    }

    func fileDropTargetChanged(_ isTargeted: Bool) {
        guard isDraggingFileOver != isTargeted else { return }
        dropExitWorkItem?.cancel()
        isDraggingFileOver = isTargeted

        if isTargeted {
            collapseWorkItem?.cancel()
            successWorkItem?.cancel()
            guard mode != .fileDrop else { return }
            if mode != .success {
                modeBeforeFileDrop = mode
            }
            mode = .fileDrop
            onPanelConfigurationChanged?()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isDraggingFileOver, self.mode == .fileDrop else { return }
            self.restoreModeAfterFileDrop()
        }
        dropExitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @discardableResult
    func handleFileDrop(_ urls: [URL]) -> Bool {
        dropExitWorkItem?.cancel()
        isDraggingFileOver = false

        let result = shelf.add(urls)
        guard result.addedCount > 0 else {
            if result.capacityRejectedCount > 0 || shelf.items.count == shelf.maxItems {
                showMessage("暂存架已满")
            } else {
                showMessage("无法添加此项目")
            }
            restoreModeAfterFileDrop()
            return false
        }

        successWorkItem?.cancel()
        selectedSection = .shelf
        expandedSectionOverride = .shelf
        isPinned = false
        mode = .success
        onPanelConfigurationChanged?()
        if result.capacityRejectedCount > 0 {
            showMessage("暂存架已满")
        } else {
            showMessage(result.addedCount == 1 ? "已添加到暂存架" : "已添加 \(result.addedCount) 个文件")
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        scheduleSuccessDismissal()
        return true
    }

    private func scheduleSuccessDismissal() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .success else { return }
            self.expandedSectionOverride = nil
            self.collapse(force: true)
        }
        successWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + successDismissalDelay, execute: work)
    }

    func removeShelfItem(_ item: ShelfItem) {
        shelf.remove(item)
        shelfDidChange()
    }

    func clearShelf() {
        shelf.clear()
        shelfDidChange()
    }

    func removeMissingShelfFiles() {
        let removedCount = shelf.removeMissingFiles()
        guard removedCount > 0 else { return }
        showMessage("已移除 \(removedCount) 个找不到的文件")
        shelfDidChange()
    }

    func completeOnboarding() {
        defaults.set(true, forKey: "virtualNotch.didCompleteOnboarding")
        isPinned = false
        selectedSection = compactDestination
        collapse(force: true)
    }

    func startPomodoro(focusMinutes: Int? = nil, breakMinutes: Int? = nil) {
        let fMin = focusMinutes ?? timer.focusMinutes
        let bMin = breakMinutes ?? timer.breakMinutes
        timer.startPomodoro(
            focusMinutes: fMin,
            breakMinutes: bMin,
            autoAdvance: true,
            notify: settings.timerNotificationsEnabled
        )
        isPinned = false
        showMessage("专注 \(fMin) 分钟 · 随后休息 \(bMin) 分钟")
        collapse(force: true)
    }

    func startTimer(minutes: Int, mode: PomodoroMode? = nil) {
        let activeMode = mode ?? timer.selectedMode
        timer.start(minutes: minutes, mode: activeMode, notify: settings.timerNotificationsEnabled)
        isPinned = false
        showMessage("\(activeMode.title)计时已开始 · \(minutes) 分钟")
        collapse(force: true)
    }

    func startCustomTimer(mode: PomodoroMode? = nil) {
        startTimer(minutes: customTimerMinutes, mode: mode)
    }

    func showMessage(_ message: String) {
        messageWorkItem?.cancel()
        transientMessage = message
        let work = DispatchWorkItem { [weak self] in self?.transientMessage = nil }
        messageWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    func setVisible(_ visible: Bool) {
        settings.isEnabled = visible
        onVisibilityChanged?(visible)
    }

    func resetSettings() {
        settings = .default
        settingsError = nil
    }

    private func scheduleCollapse() {
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.collapseDelay, execute: work)
    }

    /// Height of the expanded content frame. The System and AI 用量 sections lay
    /// out into their own minimum sizes; other sections keep the configured height.
    var expandedContentHeight: CGFloat {
        if mode == .expanded && (isShowingSystemSection || isShowingAIUsageSection) {
            return currentSize.height
        }
        return settings.expandedHeight + (settings.isHardwareNotchSafeActive ? 26 : 0)
    }

    var isCollectingSystemMetrics: Bool {
        systemCollector?.isRunning ?? false
    }

    var isSamplingSystemProcesses: Bool {
        systemProcessSampler?.isRunning ?? false
    }

    func refreshSystemNetworkProcesses() {
        systemProcessSampler?.refreshNetworkProcesses()
    }

    private var isShowingSystemSection: Bool {
        if expandedSectionOverride != nil {
            return expandedSectionOverride == .system
        }
        return selectedSection == .system
    }

    /// Collect system metrics only while they are on screen: the expanded System
    /// section, or the compact notch configured to System. Process sampling (a
    /// libproc sweep every 1.5s plus `nettop`) is limited to the expanded section.
    private func updateSystemMetricsActivity() {
        let canRun = settings.isEnabled && !areSystemMetricsSuspended
        let showsSection = mode == .expanded && isShowingSystemSection
        let showsCompact = mode == .compact && settings.resolvedCompactContent == .system

        if canRun && (showsSection || showsCompact) {
            let collector = systemCollector ?? SystemMetricsCollector(
                state: systemMetrics,
                historyStore: HistoryStore(databaseURL: systemHistoryURL)
            )
            systemCollector = collector
            collector.start()
        } else {
            systemCollector?.stop()
        }

        if canRun && showsSection {
            let sampler = systemProcessSampler ?? SystemProcessSampler(state: systemMetrics)
            systemProcessSampler = sampler
            sampler.start()
        } else {
            systemProcessSampler?.stop()
        }
    }

    var isCollectingAIUsage: Bool {
        aiUsage.isActive
    }

    private var isShowingAIUsageSection: Bool {
        if expandedSectionOverride != nil {
            return expandedSectionOverride == .aiUsage
        }
        return selectedSection == .aiUsage
    }

    /// Codex logs, the Claude Code snapshot and the DeepSeek balance are read only
    /// while they are on screen (notch enabled, Mac awake): the expanded AI 用量
    /// section needs all three, the collapsed 系统状态 content shows Codex 限额 and
    /// DeepSeek 余额 beside the system metrics.
    private func updateAIUsageActivity() {
        aiUsage.setScope(resolvedAIUsageScope)
    }

    private var resolvedAIUsageScope: AIUsageModel.Scope {
        guard settings.isEnabled, !isAIUsageSuspended else { return .hidden }
        if mode == .expanded && isShowingAIUsageSection { return .full }
        if mode == .compact,
           settings.resolvedCompactContent == .system,
           settings.compactSystemShowsAIUsage,
           compactPresentation == .configured { return .compact }
        return .hidden
    }

    private var isShowingCodingSection: Bool {
        if expandedSectionOverride != nil {
            return expandedSectionOverride == .activity
        }
        return selectedSection == .activity
    }

    private func restoreModeAfterFileDrop() {
        mode = modeBeforeFileDrop == .expanded && isPinned ? .expanded : .compact
        if mode == .compact { isPinned = false }
        onPanelConfigurationChanged?()
    }

    private func shelfDidChange() {
        onPanelConfigurationChanged?()
    }

    private func handleTimerCompletion(completedMode: PomodoroMode) {
        let breakMin = timer.breakMinutes
        let isAutoBreak = completedMode == .focus && timer.isActive && timer.currentMode == .breakTime
        if settings.timerNotificationsEnabled {
            NotificationService.shared.playTimerSound()
            NotificationService.shared.timerFinished(
                mode: completedMode,
                breakMinutes: breakMin,
                autoAdvance: isAutoBreak
            )
        }
        transientMessage = isAutoBreak
            ? "专注已完成 · 开始休息 \(breakMin) 分钟"
            : (completedMode == .focus ? "专注已完成！" : "休息已结束！")
        expand(section: .timer, pin: true, preferSelectedSection: true)
    }

    private func applyLaunchAtLoginIfNeeded(oldValue: Bool) {
        guard settings.launchAtLogin != oldValue, !isApplyingLoginSetting else { return }
        do {
            try LaunchAtLoginService.setEnabled(settings.launchAtLogin)
            settingsError = nil
        } catch {
            isApplyingLoginSetting = true
            settings.launchAtLogin = oldValue
            isApplyingLoginSetting = false
            // localizedDescription is English in bare dev runs (no Info.plist); keep the banner
            // fully Chinese and send the system description to the log instead.
            NSLog("[LaunchAtLogin] Failed to update login item: %@", String(describing: error))
            settingsError = "无法更改“登录时打开”设置（错误代码 \((error as NSError).code)）。"
        }
    }

    private func setupPowerManagementObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.pauseServices()
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.resumeServices()
            }
        }
    }

    private func pauseServices() {
        music.pause()
        activity.pause()
        areSystemMetricsSuspended = true
        updateSystemMetricsActivity()
        isAIUsageSuspended = true
        updateAIUsageActivity()
    }

    private func resumeServices() {
        music.resume()
        activity.resume()
        areSystemMetricsSuspended = false
        updateSystemMetricsActivity()
        isAIUsageSuspended = false
        updateAIUsageActivity()
    }
}
