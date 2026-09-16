import Foundation

/// On-demand process sampling for the system panel: CPU/memory Top-N on a loop and
/// a one-shot network Top-N via `nettop`.
///
/// Ported from the sampling half of MacStatus `PopoverManager`. Process data is only
/// useful while the panel is visible, so the owner calls `start()` when the system
/// section appears and `stop()` when it goes away.
@MainActor
final class SystemProcessSampler {
    private let state: SystemMetricsState
    private let resourceReader = ProcessResourceReader()
    private let resourceInterval: TimeInterval
    private var resourceSampleTask: Task<Void, Never>?
    private var networkRefreshTask: Task<Void, Never>?

    init(state: SystemMetricsState, resourceInterval: TimeInterval = 1.5) {
        self.state = state
        self.resourceInterval = resourceInterval
    }

    deinit {
        resourceSampleTask?.cancel()
        networkRefreshTask?.cancel()
    }

    var isRunning: Bool { resourceSampleTask != nil }

    /// Start sampling. Calling it while running is a no-op.
    func start() {
        guard resourceSampleTask == nil else { return }
        refreshNetworkProcesses()
        startResourceSampling()
    }

    /// Stop sampling. Calling it while stopped is a no-op.
    func stop() {
        guard resourceSampleTask != nil || networkRefreshTask != nil else { return }
        resourceSampleTask?.cancel()
        resourceSampleTask = nil
        networkRefreshTask?.cancel()
        networkRefreshTask = nil
        state.resourceLoading = true
        state.processesLoading = false
        // The actor runs this after any in-flight sample() completes, so there is no
        // concurrent read-write on its previous snapshot.
        Task { [resourceReader] in
            await resourceReader.clearSnapshot()
        }
    }

    /// Re-run the network Top-N query. `nettop` takes about a second, so it runs
    /// off the main actor.
    func refreshNetworkProcesses() {
        networkRefreshTask?.cancel()
        state.processesLoading = true
        state.processError = nil

        networkRefreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                ProcessNetworkReader.readTopProcesses()
            }.value

            guard !Task.isCancelled, let self else { return }
            switch result {
            case .processes(let processes):
                self.state.topProcesses = processes
            case .idle:
                self.state.topProcesses = []
            case .unavailable(let reason):
                self.state.processError = reason
            }
            self.state.processesLoading = false
        }
    }

    private func startResourceSampling() {
        let intervalNanoseconds = UInt64(resourceInterval * 1_000_000_000)
        resourceSampleTask = Task { [weak self, resourceReader] in
            while !Task.isCancelled {
                // Actor hop: sample() runs on ProcessResourceReader's executor, off the main actor.
                let (cpuTop, memoryTop) = await resourceReader.sample()

                guard !Task.isCancelled, let self else { return }
                self.state.topCPUProcesses = cpuTop
                self.state.topMemoryProcesses = memoryTop
                self.state.resourceLoading = false

                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
    }
}
