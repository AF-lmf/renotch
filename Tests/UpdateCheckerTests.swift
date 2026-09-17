import AppKit
import Foundation

/// Covers the update check offline: version parsing, GitHub response handling,
/// the silent launch path (no alerts or activation, one notification per new
/// version), and that an update alert neither stalls queued main-actor work nor
/// nests inside another open modal.
@main
struct UpdateCheckerTests {
    @MainActor
    static func main() {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        /// Pumps the main run loop until the condition holds or the timeout
        /// elapses, so main-actor tasks and timers can fire. Only call it from
        /// this synchronous main, never from inside a task.
        func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() >= deadline { return false }
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return true
        }

        func version(_ text: String) -> AppVersion {
            guard let parsed = AppVersion(text) else {
                failures.append("parses version \"\(text)\"")
                return AppVersion("0")!
            }
            return parsed
        }

        // MARK: Version parsing

        expect(version("v1.8.0") == version("1.8.0"), "v prefix is ignored")
        expect(version("1.7") == version("1.7.0"), "missing components count as zero")
        expect(version("1.10.0") > version("1.9.2"), "components compare numerically")
        expect(version("1.8.0-beta.1").numbers == [1, 8, 0], "pre-release suffix is not a component")
        expect(version("1.8.0-beta.1") < version("1.8.0"), "pre-release sorts before its release")
        expect(!(version("1.8.0-beta.1") > version("1.8.0")), "1.8.0-beta.1 is not newer than 1.8.0")
        expect(version("1.8.0-beta.1") > version("1.7.0"), "pre-release sorts after the previous release")
        expect(version("1.8.0-beta.10") > version("1.8.0-beta.9"), "pre-release numbers compare numerically")
        expect(version("1.8.0-rc.1") > version("1.8.0-beta.5"), "alphanumeric pre-release identifiers")
        expect(version("1.8.0-beta") < version("1.8.0-beta.1"), "shorter pre-release sorts first")
        expect(version("1.8.0+42") == version("1.8.0"), "build metadata is ignored")
        expect(version(" V1.8\n").description == "1.8", "whitespace and capital V are dropped")
        expect(version("v1.8.0-rc.1+sha.5114f85").description == "1.8.0-rc.1", "description drops v and build metadata")
        for invalid in ["", "v", "latest", "nightly", "1..0", "1.8.", "1.x", "1.8.0-", "-1.0", "1.8.0 beta", "1.8.0-beta..1", "1.8.0beta", "99999999999999999999"] {
            expect(AppVersion(invalid) == nil, "rejects version \"\(invalid)\"")
        }

        // MARK: GitHub response parsing

        let apiURL = UpdateChecker.latestReleaseAPI

        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: apiURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        }

        func releaseJSON(_ tag: String, prerelease: Bool = false, page: String? = nil) -> Data {
            var json: [String: Any] = ["tag_name": tag, "prerelease": prerelease]
            json["html_url"] = page ?? "https://github.com/yosaiy/renotch/releases/tag/\(tag)"
            return try! JSONSerialization.data(withJSONObject: json)
        }

        expect(
            LatestRelease.parse(data: releaseJSON("v1.8.0"), response: response(200)) == .success(LatestRelease(
                version: version("1.8.0"),
                page: URL(string: "https://github.com/yosaiy/renotch/releases/tag/v1.8.0")!,
                isPrerelease: false
            )),
            "parses tag and release page"
        )
        expect(
            LatestRelease.parse(data: releaseJSON("1.8.0", page: "http://example.com/x"), response: response(200))
                == .success(LatestRelease(version: version("1.8.0"), page: UpdateChecker.releasesPage, isPrerelease: false)),
            "non-GitHub release page falls back to the releases page"
        )
        if case .success(let flagged) = LatestRelease.parse(data: releaseJSON("1.8.0", prerelease: true), response: response(200)) {
            expect(flagged.isPrerelease, "GitHub prerelease flag is honored")
        } else {
            failures.append("flagged pre-release parses")
        }
        expect(LatestRelease.parse(data: Data(), response: response(403)) == .failure(.rateLimited), "403 rate limit")
        expect(LatestRelease.parse(data: Data(), response: response(429)) == .failure(.rateLimited), "429 rate limit")
        expect(LatestRelease.parse(data: Data(), response: response(404)) == .failure(.badStatus(404)), "404 without releases")
        expect(LatestRelease.parse(data: releaseJSON("1.8.0"), response: response(500)) == .failure(.badStatus(500)), "500 ignores the body")
        expect(LatestRelease.parse(data: Data("<html>".utf8), response: response(200)) == .failure(.unreadableResponse), "malformed JSON")
        expect(LatestRelease.parse(data: Data("[]".utf8), response: response(200)) == .failure(.unreadableResponse), "JSON array")
        expect(LatestRelease.parse(data: Data("{\"message\":\"Not Found\"}".utf8), response: response(200)) == .failure(.unreadableResponse), "missing tag_name")
        expect(LatestRelease.parse(data: Data("{\"tag_name\":18}".utf8), response: response(200)) == .failure(.unreadableResponse), "non-string tag_name")
        expect(LatestRelease.parse(data: releaseJSON("nightly"), response: response(200)) == .failure(.unreadableResponse), "unreadable tag")
        expect(
            LatestRelease.parse(data: releaseJSON("1.8.0"), response: URLResponse(url: apiURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
                == .failure(.unreadableResponse),
            "non-HTTP response"
        )

        // MARK: Outcome for a tag vs the installed version (S7)

        func outcome(tag: String, prerelease: Bool = false, installed: String) -> UpdateCheckOutcome {
            UpdateCheckOutcome.evaluate(
                installed: version(installed),
                release: LatestRelease.parse(data: releaseJSON(tag, prerelease: prerelease), response: response(200))
            )
        }
        func isUpdate(_ outcome: UpdateCheckOutcome) -> Bool {
            if case .updateAvailable = outcome { return true }
            return false
        }
        expect(isUpdate(outcome(tag: "v1.8.0", installed: "1.7")), "v1.8.0 is newer than 1.7")
        expect(isUpdate(outcome(tag: "1.8", installed: "1.7")), "1.8 is newer than 1.7")
        expect(outcome(tag: "1.7.0", installed: "1.7") == .upToDate(installed: version("1.7"), latest: version("1.7.0")), "1.7.0 equals 1.7")
        expect(!isUpdate(outcome(tag: "1.8.0-beta.1", installed: "1.7")), "stable build ignores pre-release tag")
        expect(!isUpdate(outcome(tag: "1.8.0-beta.1", installed: "1.8.0")), "pre-release is older than its release")
        expect(isUpdate(outcome(tag: "1.8.0-beta.2", installed: "1.8.0-beta.1")), "pre-release build is offered newer pre-release")
        expect(!isUpdate(outcome(tag: "v1.8.0", prerelease: true, installed: "1.7.0")), "stable build ignores plain tag flagged prerelease")
        expect(isUpdate(outcome(tag: "v1.8.0", prerelease: true, installed: "1.8.0-beta.1")), "pre-release build is offered plain tag flagged prerelease")
        expect(!isUpdate(outcome(tag: "1.6.0", installed: "1.7.0")), "older release is not an update")

        // MARK: Checker with stubbed side effects

        let suiteName = "com.virtualnotch.tests.update-checker"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = UserDefaults(suiteName: suiteName)!

        /// Prints every failure and exits non-zero. exit skips the defer above.
        func exitWithFailures() -> Never {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            fflush(stderr)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            exit(1)
        }

        // Creating NSApp registers its modal-panel mode as a common run loop mode,
        // so the common-mode timers below also fire inside a modal alert.
        NSApplication.shared.setActivationPolicy(.prohibited)

        /// Runs one scenario under a modal watchdog. No scenario may run a real
        /// modal, so one that opens (say, an alert run on the launch path) is
        /// aborted within a tenth of a second and recorded as a FAIL naming the
        /// scenario instead of hanging the suite. A modal that survives abortModal
        /// for two seconds, or a scenario that keeps opening new ones, ends the run.
        func scenario(_ name: String, _ body: () -> Void) {
            var abortedModal: NSWindow?
            var ticksSinceAbort = 0
            var abortedCount = 0
            let watchdog = Timer(timeInterval: 0.1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let modal = NSApp.modalWindow else { return }
                    if modal !== abortedModal {
                        failures.append("\(name) opened a modal alert")
                        abortedCount += 1
                        if abortedCount >= 5 {
                            failures.append("\(name) kept opening modal alerts")
                            NSApp.abortModal()
                            exitWithFailures()
                        }
                        abortedModal = modal
                        ticksSinceAbort = 0
                    } else {
                        ticksSinceAbort += 1
                        if ticksSinceAbort >= 20 {
                            failures.append("\(name) modal alert did not close on abortModal")
                            exitWithFailures()
                        }
                    }
                    NSApp.abortModal()
                }
            }
            RunLoop.main.add(watchdog, forMode: .common)
            body()
            watchdog.invalidate()
        }

        final class Recorder {
            var fetches = 0
            var activations = 0
            /// `activations` is the activation count when that alert was presented.
            var alerts: [(title: String, body: String, activations: Int)] = []
            /// Button titles of each presented alert, in order.
            var alertButtons: [[String]] = []
            var notified: [String] = []
            var opened: [URL] = []
            var notificationsAllowed = true
            var alertResponse: NSApplication.ModalResponse = .alertSecondButtonReturn
            var fetchResult: () throws -> (Data, URLResponse) = { throw URLError(.notConnectedToInternet) }
            var fetchGateOpen = true
            var onAlert: (() -> Void)?
        }

        func makeChecker(installed: String??, checksOnLaunch: Bool = UpdateChecker.checksOnLaunch, _ recorder: Recorder) -> UpdateChecker {
            let fetch: @MainActor () async throws -> (Data, URLResponse) = {
                recorder.fetches += 1
                while !recorder.fetchGateOpen { try await Task.sleep(nanoseconds: 5_000_000) }
                return try recorder.fetchResult()
            }
            let notify: @MainActor (AvailableUpdate) async -> Bool = { update in
                guard recorder.notificationsAllowed else { return false }
                recorder.notified.append(update.version.description)
                return true
            }
            let present: @MainActor (NSAlert) -> NSApplication.ModalResponse = { alert in
                recorder.alerts.append((alert.messageText, alert.informativeText, recorder.activations))
                recorder.alertButtons.append(alert.buttons.map(\.title))
                recorder.onAlert?()
                return recorder.alertResponse
            }
            let activate: @MainActor () -> Void = { recorder.activations += 1 }
            guard let installed else {
                // Production default: reads CFBundleShortVersionString from this binary.
                return UpdateChecker(checksOnLaunch: checksOnLaunch, defaults: defaults, fetchLatestRelease: fetch, postNotification: notify, presentAlert: present, activateApp: activate, openURL: { recorder.opened.append($0) })
            }
            return UpdateChecker(installedVersion: installed, checksOnLaunch: checksOnLaunch, defaults: defaults, fetchLatestRelease: fetch, postNotification: notify, presentAlert: present, activateApp: activate, openURL: { recorder.opened.append($0) })
        }

        func release(_ tag: String) -> () throws -> (Data, URLResponse) {
            { (releaseJSON(tag), response(200)) }
        }

        func runCheck(_ checker: UpdateChecker, interactive: Bool) {
            checker.check(interactive: interactive)
            expect(waitUntil { !checker.isChecking }, "check finishes")
        }

        /// Each alert was presented right after exactly one activation of its own.
        func activatedOncePerAlert(_ recorder: Recorder) -> Bool {
            recorder.activations == recorder.alerts.count
                && recorder.alerts.map(\.activations) == recorder.alerts.indices.map { $0 + 1 }
        }

        // S1: no version → no fetch, no alert, no notification on launch.
        expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") == nil, "test binary is unversioned like swift run")
        scenario("S1 unversioned build") {
            let unversionedCases: [(label: String, installed: String??)] = [
                ("production default", .none),
                ("nil", .some(nil)),
                ("empty", .some("")),
                ("dev", .some("dev"))
            ]
            for (label, installed) in unversionedCases {
                let recorder = Recorder()
                recorder.fetchResult = release("1.8.0")
                let checker = makeChecker(installed: installed, recorder)
                runCheck(checker, interactive: false)
                expect(recorder.fetches == 0 && recorder.alerts.isEmpty && recorder.notified.isEmpty, "S1 launch check is silent for \(label)")
                expect(recorder.activations == 0, "S1 launch check never activates the app for \(label)")
                expect(checker.availableUpdate == nil, "S1 has no available update for \(label)")
                expect(defaults.string(forKey: UpdateChecker.lastSurfacedVersionKey) == nil, "S1 persists nothing for \(label)")
            }
            let recorder = Recorder()
            let checker = makeChecker(installed: .none, recorder)
            runCheck(checker, interactive: true)
            expect(recorder.fetches == 0, "S1 menu check does not fetch")
            expect(recorder.alerts.map(\.title) == ["无法检查更新"], "S1 menu check explains missing version")
            expect(recorder.alertButtons == [["好"]], "S1 alert has an explicit Chinese OK button")
            expect(activatedOncePerAlert(recorder), "S1 menu check activates the app once for its alert")
        }

        scenario("S2 up to date") {
            let recorder = Recorder()
            recorder.fetchResult = release("v1.7.0")
            let checker = makeChecker(installed: "1.7.0", recorder)
            runCheck(checker, interactive: false)
            expect(recorder.alerts.isEmpty && recorder.notified.isEmpty, "S2 launch check is silent")
            expect(recorder.activations == 0, "S2 launch check never activates the app")
            runCheck(checker, interactive: true)
            expect(recorder.alerts.map(\.title) == ["已是最新版本"], "S2 menu check reports up to date")
            expect(recorder.alerts.first?.body == "Re:notch 1.7.0 已是最新版本。", "S2 message")
            expect(recorder.alertButtons == [["好"]], "S2 alert has an explicit Chinese OK button")
            expect(activatedOncePerAlert(recorder), "S2 menu check activates the app once for its alert")
            expect(defaults.string(forKey: UpdateChecker.lastSurfacedVersionKey) == nil, "S2 persists nothing")
        }

        // S3: first launch that sees 1.8.0 → one notification, persisted, menu item.
        scenario("S3 first launch with an update") {
            let recorder = Recorder()
            recorder.fetchResult = release("v1.8.0")
            let checker = makeChecker(installed: "1.7.0", recorder)
            runCheck(checker, interactive: false)
            expect(recorder.alerts.isEmpty, "S3 launch check never alerts")
            expect(recorder.activations == 0, "S3 launch check never activates the app")
            expect(recorder.notified == ["1.8.0"], "S3 posts one notification")
            expect(defaults.string(forKey: UpdateChecker.lastSurfacedVersionKey) == "1.8.0", "S3 persists surfaced version")
            expect(checker.availableUpdate?.version.description == "1.8.0", "S3 menu item shows 1.8.0")
            checker.openAvailableUpdate()
            expect(recorder.opened.map(\.absoluteString) == ["https://github.com/yosaiy/renotch/releases/tag/v1.8.0"], "S3 menu item opens release page")
        }

        // S4: next launch, same release → no notification, menu item still shown.
        scenario("S4 same release again") {
            let recorder = Recorder()
            recorder.fetchResult = release("1.8.0")
            let checker = makeChecker(installed: "1.7.0", recorder)
            runCheck(checker, interactive: false)
            expect(recorder.notified.isEmpty && recorder.alerts.isEmpty, "S4 does not re-surface 1.8.0")
            expect(recorder.activations == 0, "S4 launch check never activates the app")
            expect(checker.availableUpdate != nil, "S4 keeps the passive menu item")
            runCheck(checker, interactive: true)
            expect(recorder.alerts.map(\.title) == ["有可用的更新"], "S4 menu check still alerts")
            expect(recorder.alertButtons == [["下载", "以后"]], "S4 alert offers Download first and Not Now second")
            expect(activatedOncePerAlert(recorder), "S4 menu check activates the app once for its alert")
            expect(recorder.notified.isEmpty, "S4 menu check does not notify")
        }

        // S5: a newer release than the one surfaced → notify again; never lowered.
        scenario("S5 newer release") {
            let recorder = Recorder()
            recorder.fetchResult = release("1.9.0")
            let checker = makeChecker(installed: "1.7.0", recorder)
            runCheck(checker, interactive: false)
            expect(recorder.notified == ["1.9.0"], "S5 notifies about 1.9.0")
            expect(recorder.activations == 0, "S5 launch check never activates the app")
            expect(defaults.string(forKey: UpdateChecker.lastSurfacedVersionKey) == "1.9.0", "S5 persists 1.9.0")
            recorder.fetchResult = release("1.8.0")
            recorder.alertResponse = .alertFirstButtonReturn
            runCheck(checker, interactive: true)
            expect(defaults.string(forKey: UpdateChecker.lastSurfacedVersionKey) == "1.9.0", "S5 stored version is never lowered")
            expect(recorder.opened.count == 1, "Download opens the release page")
            expect(activatedOncePerAlert(recorder), "S5 menu check activates the app once for its alert")
        }
        scenario("Unreadable stored version") {
            defaults.set("garbage", forKey: UpdateChecker.lastSurfacedVersionKey)
            let recorder = Recorder()
            recorder.fetchResult = release("1.9.0")
            runCheck(makeChecker(installed: "1.7.0", recorder), interactive: false)
            expect(recorder.notified == ["1.9.0"], "unreadable stored version counts as nothing surfaced")
            expect(recorder.activations == 0, "launch check after unreadable stored version never activates the app")
            expect(defaults.string(forKey: UpdateChecker.lastSurfacedVersionKey) == "1.9.0", "unreadable stored version is replaced")
        }

        // S6: failures are silent on launch and explained from the menu.
        scenario("S6 failures") {
            defaults.set("1.9.0", forKey: UpdateChecker.lastSurfacedVersionKey)
            let failureCases: [(String, () throws -> (Data, URLResponse), String)] = [
                ("offline", { throw URLError(.notConnectedToInternet) }, "无法连接到 GitHub。请检查网络连接后重试。"),
                ("rate limit", { (Data("{\"message\":\"API rate limit exceeded\"}".utf8), response(403)) }, "GitHub 暂时限制了更新检查。请稍后再试。"),
                ("server error", { (Data(), response(502)) }, "GitHub 返回了意外的响应（HTTP 502）。请稍后再试。"),
                ("malformed", { (Data("not json".utf8), response(200)) }, "无法读取 GitHub 上的版本发布信息。请稍后再试。"),
                ("no tag", { (Data("{}".utf8), response(200)) }, "无法读取 GitHub 上的版本发布信息。请稍后再试。")
            ]
            for (name, result, body) in failureCases {
                let recorder = Recorder()
                recorder.fetchResult = result
                let checker = makeChecker(installed: "1.7.0", recorder)
                runCheck(checker, interactive: false)
                expect(recorder.alerts.isEmpty && recorder.notified.isEmpty, "S6 \(name) launch check is silent")
                expect(recorder.activations == 0, "S6 \(name) launch check never activates the app")
                expect(checker.availableUpdate == nil, "S6 \(name) adds no menu item")
                runCheck(checker, interactive: true)
                expect(recorder.alerts.map(\.title) == ["检查更新失败"], "S6 \(name) menu check alerts")
                expect(recorder.alerts.first?.body == body, "S6 \(name) message")
                expect(recorder.alertButtons == [["好"]], "S6 \(name) alert has an explicit Chinese OK button")
                expect(activatedOncePerAlert(recorder), "S6 \(name) menu check activates the app once for its alert")
                expect(defaults.string(forKey: UpdateChecker.lastSurfacedVersionKey) == "1.9.0", "S6 \(name) leaves persistence alone")
            }
        }

        // S8: notifications unavailable → nothing persisted, menu item only.
        scenario("S8 notifications unavailable") {
            defaults.removeObject(forKey: UpdateChecker.lastSurfacedVersionKey)
            let recorder = Recorder()
            recorder.notificationsAllowed = false
            recorder.fetchResult = release("1.8.0")
            let checker = makeChecker(installed: "1.7.0", recorder)
            runCheck(checker, interactive: false)
            expect(recorder.alerts.isEmpty, "S8 never falls back to an alert")
            expect(recorder.activations == 0, "S8 launch check never activates the app")
            expect(defaults.string(forKey: UpdateChecker.lastSurfacedVersionKey) == nil, "S8 does not persist an unseen version")
            expect(checker.availableUpdate?.version.description == "1.8.0", "S8 menu item still shows the update")
            checker.openAvailableUpdate()
            expect(recorder.opened.count == 1, "S8 menu item opens the release page")
            expect(defaults.string(forKey: UpdateChecker.lastSurfacedVersionKey) == "1.8.0", "S8 opening the menu item marks 1.8.0 surfaced")
        }
        scenario("S8 notification service") {
            // This test binary has no bundle identifier, like `swift run`.
            var posted: Bool?
            Task { @MainActor in
                posted = await NotificationService.shared.postUpdateAvailable(
                    version: "1.8.0",
                    installed: "1.7.0",
                    releasePage: UpdateChecker.releasesPage
                )
            }
            expect(waitUntil { posted != nil } && posted == false, "S8 notification service declines without a bundle id")
        }

        // Later checks on the same checker: a failure keeps the menu item, an
        // up-to-date result removes it.
        scenario("Later checks") {
            defaults.removeObject(forKey: UpdateChecker.lastSurfacedVersionKey)
            let recorder = Recorder()
            recorder.fetchResult = release("1.8.0")
            let checker = makeChecker(installed: "1.7.0", recorder)
            runCheck(checker, interactive: false)
            expect(checker.availableUpdate?.version.description == "1.8.0", "later checks start with 1.8.0 available")
            recorder.fetchResult = { throw URLError(.timedOut) }
            runCheck(checker, interactive: false)
            expect(checker.availableUpdate?.version.description == "1.8.0", "failed launch check keeps the available update")
            recorder.fetchResult = { (Data(), response(502)) }
            runCheck(checker, interactive: true)
            expect(recorder.alerts.map(\.title) == ["检查更新失败"], "failed menu check reports the failure")
            expect(checker.availableUpdate?.version.description == "1.8.0", "failed menu check keeps the available update")
            recorder.fetchResult = release("1.7.0")
            runCheck(checker, interactive: false)
            expect(checker.availableUpdate == nil, "up-to-date check clears the available update")
            expect(activatedOncePerAlert(recorder), "later checks activate the app only for the menu alert")
        }

        // Overlap: a menu click during the launch fetch joins it and shows one alert;
        // clicks while that alert is open are ignored.
        scenario("Overlap") {
            defaults.removeObject(forKey: UpdateChecker.lastSurfacedVersionKey)
            let recorder = Recorder()
            recorder.fetchResult = release("1.8.0")
            recorder.fetchGateOpen = false
            let checker = makeChecker(installed: "1.7.0", recorder)
            recorder.onAlert = {
                checker.check(interactive: true)
                checker.check(interactive: true)
            }
            checker.check(interactive: false)
            expect(waitUntil { recorder.fetches == 1 }, "launch fetch started")
            checker.check(interactive: true)
            checker.check(interactive: true)
            recorder.fetchGateOpen = true
            expect(waitUntil { !checker.isChecking }, "overlapping checks finish")
            _ = waitUntil(timeout: 0.2) { false }
            expect(recorder.alerts.map(\.title) == ["有可用的更新"], "overlap shows exactly one alert")
            expect(activatedOncePerAlert(recorder), "overlap activates the app once for its one alert")
            expect(recorder.fetches == 1, "overlapping checks share one fetch")
            expect(recorder.notified.isEmpty, "alerted version is not also notified")
            expect(defaults.string(forKey: UpdateChecker.lastSurfacedVersionKey) == "1.8.0", "alerted version is persisted")
        }

        // This fork never checks on launch; the menu check still works.
        scenario("Launch checks off") {
            expect(!UpdateChecker.checksOnLaunch, "fork build does not check for updates on launch")
            defaults.removeObject(forKey: UpdateChecker.lastSurfacedVersionKey)
            let recorder = Recorder()
            recorder.fetchResult = release("1.8.0")
            let checker = makeChecker(installed: "1.7.0", recorder)
            checker.checkOnLaunch()
            _ = waitUntil(timeout: 0.3) { false }
            expect(!checker.isChecking && recorder.fetches == 0, "launch check with checks off does not fetch")
            expect(recorder.alerts.isEmpty && recorder.notified.isEmpty && recorder.activations == 0, "launch check with checks off stays silent")
            expect(checker.availableUpdate == nil, "launch check with checks off adds no menu item")
            runCheck(checker, interactive: true)
            expect(recorder.fetches == 1 && recorder.alerts.map(\.title) == ["有可用的更新"], "menu check still works with launch checks off")

            defaults.removeObject(forKey: UpdateChecker.lastSurfacedVersionKey)
            let enabledRecorder = Recorder()
            enabledRecorder.fetchResult = release("1.8.0")
            let enabled = makeChecker(installed: "1.7.0", checksOnLaunch: true, enabledRecorder)
            enabled.checkOnLaunch()
            expect(waitUntil { !enabled.isChecking && enabledRecorder.fetches == 1 }, "launch check with checks on fetches")
            expect(enabledRecorder.notified == ["1.8.0"] && enabledRecorder.alerts.isEmpty, "launch check with checks on takes the silent path")
        }

        // MARK: Open alert does not stall main-actor work (G4)

        /// Runs `start` from this synchronous main (never from inside a task, whose
        /// main-queue drain would hide the bug), then once a modal window is up
        /// queues a main-actor task and a main-queue block and reports whether
        /// both ran before the modal was aborted (after at most one second).
        func queuedWorkRunsDuringModal(start: () -> Void, isFinished: () -> Bool) -> Bool {
            var taskRan = false
            var queueRan = false
            var queued = false
            var ranDuringModal = false
            var sawModal = false
            let began = Date()
            let probe = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard NSApp.modalWindow != nil else {
                        // Never hang the suite if the modal window can't be seen.
                        if Date().timeIntervalSince(began) > 3.0 { NSApp.abortModal() }
                        return
                    }
                    sawModal = true
                    if !queued {
                        queued = true
                        Task { @MainActor in taskRan = true }
                        DispatchQueue.main.async { queueRan = true }
                    } else if (taskRan && queueRan) || Date().timeIntervalSince(began) > 1.0 {
                        ranDuringModal = taskRan && queueRan
                        timer.invalidate()
                        NSApp.abortModal()
                    }
                }
            }
            RunLoop.main.add(probe, forMode: .common)
            start()
            let finished = waitUntil(timeout: 5.0, isFinished)
            probe.invalidate()
            expect(finished && sawModal, "modal alert was presented and dismissed")
            return ranDuringModal
        }

        func hiddenAlert() -> NSAlert {
            let alert = NSAlert()
            alert.messageText = "有可用的更新"
            alert.window.alphaValue = 0
            return alert
        }

        do {
            var response: NSApplication.ModalResponse?
            let ran = queuedWorkRunsDuringModal(
                start: { Task { @MainActor in response = hiddenAlert().runModal() } },
                isFinished: { response != nil }
            )
            expect(response == .abort && !ran, "control: runModal inside a main-actor task blocks queued work")
        }

        do {
            var response: NSApplication.ModalResponse?
            let ran = queuedWorkRunsDuringModal(
                start: { Task { @MainActor in response = await UpdateChecker.runModalOutsideMainQueue { hiddenAlert().runModal() } } },
                isFinished: { response != nil }
            )
            expect(response == .abort, "update alert modal ends on abort")
            expect(ran, "queued main-actor work runs while the update alert is open")
        }

        // An update alert queued while another modal is open waits for that modal
        // to end instead of nesting inside it: runModalOutsideMainQueue queues its
        // block for the default run loop mode only, which a modal loop does not run.
        do {
            let outer = hiddenAlert()
            var events: [String] = []
            var queuedAt: Date?
            var innerResponse: NSApplication.ModalResponse?
            let began = Date()
            let script = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    if events.isEmpty, NSApp.modalWindow === outer.window {
                        events.append("outer-open")
                        Task { @MainActor in
                            events.append("inner-queued")
                            queuedAt = Date()
                            innerResponse = await UpdateChecker.runModalOutsideMainQueue {
                                events.append("inner-run")
                                return .OK
                            }
                        }
                    } else if queuedAt.map({ Date().timeIntervalSince($0) > 0.3 }) ?? (Date().timeIntervalSince(began) > 3.0) {
                        // Leaves a common-mode block time to run inside the modal.
                        events.append("outer-abort")
                        timer.invalidate()
                        NSApp.abortModal()
                    }
                }
            }
            RunLoop.main.add(script, forMode: .common)
            let outerResponse = outer.runModal()
            events.append("outer-end")
            script.invalidate()
            expect(outerResponse == .abort, "outer modal ends on abort")
            expect(waitUntil { innerResponse != nil }, "update alert queued during another modal runs after it")
            expect(
                events == ["outer-open", "inner-queued", "outer-abort", "outer-end", "inner-run"],
                "update alert does not start until the open modal ends (events: \(events))"
            )
        }

        // The menu check activates the app in the same deferred block that presents
        // its alert, so it never brings the app forward while another modal (or
        // menu tracking) is still in progress.
        do {
            defaults.removeObject(forKey: UpdateChecker.lastSurfacedVersionKey)
            let outer = hiddenAlert()
            var events: [String] = []
            var checkedAt: Date?
            let began = Date()
            let checker = UpdateChecker(
                installedVersion: "1.7.0",
                defaults: defaults,
                fetchLatestRelease: { (releaseJSON("1.8.0"), response(200)) },
                postNotification: { _ in true },
                presentAlert: { _ in
                    events.append("alert")
                    return .alertSecondButtonReturn
                },
                activateApp: { events.append("activate") },
                openURL: { _ in }
            )
            let script = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    if events.isEmpty, NSApp.modalWindow === outer.window {
                        events.append("outer-open")
                        checker.check(interactive: true)
                        checkedAt = Date()
                    } else if checkedAt.map({ Date().timeIntervalSince($0) > 0.3 }) ?? (Date().timeIntervalSince(began) > 3.0) {
                        // Leaves the check time to fetch and queue its alert inside the modal.
                        events.append("outer-abort")
                        timer.invalidate()
                        NSApp.abortModal()
                    }
                }
            }
            RunLoop.main.add(script, forMode: .common)
            _ = outer.runModal()
            events.append("outer-end")
            script.invalidate()
            expect(waitUntil { !checker.isChecking }, "menu check started during another modal finishes after it")
            expect(
                events == ["outer-open", "outer-abort", "outer-end", "activate", "alert"],
                "menu check activates the app only when its alert is presented (events: \(events))"
            )
        }

        do {
            defaults.removeObject(forKey: UpdateChecker.lastSurfacedVersionKey)
            var opened: [URL] = []
            var activations = 0
            let checker = UpdateChecker(
                installedVersion: "1.7.0",
                defaults: defaults,
                fetchLatestRelease: { (releaseJSON("1.8.0"), response(200)) },
                postNotification: { _ in true },
                presentAlert: { alert in
                    alert.window.alphaValue = 0
                    return alert.runModal()
                },
                activateApp: { activations += 1 },
                openURL: { opened.append($0) }
            )
            var started = false
            let ran = queuedWorkRunsDuringModal(
                start: { checker.check(interactive: true); started = true },
                isFinished: { started && !checker.isChecking }
            )
            expect(ran, "menu check alert does not stall main-actor work")
            expect(opened.isEmpty, "aborted alert does not open the release page")
            expect(activations == 1, "menu check alert activates the app once")
        }

        if failures.isEmpty {
            print("All Re:notch update checker tests passed.")
        } else {
            exitWithFailures()
        }
    }
}
