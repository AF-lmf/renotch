import Combine
import Darwin
import Foundation

/// Connection status and the latest snapshot of the Claude Code bridge. While
/// the AI 用量 section is on screen it stats three files every 5 s and only
/// re-reads what changed. settings.json is written only by `connect()` and
/// `disconnect()`, which Settings calls from its buttons.
@MainActor
final class ClaudeUsageMonitor: ObservableObject {
    /// nil until first checked.
    @Published private(set) var status: ClaudeBridgeStatus?
    @Published private(set) var snapshot: ClaudeUsageSnapshot?
    @Published private(set) var state: ClaudeBridgeState?
    @Published private(set) var hooksDisabled = false
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?

    let settingsDisplayPath: String
    private(set) var isActive = false

    var backupURL: URL? {
        state?.backupPath.map { URL(fileURLWithPath: $0) }
    }

    var originalSummary: String {
        AIUsagePresentation.claudeOriginalSummary(state?.original)
    }

    private let worker: Worker
    private let queue = DispatchQueue(label: "com.vincentyosi.renotch.ai-usage.claude", qos: .utility)
    private let pollInterval: TimeInterval
    private var timer: Timer?

    init(paths: ClaudeBridgePaths, pollInterval: TimeInterval = 5, now: @escaping () -> Date = Date.init) {
        settingsDisplayPath = paths.settingsDisplayPath
        worker = Worker(bridge: ClaudeStatusLineBridge(paths: paths, now: now))
        self.pollInterval = pollInterval
    }

    deinit {
        timer?.invalidate()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        timer?.invalidate()
        timer = nil
        guard active else { return }

        schedulePoll(force: false)
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.schedulePoll(force: false)
            }
        }
        timer.tolerance = pollInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Settings appeared: heal the support files, then re-check everything.
    func refreshStatus() {
        let worker = worker
        queue.async { worker.bridge.performMaintenance() }
        schedulePoll(force: true)
    }

    /// Launch upkeep; touches only the support directory.
    func performMaintenance() {
        let worker = worker
        queue.async { worker.bridge.performMaintenance() }
    }

    /// Settings 连接 / 重新连接.
    @discardableResult
    func connect() async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        lastError = nil
        let worker = worker
        let queue = queue
        let failure: String? = await withCheckedContinuation { continuation in
            queue.async {
                do {
                    try worker.bridge.install()
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: ClaudeBridgeError.message(for: error))
                }
            }
        }
        await poll(force: true)
        isWorking = false
        lastError = failure
        return failure == nil
    }

    /// Settings 断开. nil when it failed (see `lastError`).
    @discardableResult
    func disconnect() async -> ClaudeStatusLineBridge.UninstallOutcome? {
        guard !isWorking else { return nil }
        isWorking = true
        lastError = nil
        let worker = worker
        let queue = queue
        let result: Result<ClaudeStatusLineBridge.UninstallOutcome, ClaudeOperationFailure> =
            await withCheckedContinuation { continuation in
                queue.async {
                    do {
                        continuation.resume(returning: .success(try worker.bridge.uninstall()))
                    } catch {
                        continuation.resume(returning: .failure(ClaudeOperationFailure(message: ClaudeBridgeError.message(for: error))))
                    }
                }
            }
        await poll(force: true)
        isWorking = false
        switch result {
        case .success(let outcome):
            return outcome
        case .failure(let failure):
            lastError = failure.message
            return nil
        }
    }

    /// Stats the files on the bridge queue and publishes only what changed.
    func poll(force: Bool) async {
        let worker = worker
        let queue = queue
        let result: PollResult = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: worker.poll(force: force)) }
        }
        apply(result)
    }

    private func schedulePoll(force: Bool) {
        Task { [weak self] in await self?.poll(force: force) }
    }

    private func apply(_ result: PollResult) {
        if let inspection = result.inspection {
            if status != inspection.status { status = inspection.status }
            if hooksDisabled != inspection.hooksDisabled { hooksDisabled = inspection.hooksDisabled }
            if state != inspection.state { state = inspection.state }
        }
        if case .changed(let newSnapshot) = result.snapshot, snapshot != newSnapshot {
            snapshot = newSnapshot
        }
    }

    // MARK: - Queue-confined work

    struct PollResult: Sendable {
        enum SnapshotChange: Sendable {
            case unchanged
            case changed(ClaudeUsageSnapshot?)
        }

        /// nil when settings.json, the record and the settings directory are unchanged.
        var inspection: ClaudeStatusLineBridge.Inspection?
        var snapshot: SnapshotChange
    }

    private struct ClaudeOperationFailure: Error, Sendable {
        let message: String
    }

    /// mtime, size and inode; a rewrite or rename changes at least one.
    private struct FileStamp: Equatable {
        let modified: timespec
        let size: off_t
        let inode: ino_t

        static func == (lhs: FileStamp, rhs: FileStamp) -> Bool {
            lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.size == rhs.size && lhs.inode == rhs.inode
        }

        /// nil when the file does not exist. stat(2) follows symlinks, so a
        /// symlinked settings.json is stamped by its target.
        static func of(_ url: URL) -> FileStamp? {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            return FileStamp(modified: info.st_mtimespec, size: info.st_size, inode: info.st_ino)
        }
    }

    /// The bridge and the last-seen stamps; used only on `queue`.
    private final class Worker: @unchecked Sendable {
        let bridge: ClaudeStatusLineBridge
        private var hasPolled = false
        private var directoryExists = false
        private var settingsStamp: FileStamp?
        private var stateStamp: FileStamp?
        private var snapshotStamp: FileStamp?

        init(bridge: ClaudeStatusLineBridge) {
            self.bridge = bridge
        }

        func poll(force: Bool) -> PollResult {
            let paths = bridge.paths
            var isDirectory: ObjCBool = false
            let directory = FileManager.default.fileExists(atPath: paths.settingsDirectory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
            let settings = FileStamp.of(paths.settingsFile)
            let state = FileStamp.of(paths.stateFile)
            let snapshotFile = FileStamp.of(paths.snapshotFile)

            let first = !hasPolled
            hasPolled = true

            var result = PollResult(inspection: nil, snapshot: .unchanged)
            if force || first || directory != directoryExists || settings != settingsStamp || state != stateStamp {
                result.inspection = bridge.inspectAll()
            }
            if force || first || snapshotFile != snapshotStamp {
                if snapshotFile == nil {
                    result.snapshot = .changed(nil)
                } else if let data = try? Data(contentsOf: paths.snapshotFile),
                          let decoded = ClaudeUsageSnapshot.decode(data) {
                    result.snapshot = .changed(decoded)
                }
                // A snapshot that fails to decode keeps the previous value.
            }
            directoryExists = directory
            settingsStamp = settings
            stateStamp = state
            snapshotStamp = snapshotFile
            return result
        }
    }
}
