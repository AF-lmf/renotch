import Combine
import Foundation
import Security

/// When to fetch. Pure so tests can drive it with a fake clock.
struct DeepSeekRefreshPolicy: Equatable, Sendable {
    /// Opening the section reuses a balance younger than this.
    var entryFreshness: TimeInterval = 60
    /// While the section stays open, a balance is refreshed after this long.
    var freshness: TimeInterval = 300
    /// Manual refresh is ignored within this long of the previous attempt.
    var manualFloor: TimeInterval = 10
    /// Automatic retries after failures other than 401.
    var retryDelays: [TimeInterval] = [30, 60, 120, 300]

    func isDue(
        now: Date,
        lastAttempt: Date?,
        lastSuccess: Date?,
        failures: Int,
        lastFailure: DeepSeekBalanceFailure?,
        onEntry: Bool
    ) -> Bool {
        guard let lastAttempt else { return true }
        // A rejected key only changes when the user saves a new one.
        if lastFailure == .invalidKey { return false }
        if failures > 0, !retryDelays.isEmpty {
            let delay = retryDelays[min(failures, retryDelays.count) - 1]
            return now.timeIntervalSince(lastAttempt) >= delay
        }
        if let lastSuccess {
            return now.timeIntervalSince(lastSuccess) >= (onEntry ? entryFreshness : freshness)
        }
        // Attempts that stopped at the Keychain retry only when the section is reopened.
        return onEntry
    }
}

/// Fetches the DeepSeek balance only while the AI 用量 section is on screen
/// (plus explicit Settings actions), keeps the last good balance in memory, and
/// never shows a Keychain dialog unless the user clicks 授权 / 授权读取 or saves
/// or clears the key.
@MainActor
final class DeepSeekBalanceMonitor: ObservableObject {
    enum KeyState: Equatable, Sendable {
        case unknown
        case missing
        case saved(hint: String?)
    }

    enum Status: Equatable, Sendable {
        case notConfigured
        /// The key exists but this build must ask macOS before reading it.
        case needsKeychainAccess
        case idle
        case loading
        case loaded
        case failed(DeepSeekBalanceFailure)
        case keychainError(SecretStoreError)
    }

    struct Snapshot: Equatable, Sendable {
        let balance: DeepSeekBalance
        let fetchedAt: Date
    }

    @Published private(set) var keyState: KeyState = .unknown
    @Published private(set) var status: Status = .idle
    /// Last good value; kept (and shown with its age) through later failures.
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var isRefreshing = false

    private(set) var isActive = false

    private let store: any SecretStore
    private let fetch: DeepSeekBalanceAPI.Fetch
    private let now: () -> Date
    private let policy: DeepSeekRefreshPolicy
    private let tickInterval: TimeInterval

    /// The key in memory after the first read; never published or logged.
    private var cachedKey: String?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    /// Bumped whenever the key changes so late responses for an old key are dropped.
    private var generation = 0
    private var lastAttempt: Date?
    private var lastSuccess: Date?
    private var failures = 0
    private var lastFailure: DeepSeekBalanceFailure?

    init(
        store: any SecretStore,
        fetch: @escaping DeepSeekBalanceAPI.Fetch,
        now: @escaping () -> Date = Date.init,
        policy: DeepSeekRefreshPolicy = DeepSeekRefreshPolicy(),
        tickInterval: TimeInterval = 30
    ) {
        self.store = store
        self.fetch = fetch
        self.now = now
        self.policy = policy
        self.tickInterval = tickInterval
    }

    deinit {
        timer?.invalidate()
    }

    /// Called by AppModel: true only while the expanded AI 用量 section is shown
    /// (and the notch is enabled and the Mac awake). Hiding it lets an in-flight
    /// request finish and keeps its result.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        timer?.invalidate()
        timer = nil
        guard active, keyState != .missing else { return }
        startTimer()
        tick(onEntry: true)
    }

    /// Automatic path: silent Keychain read, fetch only when the policy says so.
    func tick(onEntry: Bool = false) {
        guard isActive, task == nil, keyState != .missing else { return }
        if status == .needsKeychainAccess, !onEntry { return }
        guard policy.isDue(
            now: now(),
            lastAttempt: lastAttempt,
            lastSuccess: lastSuccess,
            failures: failures,
            lastFailure: lastFailure,
            onEntry: onEntry
        ) else { return }
        start(allowKeychainUI: false)
    }

    /// The card's refresh control and Settings 立即查询; works while hidden.
    func refreshManually() {
        guard task == nil, keyState != .missing else { return }
        if let lastAttempt, now().timeIntervalSince(lastAttempt) < policy.manualFloor { return }
        start(allowKeychainUI: false)
    }

    /// 授权 / 授权读取: the one non-Settings path allowed to show the system dialog.
    func authorizeKeychainAccess() {
        guard task == nil else { return }
        start(allowKeychainUI: true)
    }

    /// Settings appeared: reads only non-secret metadata, never prompts.
    func reloadKeyState() async {
        let store = store
        let result: Result<SecretMetadata?, SecretStoreError> = await Task.detached {
            do { return .success(try store.metadata()) } catch { return .failure(Self.storeError(error)) }
        }.value
        switch result {
        case .success(let metadata?):
            keyState = .saved(hint: metadata.hint)
            if status == .notConfigured { status = .idle }
            // A key appeared while the section is open (it was missing on entry).
            if isActive, timer == nil { startTimer() }
        case .success(nil):
            if keyState != .missing { resetForKeyChange() }
            keyState = .missing
            status = .notConfigured
        case .failure(let error):
            status = .keychainError(error)
        }
    }

    /// Settings 保存. Returns false for an unusable paste (nothing changes) or a
    /// Keychain error (shown in `status`). A saved key is validated right away.
    @discardableResult
    func saveKey(_ raw: String) async -> Bool {
        guard let key = DeepSeekKeyHint.sanitize(raw) else { return false }
        let hint = DeepSeekKeyHint.hint(for: key)
        let store = store
        let error: SecretStoreError? = await Task.detached {
            do { try store.write(key, hint: hint); return nil } catch { return Self.storeError(error) }
        }.value
        if let error {
            status = .keychainError(error)
            return false
        }
        resetForKeyChange()
        cachedKey = key
        keyState = .saved(hint: hint)
        status = .idle
        if isActive, timer == nil { startTimer() }
        start(allowKeychainUI: false)
        return true
    }

    /// Settings 清除 (after confirmation). User-initiated, so macOS may ask.
    func deleteKey() async {
        let store = store
        let error: SecretStoreError? = await Task.detached {
            do { try store.delete(allowUI: true); return nil } catch { return Self.storeError(error) }
        }.value
        if let error {
            status = .keychainError(error)
            return
        }
        resetForKeyChange()
        keyState = .missing
        status = .notConfigured
    }

    // MARK: - Fetching

    private func startTimer() {
        // Runs on the main run loop, so it already fires on the main actor.
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer.tolerance = tickInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func resetForKeyChange() {
        generation += 1
        task?.cancel()
        task = nil
        isRefreshing = false
        cachedKey = nil
        snapshot = nil
        lastAttempt = nil
        lastSuccess = nil
        failures = 0
        lastFailure = nil
    }

    private func start(allowKeychainUI: Bool) {
        let generation = generation
        lastAttempt = now()
        status = .loading
        isRefreshing = true
        task = Task { [weak self] in
            await self?.run(generation: generation, allowKeychainUI: allowKeychainUI)
        }
    }

    private func run(generation: Int, allowKeychainUI: Bool) async {
        defer {
            if generation == self.generation {
                task = nil
                isRefreshing = false
            }
        }
        let key: String
        if let cachedKey {
            key = cachedKey
        } else {
            let store = store
            let read: Result<String?, SecretStoreError> = await Task.detached {
                do { return .success(try store.read(allowUI: allowKeychainUI)) } catch { return .failure(Self.storeError(error)) }
            }.value
            guard generation == self.generation else { return }
            switch read {
            case .success(let secret?):
                cachedKey = secret
                key = secret
                if case .saved = keyState {} else { keyState = .saved(hint: DeepSeekKeyHint.hint(for: secret)) }
            case .success(nil):
                keyState = .missing
                status = .notConfigured
                return
            case .failure(.accessRequired), .failure(.denied):
                // No automatic retry until the section is reopened or the user authorizes.
                status = .needsKeychainAccess
                return
            case .failure(let error):
                status = .keychainError(error)
                return
            }
        }

        let outcome: Result<DeepSeekBalance, DeepSeekBalanceFailure>
        do {
            let (data, response) = try await fetch(DeepSeekBalanceAPI.makeRequest(apiKey: key))
            outcome = DeepSeekBalanceAPI.parse(data: data, response: response)
        } catch {
            outcome = .failure(DeepSeekBalanceAPI.failure(for: error))
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        switch outcome {
        case .success(let balance):
            let fetchedAt = now()
            snapshot = Snapshot(balance: balance, fetchedAt: fetchedAt)
            lastSuccess = fetchedAt
            failures = 0
            lastFailure = nil
            status = .loaded
        case .failure(let failure):
            failures += 1
            lastFailure = failure
            if failure == .invalidKey { snapshot = nil }
            status = .failed(failure)
        }
    }

    private nonisolated static func storeError(_ error: Error) -> SecretStoreError {
        error as? SecretStoreError ?? .unexpected(errSecParam)
    }
}
