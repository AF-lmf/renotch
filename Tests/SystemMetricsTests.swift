import AppKit
import Foundation

/// Covers the system metrics layer ported from MacStatus:
/// ring buffer wraparound, SQLite history round-trip, live collection on this Mac
/// (start / stop / resume / interval change), and on-demand process sampling.
/// Hardware-dependent readings (GPU, battery, thermal, fans) are printed, not asserted.
@main
struct SystemMetricsTests {
    @MainActor
    static func main() {
        // AppKit registers its modal-panel and event-tracking modes as common run loop
        // modes when the shared application is created, as it is in the real app.
        _ = NSApplication.shared
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

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("renotch-system-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        // MARK: Ring buffer

        do {
            let buffer = RingBuffer(capacity: 3)
            for value in 1...5 {
                buffer.append(MetricSample(cpuUsage: Double(value)))
            }
            expect(buffer.count == 3, "ring buffer caps at capacity")
            expect(
                buffer.recentSamples(3).compactMap(\.cpuUsage) == [3, 4, 5],
                "ring buffer keeps newest samples in chronological order"
            )
            expect(buffer.recentSamples(10).count == 3, "ring buffer never returns more than it holds")
        }

        // MARK: History store

        do {
            let store = HistoryStore(databaseURL: tempDirectory.appendingPathComponent("history.db"))
            let now = Date()
            store.insertSamples([
                MetricSample(timestamp: now.addingTimeInterval(-8 * 24 * 3600), cpuUsage: 10),
                MetricSample(timestamp: now.addingTimeInterval(-60), cpuUsage: 20, memoryUsage: 55),
                MetricSample(timestamp: now, cpuUsage: 30)
            ])
            expect(store.sampleCount == 3, "history store inserts samples")

            let recent = store.querySamples(from: now.addingTimeInterval(-300), to: now.addingTimeInterval(1))
            expect(recent.compactMap(\.cpuUsage) == [20, 30], "history store queries by time range")
            expect(recent.first?.memoryUsage == 55, "history store round-trips optional columns")

            store.purgeOlder(than: now.addingTimeInterval(-7 * 24 * 3600))
            expect(store.sampleCount == 2, "history store purges samples past retention")
        }

        // MARK: Live collection

        let state = SystemMetricsState()
        let collectorStore = HistoryStore(databaseURL: tempDirectory.appendingPathComponent("collector.db"))
        let collector = SystemMetricsCollector(
            state: state,
            refreshInterval: 0.5,
            historyStore: collectorStore
        )

        expect(!collector.isRunning, "collector is idle before start")
        collector.start()
        expect(collector.isRunning, "collector runs after start")

        let firstTicks = waitUntil(timeout: 4.0) { state.cpuSamples.count >= 3 }
        expect(firstTicks, "collector timer produces CPU samples")
        expect((0...100).contains(state.cpuUsage), "CPU usage is a percentage (got \(state.cpuUsage))")
        expect(state.cpuText != "--", "CPU text is populated")
        expect(state.memoryUsage > 0 && state.memoryUsage <= 100, "memory usage is a percentage (got \(state.memoryUsage))")
        expect(state.memoryPressure != nil, "memory pressure comes from the reader")
        expect(state.networkText != "--", "network text is populated")
        expect(state.memorySamples.count == state.cpuSamples.count, "sparklines advance together")

        collector.stop()
        expect(!collector.isRunning, "collector stops")
        let samplesAtStop = state.cpuSamples.count
        expect(
            collectorStore.sampleCount == collector.recentSamples(300).count,
            "stop flushes pending samples to history (\(collectorStore.sampleCount) persisted)"
        )

        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        expect(state.cpuSamples.count == samplesAtStop, "no samples are collected while stopped")

        collector.start()
        let resumed = waitUntil(timeout: 3.0) { state.cpuSamples.count > samplesAtStop }
        expect(resumed, "collector resumes after stop")
        expect((0...100).contains(state.cpuUsage), "first CPU reading after resume is re-baselined (got \(state.cpuUsage))")

        collector.start()
        expect(collector.isRunning, "start while running is a no-op")

        collector.setRefreshInterval(0.6)
        expect(collector.isRunning && collector.refreshInterval == 0.6, "interval change keeps collector running")
        let beforeIntervalChange = state.cpuSamples.count
        expect(
            waitUntil(timeout: 3.0) { state.cpuSamples.count > beforeIntervalChange },
            "collector keeps ticking after interval change"
        )
        // Simulates a modal alert opened from a main-actor job: NSAlert.runModal spins a
        // modal-panel run loop inside a main-actor task, so queued main-actor work cannot
        // run until the alert closes. Metrics on screen must keep updating anyway.
        final class ModalProbe {
            var finished = false
            var ticked = false
        }
        let probe = ModalProbe()
        let beforeModal = state.cpuSamples.count
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(3.0)
            while state.cpuSamples.count <= beforeModal && Date() < deadline {
                RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.01))
            }
            probe.ticked = state.cpuSamples.count > beforeModal
            probe.finished = true
        }
        expect(waitUntil(timeout: 5.0) { probe.finished }, "modal loop simulation finishes")
        expect(probe.ticked, "collector keeps ticking while a modal alert is open")

        collector.setRefreshInterval(0.1)
        expect(collector.refreshInterval == 0.5, "refresh interval is clamped to 0.5s")
        collector.stop()

        // MARK: Process sampling

        let sampler = SystemProcessSampler(state: state, resourceInterval: 0.5)
        sampler.start()
        expect(sampler.isRunning, "process sampler runs after start")

        let resourcesReady = waitUntil(timeout: 6.0) {
            !state.resourceLoading && !state.topCPUProcesses.isEmpty && !state.topMemoryProcesses.isEmpty
        }
        expect(resourcesReady, "process sampler publishes CPU and memory Top-N")
        expect(state.topMemoryProcesses.allSatisfy { $0.memoryBytes > 0 }, "memory Top-N has non-zero footprints")

        let networkReady = waitUntil(timeout: 6.0) { !state.processesLoading }
        expect(networkReady, "nettop query finishes")

        sampler.stop()
        expect(!sampler.isRunning, "process sampler stops")
        expect(state.resourceLoading, "stop resets the resource loading state")

        // MARK: Diagnostics (hardware-dependent, informational only)

        func format(_ value: Double?, _ unit: String) -> String {
            value.map { String(format: "%.1f%@", $0, unit) } ?? "unavailable"
        }
        print("""
        --- System metrics on this Mac ---
        CPU      \(state.cpuText)
        Memory   \(state.memoryText)
        Network  \(state.networkText.replacingOccurrences(of: "\n", with: " "))
        GPU      \(state.gpuText)
        Battery  \(state.battery.map { "\($0.chargePercent)%\($0.isCharging ? " charging" : "")" } ?? "none (desktop)")
        CPU temp \(format(state.thermal.cpuSocTemperatureCelsius, "°C"))
        Fans     \(state.fan.supportState) · \(state.fan.fans.compactMap(\.currentRPM).map { "\(Int($0)) rpm" }.joined(separator: ", "))
        Top CPU  \(state.topCPUProcesses.prefix(3).map(\.processName).joined(separator: ", "))
        Top net  \(state.processError ?? state.topProcesses.prefix(3).map(\.processName).joined(separator: ", "))
        ----------------------------------
        """)

        if failures.isEmpty {
            print("All system metrics tests passed.")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
