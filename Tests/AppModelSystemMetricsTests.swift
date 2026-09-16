import AppKit
import Foundation

/// Covers when AppModel runs system metrics collection: only while the expanded
/// System section or the compact System view is on screen, with process sampling
/// limited to the expanded section, plus the taller System layout size.
@main
struct AppModelSystemMetricsTests {
    @MainActor
    static func main() {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        /// Pumps the main run loop until the condition holds or the timeout
        /// elapses, so timers and main-actor tasks can fire.
        func waitUntil(
            timeout: TimeInterval = 2.0,
            _ condition: () -> Bool
        ) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() >= deadline { return false }
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return true
        }

        let defaultsSuiteName = "com.virtualnotch.tests.appmodel-system-metrics"
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("renotch-appmodel-system-\(UUID().uuidString)", isDirectory: true)
        let historyURL = tempDirectory.appendingPathComponent("system-history.db")
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }

        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.set(true, forKey: "virtualNotch.didCompleteOnboarding")

        let model = AppModel(defaults: defaults, systemHistoryURL: historyURL)

        // MARK: Idle by default

        expect(model.mode == .compact, "onboarded model starts compact")
        expect(!model.isCollectingSystemMetrics, "no collection while System is not shown")
        expect(!model.isSamplingSystemProcesses, "no process sampling while System is not shown")
        expect(
            !FileManager.default.fileExists(atPath: historyURL.path),
            "history database is not opened before System is shown"
        )

        // MARK: Expanded System section

        model.expand(section: .system, pin: true, preferSelectedSection: true)
        expect(model.mode == .expanded && model.selectedSection == .system, "expands to System section")
        expect(model.isCollectingSystemMetrics, "System section starts collection")
        expect(model.isSamplingSystemProcesses, "System section starts process sampling")
        expect(FileManager.default.fileExists(atPath: historyURL.path), "history database opens at the injected URL")

        let defaultExpandedHeight = NotchSettings.default.expandedHeight
        expect(
            model.currentSize.height == max(defaultExpandedHeight, NotchSettings.systemExpandedHeight),
            "System section uses its taller layout (got \(model.currentSize.height))"
        )
        expect(model.currentSize.width >= NotchSettings.systemExpandedWidth, "System section is at least its minimum width")
        expect(model.expandedContentHeight == model.currentSize.height, "expanded content fills the System layout")

        let collected = waitUntil(timeout: 6.0) { !model.systemMetrics.cpuSamples.isEmpty }
        expect(collected, "AppModel-driven collection publishes CPU samples")
        let sampled = waitUntil(timeout: 6.0) { !model.systemMetrics.topCPUProcesses.isEmpty }
        expect(sampled, "AppModel-driven sampling publishes top CPU processes")

        // MARK: Other sections stop everything

        model.expand(section: .music, pin: true, preferSelectedSection: true)
        expect(!model.isCollectingSystemMetrics, "switching away from System stops collection")
        expect(!model.isSamplingSystemProcesses, "switching away from System stops process sampling")
        expect(model.currentSize.height == defaultExpandedHeight, "other sections keep the configured height")
        expect(model.expandedContentHeight == defaultExpandedHeight, "other sections keep the configured content height")

        model.expand(section: .system, pin: true, preferSelectedSection: true)
        expect(model.isCollectingSystemMetrics && model.isSamplingSystemProcesses, "returning to System resumes both")

        model.collapse(force: true)
        expect(model.mode == .compact, "collapse returns to compact")
        expect(!model.isCollectingSystemMetrics, "compact music view does not collect")
        expect(!model.isSamplingSystemProcesses, "compact view never samples processes")

        // MARK: Compact System view

        // A coding glance (e.g. uncommitted changes in the repo the tests run from)
        // legitimately redirects the compact destination to Coding.
        func expectedCompactDestination() -> NotchSection {
            model.activity.glance == nil ? .system : .activity
        }

        model.settings.compactContent = .system
        expect(model.selectedSection == expectedCompactDestination(), "compact System content maps to its destination section")
        expect(model.isCollectingSystemMetrics, "compact System view collects metrics")
        expect(!model.isSamplingSystemProcesses, "compact System view does not sample processes")

        model.hoverChanged(true)
        expect(model.mode == .expanded, "hover expands the compact System view")
        expect(
            model.isSamplingSystemProcesses == (model.selectedSection == .system),
            "hover-expanded notch samples processes only when it lands on System"
        )
        model.expand(section: .system, preferSelectedSection: true)
        expect(model.isSamplingSystemProcesses, "expanded System section samples processes")

        model.collapse(force: true)
        expect(model.isCollectingSystemMetrics, "collapsing to compact System keeps collecting")
        expect(!model.isSamplingSystemProcesses, "collapsing stops process sampling")

        // MARK: Hidden notch and sleep

        model.setVisible(false)
        expect(!model.isCollectingSystemMetrics, "hiding the notch stops collection")
        model.setVisible(true)
        expect(model.isCollectingSystemMetrics, "showing the notch resumes collection")

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        expect(waitUntil { !model.isCollectingSystemMetrics }, "sleep pauses collection")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        expect(waitUntil { model.isCollectingSystemMetrics }, "wake resumes collection")

        model.settings.compactContent = .music
        expect(!model.isCollectingSystemMetrics, "changing compact content away from System stops collection")

        if failures.isEmpty {
            print("All AppModel system metrics tests passed.")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
