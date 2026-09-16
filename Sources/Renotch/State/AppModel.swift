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
        }
    }
    @Published private(set) var mode: NotchMode {
        didSet { updateSystemMetricsActivity() }
    }
    @Published private(set) var isDraggingFileOver = false
    @Published var selectedSection: NotchSection {
        didSet { updateSystemMetricsActivity() }
    }
    @Published private(set) var isPinned: Bool
    @Published var customTimerMinutes = 30
    @Published var transientMessage: String?
    @Published var authGlance: AuthGlance?
    @Published var settingsError: String?
    @Published private(set) var expandedSectionOverride: NotchSection? {
        didSet { updateSystemMetricsActivity() }
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

    var onPanelConfigurationChanged: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?

    private let settingsStore: SettingsStore
    private let defaults: UserDefaults
    private var collapseWorkItem: DispatchWorkItem?
    private var dropExitWorkItem: DispatchWorkItem?
    private var successWorkItem: DispatchWorkItem?
    private var messageWorkItem: DispatchWorkItem?
    private var browserActivityCancellable: AnyCancellable?
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

    init(
        defaults: UserDefaults = .standard,
        systemHistoryURL: URL = HistoryStore.defaultDatabaseURL
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
        activity = DeveloperActivityService()
        focusBlocker = FocusBlockerService()
        systemMetrics = SystemMetricsState()
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
                }
            }
        setupPowerManagementObservers()
        activity.setRefreshInterval(isExpanded ? 4.0 : 15.0)
        updateSystemMetricsActivity()
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

    func triggerFaceIDGlance(title: String = "Face ID", subtitle: String = "Authenticated", duration: TimeInterval = 2.2) {
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
            showMessage(removedCount == 1 ? "Removed 1 missing file" : "Removed \(removedCount) missing files")
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
                showMessage("Shelf is full")
            } else {
                showMessage("This item cannot be added")
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
            showMessage("Shelf is full")
        } else {
            showMessage(result.addedCount == 1 ? "Added to shelf" : "Added \(result.addedCount) files")
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
        showMessage(removedCount == 1 ? "Removed 1 missing file" : "Removed \(removedCount) missing files")
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
        showMessage("Focus started · \(fMin)m (Break \(bMin)m next)")
        collapse(force: true)
    }

    func startTimer(minutes: Int, mode: PomodoroMode? = nil) {
        let activeMode = mode ?? timer.selectedMode
        timer.start(minutes: minutes, mode: activeMode, notify: settings.timerNotificationsEnabled)
        isPinned = false
        showMessage("\(activeMode.title) timer started · \(minutes) min")
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

    /// Height of the expanded content frame. The System section lays out into its
    /// taller size; other sections keep the configured expanded height.
    var expandedContentHeight: CGFloat {
        if mode == .expanded && isShowingSystemSection {
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
            ? "Focus complete · \(breakMin)m Break started"
            : (completedMode == .focus ? "Focus complete!" : "Break complete!")
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
            settingsError = "Launch at login could not be changed: \(error.localizedDescription)"
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
    }

    private func resumeServices() {
        music.resume()
        activity.resume()
        areSystemMetricsSuspended = false
        updateSystemMetricsActivity()
    }
}
