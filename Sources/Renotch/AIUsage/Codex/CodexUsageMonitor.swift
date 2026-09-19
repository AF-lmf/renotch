import Combine
import Foundation

/// Reads Codex limits from the local rollout logs while the AI 用量 section is
/// on screen: once on entry, then every 20 s. While older history is still being
/// explored (each read is byte-budgeted) it reads again after 0.3 s, up to 30
/// times per entry. The reader keeps its per-file offsets while hidden, so
/// reopening the section only reads bytes appended since.
@MainActor
final class CodexUsageMonitor: ObservableObject {
    @Published private(set) var reading: CodexUsageReading?

    let codexHome: URL

    /// "~/.codex" for Settings copy.
    var codexHomeDisplayPath: String {
        (codexHome.path as NSString).abbreviatingWithTildeInPath
    }

    private(set) var isActive = false
    /// Completed reads, for tests.
    private(set) var readCount = 0
    var isTimerRunning: Bool { timer != nil }

    /// The reader is not thread-safe; it is only ever touched on `queue`.
    private final class ReaderBox: @unchecked Sendable {
        let reader: CodexRateLimitReader
        init(_ reader: CodexRateLimitReader) { self.reader = reader }
    }

    private let box: ReaderBox
    private let queue = DispatchQueue(label: "com.vincentyosi.renotch.ai-usage.codex", qos: .utility)
    private let refreshInterval: TimeInterval
    private let catchUpDelay: TimeInterval
    private let maxCatchUpReads: Int
    private let now: () -> Date
    private var timer: Timer?
    /// Bumped on every activation change so pending catch-ups are dropped.
    private var generation = 0
    private var catchUpReads = 0
    private var isReading = false

    init(
        codexHome: URL,
        limits: CodexRateLimitReader.Limits = .init(),
        refreshInterval: TimeInterval = 20,
        catchUpDelay: TimeInterval = 0.3,
        maxCatchUpReads: Int = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.codexHome = codexHome
        box = ReaderBox(CodexRateLimitReader(codexHome: codexHome, limits: limits))
        self.refreshInterval = refreshInterval
        self.catchUpDelay = catchUpDelay
        self.maxCatchUpReads = maxCatchUpReads
        self.now = now
    }

    deinit {
        timer?.invalidate()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        generation += 1
        timer?.invalidate()
        timer = nil
        guard active else { return }

        catchUpReads = 0
        refresh()
        // Runs on the main run loop, so it already fires on the main actor.
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        timer.tolerance = refreshInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One read even while the section is hidden (Settings). Ignored while a
    /// read is already in flight.
    func refreshNow() {
        refresh()
    }

    private func refresh() {
        guard !isReading else { return }
        isReading = true
        let box = box
        let now = now()
        let generation = generation
        queue.async { [weak self] in
            let reading = box.reader.read(now: now)
            guard let self else { return }
            Task { @MainActor in
                self.finish(reading, generation: generation)
            }
        }
    }

    private func finish(_ new: CodexUsageReading, generation: Int) {
        isReading = false
        readCount += 1
        if reading.map({ !$0.hasSameContent(as: new) }) ?? true {
            reading = new
        }
        if isActive, generation != self.generation {
            // Reactivated while this read was in flight; the entry read was skipped.
            refresh()
            return
        }
        guard isActive, !new.isComplete,
              catchUpReads < maxCatchUpReads else { return }
        catchUpReads += 1
        let delay = UInt64(max(0, catchUpDelay) * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, self.isActive, self.generation == generation else { return }
            self.refresh()
        }
    }
}
