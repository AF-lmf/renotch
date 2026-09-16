import Foundation

/// Drives all system metric readers on one timer and publishes into `SystemMetricsState`.
///
/// Ported from MacStatus `MetricCollector` with its app couplings removed:
/// - no singleton; the owner injects the state and history store
/// - the refresh interval is injected via `setRefreshInterval(_:)` instead of being
///   read from `SettingsManager`
/// - no `PopoverManager` / `StatusBarManager` writes
///
/// MacStatus started collection once at launch. Renotch starts and stops it as the
/// notch expands and collapses, so reader setup runs once, delta-based readers are
/// re-baselined on every `start()`, and history purging is time-based rather than
/// tick-count based.
///
/// ```
/// Timer → tick() → RingBuffer (memory)
///                → HistoryStore (SQLite, batched)
///                → SystemMetricsState (SwiftUI)
/// ```
@MainActor
final class SystemMetricsCollector {
    let state: SystemMetricsState
    private(set) var refreshInterval: TimeInterval
    var isRunning: Bool { timer != nil }

    private let ringBuffer = RingBuffer(capacity: 300)
    private let historyStore: HistoryStore
    private var timer: Timer?

    private let cpuReader = CPUReader()
    private let memoryReader = MemoryReader()
    private let networkReader = NetworkReader()
    private let gpuReader = GPUReader()
    private let batteryReader = BatteryReader()
    private let thermalReader = ThermalReader()
    private let fanReader = FanReader()

    private var pendingSamples: [MetricSample] = []
    private let flushThreshold = 30
    private let historyRetention: TimeInterval = 7 * 24 * 3600
    private let purgeInterval: TimeInterval = 3600
    private var lastPurge = Date.distantPast
    private var didPrepareReaders = false

    // Kept outside MetricSample: no persistence, no sparkline.
    private var lastBatterySnapshot: BatterySnapshot?
    private var lastThermalSnapshot: ThermalSnapshot = .unavailable()
    private var lastFanSnapshot: FanSnapshot = .unavailable()

    init(
        state: SystemMetricsState,
        refreshInterval: TimeInterval = 2.0,
        historyStore: HistoryStore = HistoryStore()
    ) {
        self.state = state
        self.refreshInterval = max(0.5, refreshInterval)
        self.historyStore = historyStore
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Lifecycle

    /// Start or resume collection. Calling it while running is a no-op.
    func start() {
        guard timer == nil else { return }
        if didPrepareReaders {
            rebaselineDeltaReaders()
        } else {
            prepareReaders()
            loadRecentHistory()
            didPrepareReaders = true
        }
        scheduleTimer()
    }

    /// Stop collection and flush pending history. Reader state is kept for the next `start()`.
    func stop() {
        timer?.invalidate()
        timer = nil
        flushPendingSamples()
    }

    /// Reschedule a running timer without touching readers, so delta baselines survive.
    func setRefreshInterval(_ interval: TimeInterval) {
        let clamped = max(0.5, interval)
        guard clamped != refreshInterval else { return }
        refreshInterval = clamped
        guard timer != nil else { return }
        timer?.invalidate()
        scheduleTimer()
    }

    // MARK: - Tick

    /// One collection cycle. Internal rather than private so tests can drive it
    /// without waiting on the run loop.
    func tick() {
        let cpu = cpuReader.readValue()
        let memory = memoryReader.readValue()
        let network = networkReader.readValue()
        let gpu = gpuReader.readValue()
        lastBatterySnapshot = batteryReader.readValue()
        lastThermalSnapshot = thermalReader.readValue()
        lastFanSnapshot = fanReader.readValue()

        let sample = MetricSample(
            cpuUsage: cpu,
            memoryUsage: memory?.usedPercent,
            networkUploadBps: network?.uploadBytesPerSec,
            networkDownloadBps: network?.downloadBytesPerSec,
            gpuUsage: gpu?.utilizationPercent
        )

        ringBuffer.append(sample)
        pendingSamples.append(sample)
        if pendingSamples.count >= flushThreshold {
            flushPendingSamples()
        }

        // MacStatus rebuilt MemoryStats/GPUStats from the sample with a hard-coded
        // pressure level; pass the reader results through so pressure is real.
        state.updateCPU(cpu)
        state.updateMemory(memory)
        state.updateNetwork(network)
        state.updateGPU(gpu)
        state.updateBattery(lastBatterySnapshot)
        state.updateThermal(lastThermalSnapshot)
        state.updateFans(lastFanSnapshot)
        publishSparklines()

        purgeHistoryIfNeeded()
    }

    // MARK: - Accessors

    func recentSamples(_ count: Int = SystemMetricsState.sparklineCapacity) -> [MetricSample] {
        ringBuffer.recentSamples(count)
    }

    var persistedCount: Int {
        historyStore.sampleCount
    }

    // MARK: - Private

    private func prepareReaders() {
        // CPU, memory, network and GPU readers are TimerReader subclasses whose init
        // already calls setup(). Calling it again would register a second wake
        // observer in NetworkReader and leak the first token.
        batteryReader.setup()
        thermalReader.setup()
        fanReader.setup()

        rebaselineDeltaReaders()
        lastBatterySnapshot = batteryReader.readValue()
        lastThermalSnapshot = thermalReader.readValue()
        lastFanSnapshot = fanReader.readValue()
    }

    /// CPU ticks and network byte counters are deltas. Re-reading them makes the next
    /// tick measure only the time since now, not the whole period collection was paused.
    private func rebaselineDeltaReaders() {
        _ = cpuReader.readValue()
        _ = networkReader.readValue()
    }

    private func scheduleTimer() {
        // The timer lives on the main run loop, so it already fires on the main actor.
        // Tick synchronously rather than hopping through a Task: while a modal alert
        // runs inside a main-actor task (e.g. the launch update check), queued
        // main-actor work cannot start until the alert closes.
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer.tolerance = refreshInterval * 0.1
        // Common modes, not just default, so modal alerts and menu tracking don't
        // stop the timer either.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func publishSparklines() {
        let recent = ringBuffer.recentSamples(SystemMetricsState.sparklineCapacity)
        state.cpuSamples = recent.compactMap(\.cpuUsage)
        state.memorySamples = recent.compactMap(\.memoryUsage)
        state.networkSamples = recent.compactMap { $0.networkDownloadBps.map { $0 / 1000.0 } }
        state.gpuSamples = recent.compactMap(\.gpuUsage)
    }

    private func loadRecentHistory() {
        let samples = historyStore.querySamples(from: Date().addingTimeInterval(-300), to: Date())
        guard !samples.isEmpty else { return }
        samples.forEach(ringBuffer.append)
        publishSparklines()
    }

    private func flushPendingSamples() {
        guard !pendingSamples.isEmpty else { return }
        historyStore.insertSamples(pendingSamples)
        pendingSamples.removeAll()
    }

    private func purgeHistoryIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastPurge) >= purgeInterval else { return }
        lastPurge = now
        historyStore.purgeOlder(than: now.addingTimeInterval(-historyRetention))
    }
}
