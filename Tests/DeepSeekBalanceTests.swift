import Foundation

/// DeepSeek balance: request, parsing, amounts, key hints, refresh policy and
/// the monitor. Offline: fixtures, an injected fake server and an in-memory
/// secret store; never the network or the user's Keychain.
@main
struct DeepSeekBalanceTests {
    @MainActor
    static func main() {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            if !condition() { failures.append("line \(line): \(message)") }
        }

        let fixtureDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("DeepSeek", isDirectory: true)
        func fixture(_ name: String) -> Data {
            (try? Data(contentsOf: fixtureDirectory.appendingPathComponent(name))) ?? Data()
        }
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: DeepSeekBalanceAPI.endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        }
        func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
        func parse(_ name: String, _ status: Int = 200) -> Result<DeepSeekBalance, DeepSeekBalanceFailure> {
            DeepSeekBalanceAPI.parse(data: fixture(name), response: response(status))
        }

        // MARK: Request

        let request = DeepSeekBalanceAPI.makeRequest(apiKey: "sk-test")
        expect(request.url?.absoluteString == "https://api.deepseek.com/user/balance", "endpoint")
        expect(request.httpMethod == "GET", "GET")
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test", "Bearer header, capital B")
        expect(request.value(forHTTPHeaderField: "Accept") == "application/json", "Accept header")
        expect(request.timeoutInterval == 15, "15 s timeout")
        expect(request.cachePolicy == .reloadIgnoringLocalCacheData, "no cached balances")
        expect(request.httpBody == nil, "no body")
        let configuration = DeepSeekBalanceAPI.session.configuration
        expect(configuration.urlCache == nil && configuration.httpCookieStorage == nil && configuration.urlCredentialStorage == nil,
               "ephemeral session keeps nothing")
        expect(configuration.timeoutIntervalForResource == 20 && !configuration.waitsForConnectivity, "session timeouts")
        expect(DeepSeekBalanceAPI.apiKeysPage.absoluteString == "https://platform.deepseek.com/api_keys", "API keys page")
        expect(DeepSeekBalanceAPI.topUpPage.absoluteString == "https://platform.deepseek.com/top_up", "top-up page")

        // MARK: Parsing

        expect(parse("200-cny.json") == .success(DeepSeekBalance(isAvailable: true, balances: [
            DeepSeekCurrencyBalance(currency: "CNY", total: dec("110.00"), granted: dec("10.00"), toppedUp: dec("100.00")),
        ])), "docs example parses")
        if case .success(let multi) = parse("200-multi.json") {
            expect(multi.balances.map(\.currency) == ["USD", "CNY"], "response order kept")
            expect(multi.sortedBalances.map(\.currency) == ["CNY", "USD"], "CNY sorts first")
            expect(multi.primary?.currency == "CNY" && multi.primary?.total == dec("23.45"), "CNY is the headline even when listed second")
        } else { failures.append("multi parses") }
        if case .success(let usd) = parse("200-usd.json") {
            expect(usd.primary?.currency == "USD" && usd.primary?.total == dec("4.87"), "USD-only account")
        } else { failures.append("usd parses") }
        if case .success(let empty) = parse("200-empty-infos.json") {
            expect(empty.primary == nil && !empty.isAvailable, "empty balance_infos")
        } else { failures.append("empty infos parses") }
        if case .success(let dry) = parse("200-exhausted.json") {
            expect(!dry.isAvailable && dry.primary?.total == 0, "exhausted balance")
        } else { failures.append("exhausted parses") }
        expect(parse("200-malformed.json") == .failure(.unreadableResponse), "non-numeric amount")
        expect(parse("200-html.txt") == .failure(.unreadableResponse), "HTML body")
        expect(parse("401-invalid-key.json", 401) == .failure(.invalidKey), "401 JSON")
        expect(parse("401-missing-header.txt", 401) == .failure(.invalidKey), "401 missing header text")
        expect(parse("401-malformed-header.txt", 401) == .failure(.invalidKey), "401 malformed header text")
        expect(parse("429.json", 429) == .failure(.rateLimited), "429")
        for code in [500, 502, 503, 504] {
            expect(DeepSeekBalanceAPI.parse(data: Data(), response: response(code)) == .failure(.serverUnavailable(code)), "\(code)")
        }
        expect(DeepSeekBalanceAPI.parse(data: Data(), response: response(418)) == .failure(.badStatus(418)), "418")
        expect(DeepSeekBalanceAPI.parse(data: Data(), response: response(402)) == .failure(.badStatus(402)), "402")
        expect(DeepSeekBalanceAPI.parse(data: Data(), response: URLResponse()) == .failure(.unreadableResponse), "non-HTTP")
        expect(DeepSeekBalanceAPI.failure(for: URLError(.timedOut)) == .timedOut, "timeout")
        expect(DeepSeekBalanceAPI.failure(for: URLError(.notConnectedToInternet)) == .unreachable, "offline")
        expect(DeepSeekBalanceAPI.failure(for: URLError(.cannotFindHost)) == .unreachable, "DNS")
        expect(DeepSeekBalanceAPI.failure(for: CancellationError()) == .unreachable, "other errors")
        let stable = DeepSeekBalance(isAvailable: true, balances: ["GBP", "USD", "EUR", "CNY", "AUD"].map {
            DeepSeekCurrencyBalance(currency: $0, total: 1, granted: 0, toppedUp: 1)
        })
        expect(stable.sortedBalances.map(\.currency) == ["CNY", "USD", "GBP", "EUR", "AUD"], "currency sort is stable")

        // MARK: Amounts and key hints

        expect(DeepSeekBalanceAPI.amount("110.00") == dec("110"), "string amount")
        expect(DeepSeekBalanceAPI.amount(NSNumber(value: 1.5)) == dec("1.5"), "number amount")
        expect(DeepSeekBalanceAPI.amount("-0.01") == dec("-0.01"), "negative amount")
        for bad: Any? in ["12abc", "", " ", "1,000.00", "NaN", "1e3", NSNumber(value: true), nil] {
            expect(DeepSeekBalanceAPI.amount(bad) == nil, "rejects amount \(String(describing: bad))")
        }
        expect(DeepSeekKeyHint.sanitize("  sk-test-0123456789abcdef0123456789abcdef\n") == "sk-test-0123456789abcdef0123456789abcdef", "trims paste")
        expect(DeepSeekKeyHint.sanitize("0123456789abcdef") == "0123456789abcdef", "sk- prefix not required")
        expect(DeepSeekKeyHint.sanitize("") == nil, "rejects empty")
        expect(DeepSeekKeyHint.sanitize(" \n") == nil, "rejects whitespace")
        expect(DeepSeekKeyHint.sanitize("sk-abc def") == nil, "rejects inner space")
        expect(DeepSeekKeyHint.sanitize("密钥") == nil, "rejects non-ASCII")
        expect(DeepSeekKeyHint.sanitize("sk-é123") == nil, "rejects accented letters")
        expect(DeepSeekKeyHint.sanitize(String(repeating: "a", count: 256)) != nil, "256 characters allowed")
        expect(DeepSeekKeyHint.sanitize(String(repeating: "a", count: 257)) == nil, "rejects over 256 characters")
        expect(DeepSeekKeyHint.hint(for: "sk-test-0123456789abcdef0123456789abab12") == "sk-…ab12", "hint")
        expect(DeepSeekKeyHint.hint(for: "abcdefghijklmnop") == "…mnop", "hint without sk-")
        expect(DeepSeekKeyHint.hint(for: "sk-short") == nil && DeepSeekKeyHint.hint(for: "12345678901") == nil, "no hint under 12 characters")
        expect(DeepSeekKeyHint.hint(for: "123456789012") == "…9012", "hint at 12 characters")
        expect(DeepSeekKeyHint.display(hint: "sk-…ab12") == "已保存 · sk-…ab12", "display with hint")
        expect(DeepSeekKeyHint.display(hint: nil) == "已保存" && DeepSeekKeyHint.display(hint: "") == "已保存", "display without hint")

        // MARK: Policy

        let policy = DeepSeekRefreshPolicy()
        expect(policy == DeepSeekRefreshPolicy(entryFreshness: 60, freshness: 300, manualFloor: 10, retryDelays: [30, 60, 120, 300]), "defaults")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func due(_ seconds: TimeInterval, success: Bool = true, failures: Int = 0, failure: DeepSeekBalanceFailure? = nil, entry: Bool = false) -> Bool {
            policy.isDue(now: t0.addingTimeInterval(seconds), lastAttempt: t0, lastSuccess: success ? t0 : nil,
                         failures: failures, lastFailure: failure, onEntry: entry)
        }
        expect(policy.isDue(now: t0, lastAttempt: nil, lastSuccess: nil, failures: 0, lastFailure: nil, onEntry: false), "first fetch due")
        expect(!due(59, entry: true), "entry reuses a balance younger than 60 s")
        expect(due(60, entry: true), "entry refetches after 60 s")
        expect(!due(299), "ticks keep a balance for 5 min")
        expect(due(300), "ticks refetch after 5 min")
        for (failures, delay) in [(1, 30.0), (2, 60.0), (3, 120.0), (4, 300.0), (9, 300.0)] {
            expect(!due(delay - 1, success: false, failures: failures, failure: .unreachable), "retry \(failures) waits \(delay) s")
            expect(due(delay, success: false, failures: failures, failure: .unreachable), "retry \(failures) after \(delay) s")
        }
        expect(!due(29, success: false, failures: 1, failure: .serverUnavailable(503), entry: true), "backoff applies on entry too")
        expect(!due(86_400, success: false, failures: 1, failure: .invalidKey), "401 never auto-retries")
        expect(!due(86_400, success: false, failures: 1, failure: .invalidKey, entry: true), "401 never retries on entry")
        expect(!due(5, success: false), "a stopped Keychain read does not retry on ticks")
        expect(due(5, success: false, entry: true), "a stopped Keychain read retries on entry")

        // MARK: Monitor

        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 2_000_000) }
        let key = "sk-test-0123456789abcdef0123456789abab12"

        do { // no key: nothing to fetch
            let clock = Clock()
            let store = InMemorySecretStore()
            let server = FakeDeepSeekServer(status: 200, body: fixture("200-cny.json"))
            let monitor = DeepSeekBalanceMonitor(store: store, fetch: server.fetch, now: { clock.now }, tickInterval: 3600)
            expect(monitor.keyState == .unknown && monitor.status == .idle, "initial state")
            monitor.tick()
            aiTestSettle(0.05)
            expect(store.readCount == 0, "inactive monitor never reads the store")
            monitor.setActive(true)
            expect(aiTestWaitUntil { monitor.status == .notConfigured }, "no key → notConfigured")
            expect(monitor.keyState == .missing && server.requestCount == 0, "no request without a key")
            let reads = store.readCount
            monitor.setActive(false)
            monitor.setActive(true)
            clock.now.addTimeInterval(600)
            monitor.tick(onEntry: true)
            aiTestSettle()
            expect(store.readCount == reads && server.requestCount == 0, "a missing key is not re-read on entry")
            monitor.refreshManually()
            expect(!monitor.isRefreshing && server.requestCount == 0, "manual refresh needs a key")
        }

        do { // saved key: fetch on entry, reuse, refresh, manual floor, failures
            let clock = Clock()
            let store = InMemorySecretStore(secret: key, hint: "sk-…ab12")
            let server = FakeDeepSeekServer(status: 200, body: fixture("200-cny.json"))
            let monitor = DeepSeekBalanceMonitor(store: store, fetch: server.fetch, now: { clock.now }, tickInterval: 3600)
            monitor.setActive(true)
            expect(monitor.isRefreshing && monitor.status == .loading, "entry starts a fetch")
            expect(aiTestWaitUntil { monitor.status == .loaded }, "loads when shown")
            expect(!monitor.isRefreshing, "refresh finished")
            expect(server.requestCount == 1, "one fetch")
            expect(server.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)", "uses the stored key")
            expect(monitor.snapshot?.balance.primary?.total == dec("110") && monitor.snapshot?.fetchedAt == clock.now, "snapshot")
            expect(monitor.keyState == .saved(hint: "sk-…ab12"), "key state learned from the read")

            clock.now.addTimeInterval(30)
            monitor.setActive(false)
            monitor.setActive(true)
            aiTestSettle()
            expect(server.requestCount == 1, "reopening within 60 s reuses the balance")
            clock.now.addTimeInterval(31)
            monitor.setActive(false)
            monitor.setActive(true)
            expect(aiTestWaitUntil { server.requestCount == 2 }, "reopening after 60 s refetches")
            _ = aiTestWaitUntil { !monitor.isRefreshing }

            clock.now.addTimeInterval(299)
            monitor.tick()
            aiTestSettle()
            expect(server.requestCount == 2, "ticks keep the balance for 5 min")
            clock.now.addTimeInterval(1)
            monitor.tick()
            expect(aiTestWaitUntil { server.requestCount == 3 }, "ticks refetch after 5 min")
            _ = aiTestWaitUntil { !monitor.isRefreshing }
            expect(store.readCount == 1, "Keychain read once, then the key stays in memory")

            monitor.refreshManually()
            aiTestSettle()
            expect(server.requestCount == 3, "manual refresh ignored within 10 s")
            clock.now.addTimeInterval(10)
            monitor.setActive(false)
            monitor.refreshManually()
            expect(aiTestWaitUntil { server.requestCount == 4 }, "manual refresh bypasses the cache, even while hidden")
            _ = aiTestWaitUntil { !monitor.isRefreshing }
            monitor.setActive(true)

            server.respond(503)
            clock.now.addTimeInterval(301)
            monitor.tick()
            expect(aiTestWaitUntil { monitor.status == .failed(.serverUnavailable(503)) }, "server error surfaces")
            expect(monitor.snapshot?.balance.primary?.total == dec("110"), "previous snapshot kept through a 503")
            let afterFailure = server.requestCount
            clock.now.addTimeInterval(29)
            monitor.tick()
            aiTestSettle()
            expect(server.requestCount == afterFailure, "retry waits 30 s")
            clock.now.addTimeInterval(1)
            server.fail(.timedOut)
            monitor.tick()
            expect(aiTestWaitUntil { monitor.status == .failed(.timedOut) }, "timeout surfaces")
            clock.now.addTimeInterval(59)
            monitor.tick()
            aiTestSettle()
            expect(server.requestCount == afterFailure + 1, "second retry waits 60 s")

            server.respond(401, fixture("401-invalid-key.json"))
            clock.now.addTimeInterval(1)
            monitor.tick()
            expect(aiTestWaitUntil { monitor.status == .failed(.invalidKey) }, "401 surfaces")
            expect(monitor.snapshot == nil, "401 clears the balance")
            let before401 = server.requestCount
            clock.now.addTimeInterval(86_400)
            monitor.tick()
            monitor.setActive(false)
            monitor.setActive(true)
            aiTestSettle()
            expect(server.requestCount == before401, "401 does not retry automatically, even on entry")

            // Saving a new key validates it immediately.
            server.respond(200, fixture("200-usd.json"))
            var saved: Bool?
            Task { saved = await monitor.saveKey("  sk-test-ffffffffffffffffffffffffffffcd34 \n") }
            expect(aiTestWaitUntil { saved == true && monitor.status == .loaded }, "save + validate")
            expect(monitor.keyState == .saved(hint: "sk-…cd34"), "hint after save")
            expect(store.storedSecret == "sk-test-ffffffffffffffffffffffffffffcd34", "trimmed key stored")
            expect(server.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-ffffffffffffffffffffffffffffcd34", "new key used")
            var rejected: Bool?
            let writes = store.writeCount
            Task { rejected = await monitor.saveKey("不是密钥") }
            expect(aiTestWaitUntil { rejected == false }, "invalid paste rejected")
            expect(store.writeCount == writes && monitor.status == .loaded, "invalid paste changes nothing")
            monitor.setActive(false)
        }

        do { // saving while hidden validates once; Keychain write errors surface
            let clock = Clock()
            let store = InMemorySecretStore()
            let server = FakeDeepSeekServer(status: 200, body: fixture("200-cny.json"))
            let monitor = DeepSeekBalanceMonitor(store: store, fetch: server.fetch, now: { clock.now }, tickInterval: 3600)
            var ok: Bool?
            Task { ok = await monitor.saveKey(key) }
            expect(aiTestWaitUntil { ok == true && monitor.status == .loaded }, "inactive save validates immediately")
            expect(server.requestCount == 1 && store.readCount == 0, "validation uses the saved key without reading it back")
            store.writeError = .unexpected(-25_299)
            var failed: Bool?
            Task { failed = await monitor.saveKey(key) }
            expect(aiTestWaitUntil { failed == false }, "write error reported")
            expect(monitor.status == .keychainError(.unexpected(-25_299)), "write error status")
            expect(monitor.snapshot != nil, "a failed save keeps the previous balance")
        }

        do { // a rebuilt binary: silent read refused → ask, never prompt on its own
            let clock = Clock()
            let store = InMemorySecretStore(secret: key, hint: "sk-…ab12")
            store.silentReadError = .accessRequired
            let server = FakeDeepSeekServer(status: 200, body: fixture("200-cny.json"))
            let monitor = DeepSeekBalanceMonitor(store: store, fetch: server.fetch, now: { clock.now }, tickInterval: 3600)
            monitor.setActive(true)
            expect(aiTestWaitUntil { monitor.status == .needsKeychainAccess }, "needs Keychain access")
            expect(server.requestCount == 0 && store.interactiveReadCount == 0, "no fetch, no dialog")
            let silentReads = store.readCount
            clock.now.addTimeInterval(3600)
            monitor.tick()
            monitor.refreshManually()
            aiTestSettle()
            expect(store.readCount == silentReads + 1 && monitor.status == .needsKeychainAccess, "ticks never retry; a manual refresh retries silently")
            monitor.setActive(false)
            clock.now.addTimeInterval(20)
            monitor.setActive(true)
            expect(aiTestWaitUntil { store.readCount == silentReads + 2 }, "re-entry retries silently")
            expect(store.interactiveReadCount == 0, "still no dialog")
            _ = aiTestWaitUntil { !monitor.isRefreshing }
            monitor.authorizeKeychainAccess()
            expect(aiTestWaitUntil { monitor.status == .loaded }, "authorize then load")
            expect(store.interactiveReadCount == 1, "exactly one interactive read")

            store.interactiveReadError = .denied
            let denied = DeepSeekBalanceMonitor(store: store, fetch: server.fetch, now: { clock.now }, tickInterval: 3600)
            store.silentReadError = .accessRequired
            denied.authorizeKeychainAccess()
            expect(aiTestWaitUntil { denied.status == .needsKeychainAccess }, "a declined dialog asks again later")
        }

        do { // a late response for an old key is dropped
            let clock = Clock()
            let store = InMemorySecretStore(secret: key, hint: "sk-…ab12")
            let server = FakeDeepSeekServer()
            server.script([.response(status: 200, body: fixture("200-cny.json")), .response(status: 200, body: fixture("200-usd.json"))])
            server.delay = 0.3
            let monitor = DeepSeekBalanceMonitor(store: store, fetch: server.fetch, now: { clock.now }, tickInterval: 3600)
            monitor.setActive(true)
            expect(aiTestWaitUntil { server.requestCount == 1 }, "old key request sent")
            server.delay = 0
            var saved: Bool?
            Task { saved = await monitor.saveKey("sk-test-eeeeeeeeeeeeeeeeeeeeeeeeeeeeee99") }
            expect(aiTestWaitUntil { saved == true && monitor.status == .loaded }, "new key loads")
            aiTestSettle(0.5)
            expect(monitor.snapshot?.balance.primary?.currency == "USD", "the old key's late CNY response was dropped")
            expect(monitor.status == .loaded && !monitor.isRefreshing, "state settled")
            monitor.setActive(false)
        }

        do { // metadata, delete and delete failures
            let clock = Clock()
            let store = InMemorySecretStore(secret: key, hint: "sk-…ab12")
            let server = FakeDeepSeekServer(status: 200, body: fixture("200-cny.json"))
            let monitor = DeepSeekBalanceMonitor(store: store, fetch: server.fetch, now: { clock.now }, tickInterval: 3600)
            var loaded = false
            Task { await monitor.reloadKeyState(); loaded = true }
            expect(aiTestWaitUntil { loaded }, "metadata loads")
            expect(monitor.keyState == .saved(hint: "sk-…ab12") && store.readCount == 0 && server.requestCount == 0, "metadata never reads the secret")
            monitor.refreshManually()
            expect(aiTestWaitUntil { monitor.status == .loaded }, "loaded before delete")

            store.deleteError = .notOwner
            var deleted = false
            Task { await monitor.deleteKey(); deleted = true }
            expect(aiTestWaitUntil { deleted }, "failing delete finishes")
            expect(monitor.status == .keychainError(.notOwner) && monitor.keyState == .saved(hint: "sk-…ab12"), "notOwner delete reported, key kept")

            store.deleteError = nil
            deleted = false
            Task { await monitor.deleteKey(); deleted = true }
            expect(aiTestWaitUntil { deleted }, "delete finishes")
            expect(monitor.status == .notConfigured && monitor.snapshot == nil && monitor.keyState == .missing, "deleted state")
            expect(store.deleteCount == 2 && store.storedSecret == nil, "store emptied")
            loaded = false
            Task { await monitor.reloadKeyState(); loaded = true }
            expect(aiTestWaitUntil { loaded } && monitor.keyState == .missing, "metadata after delete")
        }

        if failures.isEmpty {
            print("All DeepSeek balance tests passed.")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
