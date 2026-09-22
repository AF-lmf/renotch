import Combine
import Foundation

/// Codex rate-limit parser, line scanner, incremental reader and monitor, run
/// against synthetic fixtures in temporary CODEX_HOME directories.
@main
struct CodexUsageTests {
    @MainActor
    static func main() {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            if !condition() { failures.append("line \(line): \(message)") }
        }

        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("Codex", isDirectory: true)
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("renotch-codex-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }

        func date(_ s: String) -> Date { CodexRateLimitLineParser.parseTimestamp(s)! }
        func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
        func lines(_ url: URL) -> [String] {
            (try! String(contentsOf: url, encoding: .utf8)).components(separatedBy: "\n")
        }

        /// Creates a CODEX_HOME with the given (relative path, fixture or raw text, mtime) files.
        func makeHome(_ name: String, _ files: [(String, String, Date)]) -> URL {
            let home = temp.appendingPathComponent(name, isDirectory: true)
            try! fm.createDirectory(at: home, withIntermediateDirectories: true)
            for (path, source, mtime) in files {
                let url = home.appendingPathComponent(path)
                try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if source.hasSuffix(".jsonl") {
                    try! fm.copyItem(at: fixture(source), to: url)
                } else {
                    try! source.write(to: url, atomically: true, encoding: .utf8)
                }
                try! fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
            }
            return home
        }

        // MARK: Window titles (through AIUsageFormatting)

        do {
            let window = { (minutes: Int) in CodexRateWindow(usedPercent: 1, windowMinutes: minutes, resetsAt: nil).label }
            expect(window(300) == "5 小时", "300")
            expect(window(299) == "5 小时", "299 snaps")
            expect(window(10080) == "每周", "10080")
            expect(window(10079) == "每周", "10079 snaps")
            expect(window(1440) == "每天", "1440")
            expect(window(43200) == "每月", "30 days")
            expect(window(90) == "90 分钟", "90")
        }

        // MARK: Timestamp parsing

        expect(date("2026-09-18T07:24:55.000Z").timeIntervalSince1970 == 1789716295, "fast path")
        expect(abs(date("2026-09-18T07:24:55.123Z").timeIntervalSince1970 - 1789716295.123) < 0.0005, "fraction")
        expect(CodexRateLimitLineParser.parseTimestamp("2026-09-18T15:24:55+08:00")?.timeIntervalSince1970 == 1789716295, "offset via slow path")
        expect(CodexRateLimitLineParser.parseTimestamp("garbage") == nil, "garbage")

        // MARK: Line parser on fixtures

        do {
            let ls = lines(fixture("codex-weekly-only.jsonl")).filter { !$0.isEmpty }
            let parsed = ls.compactMap { CodexRateLimitLineParser.parse(Data($0.utf8)) }
            expect(parsed.count == 2, "two token_count lines parse, filler/meta do not")
            let last = parsed.last!
            expect(last.limitID == "codex" && last.isMain, "main id")
            expect(last.windows == [CodexRateWindow(usedPercent: 85, windowMinutes: 10080, resetsAt: Date(timeIntervalSince1970: 1790064534))], "weekly only window")
            expect(last.credits == CodexCredits(hasCredits: false, unlimited: false, balance: "0"), "credits")
            expect(last.planType == nil && last.reachedType == nil, "nulls")
            expect(last.observedAt == date("2026-09-18T07:24:55.000Z"), "observedAt from event timestamp")
        }
        do {
            let s = lines(fixture("codex-five-hour-and-weekly.jsonl")).compactMap { CodexRateLimitLineParser.parse(Data($0.utf8)) }.first!
            expect(s.windows.map(\.label) == ["5 小时", "每周"], "primary then secondary")
            expect(s.windows.map(\.usedPercent) == [12, 40], "five-hour and weekly values")
            expect(s.credits == nil && s.planDisplayName == "Pro Lite", "credits null, plan")
        }
        do {
            let s = lines(fixture("codex-legacy-resets-in-seconds.jsonl")).compactMap { CodexRateLimitLineParser.parse(Data($0.utf8)) }.first!
            expect(s.limitID == "codex", "missing limit_id means main bucket")
            expect(s.windows.map(\.windowMinutes) == [299, 10079], "legacy lengths kept")
            expect(s.windows.map(\.label) == ["5 小时", "每周"], "legacy labels snap")
            expect(s.windows.first?.resetsAt == s.observedAt.addingTimeInterval(3600), "resets_in_seconds is relative to the event")
        }
        do {
            let raw = lines(fixture("codex-edge-cases.jsonl"))
            let parsed = raw.map { CodexRateLimitLineParser.parse(Data($0.utf8)) }
            expect(parsed.compactMap { $0 }.count == 4, "main, windowless main, window-0 spark, premium parse; null rate_limits/decoy/partial do not")
            expect(parsed.compactMap { $0 }.filter { !$0.windows.isEmpty }.count == 1, "only one windowed snapshot")
            let decoy = raw.first { $0.contains("user pasted") }!
            let matched = Data(decoy.utf8).withUnsafeBytes { CodexRateLimitLineParser.mightContainRateLimits($0) }
            expect(!matched, "escaped JSON inside message text does not pass the byte filter")
            let long = raw.first { $0.utf8.count > CodexRateLimitLineParser.maxLineLength }!
            let longMatched = Data(long.utf8).withUnsafeBytes { CodexRateLimitLineParser.mightContainRateLimits($0) }
            expect(!longMatched, "lines over 16 KB are skipped")
            var padded = lines(fixture("codex-weekly-only.jsonl"))[4]
            padded = padded.replacingOccurrences(of: "\"ordinal\":13", with: "\"ordinal\":13,\"pad\":\"\(String(repeating: "x", count: 17_000))\"")
            let paddedMatched = Data(padded.utf8).withUnsafeBytes { CodexRateLimitLineParser.mightContainRateLimits($0) }
            expect(!paddedMatched, "a real rate_limits line over 16 KB is skipped too")
        }

        // MARK: Line scanner

        do {
            let url = fixture("codex-edge-cases.jsonl")
            let size = UInt64(try! fm.attributesOfItem(atPath: url.path)[.size] as! Int)
            let all = lines(url)
            let completeEnd = size - UInt64(all.last!.utf8.count)       // start of the unfinished tail
            let expected = Array(all.dropLast()).filter { $0.utf8.count <= CodexRateLimitLineParser.maxLineLength }
            for chunk in [1, 7, 64, 1000, 16 * 1024, 64 * 1024] {
                var scanner = CodexLogLineScanner()
                scanner.chunkSize = chunk
                var back: [String] = []
                let r = scanner.scanBackward(url: url, end: size, byteBudget: .max) { back.append(String(decoding: $0, as: UTF8.self)); return true }
                expect(back == expected.reversed(), "backward lines match, chunk \(chunk)")
                expect(r.resumeOffset == 0 && r.completeEnd == completeEnd && r.bytesRead == Int(size), "backward offsets, chunk \(chunk)")
                var fwd: [String] = []
                let f = scanner.scanForward(url: url, from: 0, to: size, byteBudget: .max) { fwd.append(String(decoding: $0, as: UTF8.self)) }
                expect(fwd == expected && f.completeEnd == completeEnd, "forward lines match and stop before the unfinished tail, chunk \(chunk)")
                // Resumable backward exploration with a tiny budget visits every line exactly once.
                var resumed: [String] = []
                var end = size
                var rounds = 0
                while end > 0, rounds < 10_000 {
                    let step = scanner.scanBackward(url: url, end: end, byteBudget: CodexRateLimitLineParser.maxLineLength + 1) {
                        resumed.append(String(decoding: $0, as: UTF8.self))
                        return true
                    }
                    expect(step.resumeOffset < end, "resumable scan progresses, chunk \(chunk)")
                    end = step.resumeOffset
                    rounds += 1
                }
                expect(resumed == expected.reversed(), "resumed backward lines match, chunk \(chunk)")
            }
            var stops = 0
            let r = CodexLogLineScanner().scanBackward(url: url, end: size, byteBudget: .max) { _ in stops += 1; return false }
            expect(stops == 1 && r.resumeOffset > 0, "visitor can stop; resume point is that line's start")
        }

        // MARK: Reader over a temporary CODEX_HOME

        let now = date("2026-09-18T08:10:00.000Z")
        do {
            let home = makeHome("missing", [])
            try? fm.removeItem(at: home)
            expect(CodexRateLimitReader(codexHome: home).read(now: now).status == .codexNotFound, "no CODEX_HOME")
            let empty = makeHome("empty", [("sessions/2026/09/18/rollout-a.jsonl", "{\"timestamp\":\"2026-09-18T08:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{}}\n", now)])
            let r = CodexRateLimitReader(codexHome: empty).read(now: now)
            expect(r.status == .noRateLimits && r.main == nil, "logs without rate limits")
        }
        do {
            let home = makeHome("weekly", [("sessions/2026/09/18/rollout-w.jsonl", "codex-weekly-only.jsonl", date("2026-09-18T07:24:58.000Z"))])
            let r = CodexRateLimitReader(codexHome: home).read(now: now)
            expect(r.status == .ok && r.main?.windows.first?.usedPercent == 85, "weekly-only: main 85%")
        }
        do { // edge cases file: newest valid main wins over partial/windowless/decoy lines
            let home = makeHome("edge", [("sessions/2026/09/18/rollout-e.jsonl", "codex-edge-cases.jsonl", date("2026-09-18T08:00:13.000Z"))])
            let r = CodexRateLimitReader(codexHome: home).read(now: now)
            expect(r.main?.windows.first?.usedPercent == 70 && r.main?.observedAt == date("2026-09-18T08:00:05.000Z"), "edge: main 70% @08:00:05")
            expect(r.additional.isEmpty, "edge: window-0 spark and premium are not shown")
        }
        do { // Account-wide limits are sufficient to skip older-mtime files.
            let home = makeHome("stop", [
                ("sessions/2026/09/18/rollout-new.jsonl", "codex-weekly-only.jsonl", date("2026-09-18T07:24:58.000Z")),
                // inconsistent on purpose: newer events but an older mtime
                ("sessions/2026/09/17/rollout-old.jsonl", "codex-edge-cases.jsonl", date("2026-09-18T07:00:00.000Z")),
            ])
            let r = CodexRateLimitReader(codexHome: home).read(now: now)
            expect(r.main?.windows.first?.usedPercent == 85, "stop: main from newest file")
            expect(r.scannedFiles == 1, "stop: older file not opened (scanned \(r.scannedFiles))")
        }
        do { // Retired Spark history does not prolong account-wide history scans.
            let main = lines(fixture("codex-weekly-only.jsonl"))[4] + "\n"
            let spark = lines(fixture("codex-spark-after-main.jsonl"))[4] + "\n"
            for sameFile in [true, false] {
                let inputs: [(String, String, Date)] = sameFile
                    ? [("sessions/rollout-both.jsonl", spark + main, now)]
                    : [("sessions/rollout-main.jsonl", main, now),
                       ("sessions/rollout-spark.jsonl", spark, date("2026-09-17T14:28:00.000Z"))]
                let home = makeHome("spark-older-\(sameFile)", inputs)
                let reader = CodexRateLimitReader(codexHome: home)
                let r = reader.read(now: now)
                expect(r.main?.windows.first?.usedPercent == 85, "older Spark preserves main")
                expect(r.additional.isEmpty, "older Spark not searched, same file: \(sameFile)")
                expect(r.isComplete && r.scannedFiles == 1, "account-wide record completes history without Spark")
                expect(reader.read(now: now).scannedBytes == 0, "unchanged Spark history not reread")
                let aged = reader.read(now: now.addingTimeInterval(9 * 86400))
                expect(aged.main == nil && aged.additional.isEmpty, "cached buckets age out")
            }
        }
        do { // spark events after main in the same file
            let home = makeHome("spark", [("sessions/2026/09/17/rollout-s.jsonl", "codex-spark-after-main.jsonl", date("2026-09-17T14:28:00.000Z"))])
            let r = CodexRateLimitReader(codexHome: home).read(now: now)
            expect(r.main?.windows.first?.usedPercent == 60, "spark: main found behind model bucket")
            expect(r.additional.map(\.limitID) == ["codex_bengalfox"], "spark: model bucket listed")
            expect(r.additional.first?.windows.first?.usedPercent == 1 && r.additional.first?.displayName == "GPT-5.3-Codex-Spark", "spark: newest model bucket value")
        }
        do { // fall back to an older file; model bucket from the newer one; archived_sessions is searched
            let sparkOnly = lines(fixture("codex-spark-after-main.jsonl")).filter { !$0.contains("\"limit_id\":\"codex\"") }.joined(separator: "\n")
            let home = makeHome("fallback", [
                ("sessions/2026/09/18/rollout-spark.jsonl", sparkOnly, date("2026-09-18T08:00:00.000Z")),
                ("archived_sessions/rollout-archived.jsonl", "codex-five-hour-and-weekly.jsonl", date("2026-09-10T00:00:00.000Z")),
            ])
            var wide = CodexRateLimitReader.Limits()
            wide.maxAge = 400 * 24 * 3600 // fixture events are from July
            let r = CodexRateLimitReader(codexHome: home, limits: wide).read(now: now)
            expect(r.main?.windows.map(\.windowMinutes) == [300, 10080], "fallback: main from archived file")
            expect(r.additional.first?.limitID == "codex_bengalfox", "fallback: spark kept")
            expect(r.scannedFiles == 2, "fallback: both files opened")
        }
        do { // concurrent sessions: later event wins even when its file mtime is a bit older
            let a = lines(fixture("codex-weekly-only.jsonl"))[4] // 85% @07:24:55
            let b = a.replacingOccurrences(of: "2026-09-18T07:24:55.000Z", with: "2026-09-18T07:24:57.000Z")
                .replacingOccurrences(of: "\"used_percent\":85.0", with: "\"used_percent\":86.0")
            let home = makeHome("concurrent", [
                ("sessions/2026/09/18/rollout-x.jsonl", a + "\n", date("2026-09-18T07:24:59.000Z")),
                ("sessions/2026/09/17/rollout-y.jsonl", b + "\n", date("2026-09-18T07:24:58.000Z")),
            ])
            let r = CodexRateLimitReader(codexHome: home).read(now: now)
            expect(r.main?.windows.first?.usedPercent == 86, "concurrent: newest event timestamp wins")
        }
        do { // only rollout-*.jsonl files at most four levels deep are read
            let line = lines(fixture("codex-weekly-only.jsonl"))[4] + "\n"
            let home = makeHome("names", [
                ("sessions/2026/09/18/other.jsonl", line, now),
                ("sessions/2026/09/18/rollout-x.json", line, now),
                ("sessions/2026/09/18/extra/rollout-deep.jsonl", line, now),
            ])
            let r = CodexRateLimitReader(codexHome: home).read(now: now)
            expect(r.main == nil && r.scannedFiles == 0, "names: other files and deeper folders are ignored")
        }
        do { // incremental: unchanged files cost nothing, appended bytes are read forward only
            let sparkOnly = lines(fixture("codex-spark-after-main.jsonl")).filter { !$0.contains("\"limit_id\":\"codex\"") }.joined(separator: "\n")
            let home = makeHome("incremental", [("sessions/2026/09/18/rollout-spark.jsonl", sparkOnly, date("2026-09-18T08:00:00.000Z"))])
            let reader = CodexRateLimitReader(codexHome: home)
            let first = reader.read(now: now)
            let second = reader.read(now: now)
            expect(first.scannedBytes > 0 && second.scannedBytes == 0, "incremental: second read reads nothing")
            expect(second.additional.first?.limitID == "codex_bengalfox" && second.main == nil, "incremental: state kept")
            let url = home.appendingPathComponent("sessions/2026/09/18/rollout-spark.jsonl")
            let mainLine = lines(fixture("codex-weekly-only.jsonl"))[4].replacingOccurrences(of: "2026-09-18T07:24:55.000Z", with: "2026-09-18T08:00:30.000Z")
            let half = mainLine.utf8.count / 2
            func append(_ text: String) {
                let handle = try! FileHandle(forWritingTo: url)
                try! handle.seekToEnd()
                try! handle.write(contentsOf: Data(text.utf8))
                try! handle.close()
            }
            append(String(mainLine.prefix(half)))
            let third = reader.read(now: now)
            expect(third.main == nil, "incremental: unfinished line ignored")
            append(String(mainLine.dropFirst(half)) + "\n")
            let fourth = reader.read(now: now)
            expect(fourth.main?.windows.first?.usedPercent == 85 && fourth.main?.observedAt == date("2026-09-18T08:00:30.000Z"), "incremental: completed line found")
            expect(fourth.scannedBytes == mainLine.utf8.count + 1, "incremental: only the appended line is read (\(fourth.scannedBytes))")
            // Moving to archived_sessions (Codex archives by rename) keeps the answer.
            let archived = home.appendingPathComponent("archived_sessions/rollout-spark.jsonl")
            try! fm.createDirectory(at: archived.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! fm.moveItem(at: url, to: archived)
            let fifth = reader.read(now: now)
            expect(fifth.main?.windows.first?.usedPercent == 85, "incremental: archived move keeps main")
            // A rewritten (smaller) file is explored again.
            try! (lines(fixture("codex-five-hour-and-weekly.jsonl")).joined(separator: "\n")).write(to: archived, atomically: true, encoding: .utf8)
            try! fm.setAttributes([.modificationDate: date("2026-09-18T08:05:00.000Z")], ofItemAtPath: archived.path)
            let sixth = reader.read(now: now)
            expect(sixth.main?.windows.first?.usedPercent == 85, "incremental: older rewritten content does not replace a newer main")
        }
        do { // horizon: a recently touched file whose events are older than maxAge yields nothing
            let home = makeHome("horizon", [("sessions/2026/07/01/rollout-old.jsonl", "codex-five-hour-and-weekly.jsonl", now)])
            let r = CodexRateLimitReader(codexHome: home).read(now: now)
            expect(r.main == nil && r.status == .noRateLimits, "horizon: July events ignored in September")
        }
        do { // budgets: exploration resumes on later refreshes; age filter
            let home = makeHome("budget", [("sessions/2026/09/17/rollout-s.jsonl", "codex-spark-after-main.jsonl", date("2026-09-17T14:28:00.000Z"))])
            var limits = CodexRateLimitReader.Limits()
            limits.backwardBytesPerFile = 900 // below maxLineLength only to force several rounds
            let reader = CodexRateLimitReader(codexHome: home, limits: limits)
            let r = reader.read(now: now)
            expect(r.main == nil && r.scannedBytes <= 900 && !r.isComplete, "budget: first refresh stops at the budget")
            var found: CodexUsageReading?
            for _ in 0..<5 {
                let next = reader.read(now: now)
                if next.isComplete { found = next; break }
            }
            expect(found?.main?.windows.first?.usedPercent == 60 && found?.isComplete == true, "budget: later refreshes resume and find main")
            var aged = CodexRateLimitReader.Limits()
            aged.maxAge = 3600
            let r2 = CodexRateLimitReader(codexHome: home, limits: aged).read(now: now)
            expect(r2.scannedFiles == 0 && r2.status == .noRateLimits, "age: old file ignored")
        }

        // MARK: Display semantics

        do {
            let reset = date("2026-09-18T08:10:00.000Z")
            let w = { (u: Double, r: Date?) in CodexRateWindow(usedPercent: u, windowMinutes: 10080, resetsAt: r) }
            let later = reset.addingTimeInterval(3600)
            expect(!w(100, later).hasReset(at: reset), "not reset before resetsAt")
            expect(w(100, reset).hasReset(at: reset), "reset at resetsAt")
            expect(!w(100, nil).hasReset(at: reset), "unknown reset time never counts as reset")
            let snap = CodexRateLimitSnapshot(limitID: "codex", limitName: nil,
                windows: [CodexRateWindow(usedPercent: 95, windowMinutes: 300, resetsAt: reset), w(40, later)],
                credits: nil, planType: nil, reachedType: nil, observedAt: reset)
            expect(snap.tightestWindow(now: reset)?.usedPercent == 40, "tightest skips windows past reset")
            expect(snap.displayName == "Codex", "main display name")

            var a = CodexUsageReading(status: .ok, main: snap, additional: [], scannedFiles: 1, scannedBytes: 100)
            let b = CodexUsageReading(status: .ok, main: snap, additional: [], scannedFiles: 3, scannedBytes: 0)
            expect(a.hasSameContent(as: b) && a != b, "scan counters do not count as content")
            a.isComplete = false
            expect(!a.hasSameContent(as: b), "completeness counts as content")
        }

        // MARK: Monitor

        do { // publishes on activation, stops with the section, reads on demand while hidden
            let home = makeHome("monitor", [("sessions/2026/09/18/rollout-w.jsonl", "codex-weekly-only.jsonl", date("2026-09-18T07:24:58.000Z"))])
            let monitor = CodexUsageMonitor(codexHome: home, refreshInterval: 0.2, now: { now })
            var publishes = 0
            let cancellable = monitor.$reading.dropFirst().sink { _ in publishes += 1 }
            defer { cancellable.cancel() }
            aiTestSettle(0.1)
            expect(monitor.reading == nil && monitor.readCount == 0, "monitor: nothing read before activation")
            monitor.setActive(true)
            expect(monitor.isTimerRunning, "monitor: timer runs while active")
            expect(aiTestWaitUntil { monitor.reading != nil }, "monitor: activation publishes a reading")
            expect(monitor.reading?.main?.windows.first?.usedPercent == 85, "monitor: main 85%")
            expect(aiTestWaitUntil { monitor.readCount >= 3 }, "monitor: timer keeps reading while active")
            expect(publishes == 1, "monitor: unchanged readings are not republished (\(publishes))")
            monitor.setActive(false)
            expect(!monitor.isTimerRunning, "monitor: timer stops with the section")
            aiTestSettle(0.1)
            let stopped = monitor.readCount
            aiTestSettle(0.5)
            expect(monitor.readCount == stopped, "monitor: no reads while inactive")
            monitor.refreshNow()
            expect(aiTestWaitUntil { monitor.readCount == stopped + 1 }, "monitor: refreshNow reads while inactive")
            expect(monitor.codexHomeDisplayPath.hasSuffix("/monitor"), "monitor: display path")
        }
        do { // catch-up reads while history is incomplete; none after deactivation
            let home = makeHome("catchup", [("sessions/2026/09/17/rollout-s.jsonl", "codex-spark-after-main.jsonl", date("2026-09-17T14:28:00.000Z"))])
            var limits = CodexRateLimitReader.Limits()
            limits.backwardBytesPerFile = 900
            let monitor = CodexUsageMonitor(codexHome: home, limits: limits, catchUpDelay: 0.01, now: { now })
            monitor.setActive(true)
            expect(aiTestWaitUntil { monitor.reading?.isComplete == true }, "catch-up: history completes without waiting for the timer")
            expect(monitor.reading?.main?.windows.first?.usedPercent == 60, "catch-up: main found")
            let settled = monitor.readCount
            expect(settled > 1, "catch-up: several reads (\(settled))")
            aiTestSettle(0.3)
            expect(monitor.readCount == settled, "catch-up: stops once complete")
            monitor.setActive(false)

            let slow = CodexUsageMonitor(codexHome: home, limits: limits, catchUpDelay: 0.2, now: { now })
            slow.setActive(true)
            expect(aiTestWaitUntil { slow.readCount >= 1 }, "catch-up: first read")
            slow.setActive(false)
            let atStop = slow.readCount
            aiTestSettle(0.6)
            expect(slow.readCount <= atStop + 1, "catch-up: deactivation drops pending catch-ups (\(atStop) → \(slow.readCount))")
            expect(slow.reading?.isComplete == false, "catch-up: history stays incomplete while hidden")
        }

        if failures.isEmpty {
            print("All Codex usage tests passed.")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
