import Foundation

/// Secret store for tests; never touches the Keychain.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: String?
    private var hint: String?
    private var modifiedAt: Date?
    private var _silentReadError: SecretStoreError?
    private var _interactiveReadError: SecretStoreError?
    private var _writeError: SecretStoreError?
    private var _deleteError: SecretStoreError?
    private var _readCount = 0
    private var _interactiveReadCount = 0
    private var _writeCount = 0
    private var _deleteCount = 0

    init(secret: String? = nil, hint: String? = nil) {
        self.secret = secret
        self.hint = hint
        modifiedAt = secret == nil ? nil : Date(timeIntervalSince1970: 0)
    }

    /// When set, non-interactive reads of an existing item throw it (a rebuilt binary).
    var silentReadError: SecretStoreError? {
        get { locked { _silentReadError } }
        set { locked { _silentReadError = newValue } }
    }

    /// When set, interactive reads throw it (the user clicked 拒绝).
    var interactiveReadError: SecretStoreError? {
        get { locked { _interactiveReadError } }
        set { locked { _interactiveReadError = newValue } }
    }

    var writeError: SecretStoreError? {
        get { locked { _writeError } }
        set { locked { _writeError = newValue } }
    }

    var deleteError: SecretStoreError? {
        get { locked { _deleteError } }
        set { locked { _deleteError = newValue } }
    }

    var readCount: Int { locked { _readCount } }
    var interactiveReadCount: Int { locked { _interactiveReadCount } }
    var writeCount: Int { locked { _writeCount } }
    var deleteCount: Int { locked { _deleteCount } }
    var storedSecret: String? { locked { secret } }

    func metadata() throws -> SecretMetadata? {
        locked { secret == nil ? nil : SecretMetadata(hint: hint, modifiedAt: modifiedAt) }
    }

    func read(allowUI: Bool) throws -> String? {
        try locked {
            _readCount += 1
            if allowUI {
                _interactiveReadCount += 1
                if let error = _interactiveReadError { throw error }
            } else if secret != nil, let error = _silentReadError {
                throw error
            }
            return secret
        }
    }

    func write(_ secret: String, hint: String?) throws {
        try locked {
            _writeCount += 1
            if let error = _writeError { throw error }
            self.secret = secret
            self.hint = hint
            modifiedAt = Date()
            _silentReadError = nil
        }
    }

    func delete(allowUI: Bool) throws {
        try locked {
            _deleteCount += 1
            if let error = _deleteError { throw error }
            secret = nil
            hint = nil
            modifiedAt = nil
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Stands in for api.deepseek.com. Replies are consumed in order; the last one
/// repeats. Never opens a socket.
final class FakeDeepSeekServer: @unchecked Sendable {
    enum Reply {
        case response(status: Int, body: Data)
        case failure(URLError)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var _delay: TimeInterval = 0
    private var _requests: [URLRequest] = []

    init(status: Int = 200, body: Data = Data()) {
        replies = [.response(status: status, body: body)]
    }

    /// Seconds each reply waits before answering.
    var delay: TimeInterval {
        get { locked { _delay } }
        set { locked { _delay = newValue } }
    }

    var requests: [URLRequest] { locked { _requests } }
    var requestCount: Int { locked { _requests.count } }

    func respond(_ status: Int, _ body: Data = Data()) {
        locked { replies = [.response(status: status, body: body)] }
    }

    func fail(_ code: URLError.Code) {
        locked { replies = [.failure(URLError(code))] }
    }

    func script(_ scripted: [Reply]) {
        locked { replies = scripted }
    }

    var fetch: DeepSeekBalanceAPI.Fetch {
        { [self] request in try await self.handle(request) }
    }

    private func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (reply, delay): (Reply, TimeInterval) = locked {
            _requests.append(request)
            let reply = replies.count > 1 ? replies.removeFirst() : replies[0]
            return (reply, _delay)
        }
        if delay > 0 {
            // Deliberately ignores cancellation, like a response already on the wire.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume() }
            }
        }
        switch reply {
        case .response(let status, let body):
            let response = HTTPURLResponse(
                url: request.url ?? DeepSeekBalanceAPI.endpoint,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        case .failure(let error):
            throw error
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Pumps the main run loop until the condition holds or the timeout elapses,
/// so timers and main-actor tasks can run.
@MainActor
func aiTestWaitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return true
}

/// Lets queued main-actor work run for a while (to show that nothing happens).
@MainActor
func aiTestSettle(_ duration: TimeInterval = 0.2) {
    _ = aiTestWaitUntil(timeout: duration) { false }
}
