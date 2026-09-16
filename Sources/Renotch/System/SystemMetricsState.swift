import Foundation

/// Observable system metrics for the notch UI.
///
/// Ported from MacStatus `DashboardState`. Differences from the original:
/// - Sparkline arrays are written only by `SystemMetricsCollector` from its ring
///   buffer. MacStatus appended inside each `update*` method and then overwrote
///   the same arrays from the ring buffer in the same tick.
/// - Raw network rates are exposed so compact notch layouts can format them.
/// - MacStatus-only fields (app self-monitoring, refresh interval mirror) are omitted.
@MainActor
final class SystemMetricsState: ObservableObject {
    nonisolated static let sparklineCapacity = 60

    // CPU
    @Published var cpuUsage: Double = 0
    @Published var cpuText: String = "--"
    @Published var cpuSamples: [Double] = []

    // Memory
    @Published var memoryUsage: Double = 0
    /// nil until the first successful memory read.
    @Published var memoryPressure: MemoryPressureLevel?
    @Published var memoryText: String = "--"
    @Published var memorySamples: [Double] = []

    // Network
    @Published var networkDownloadBps: Double = 0
    @Published var networkUploadBps: Double = 0
    @Published var networkText: String = "--"
    @Published var networkProgress: Double = 0
    /// Download throughput in KB/s.
    @Published var networkSamples: [Double] = []

    // GPU
    @Published var gpuUsage: Double = 0
    @Published var gpuText: String = "--"
    @Published var gpuSamples: [Double] = []

    // Battery (nil = no battery = desktop → section hidden)
    @Published var battery: BatterySnapshot?
    @Published var hasBattery: Bool = false

    // Thermal (current snapshot only; unavailable values keep rows stable)
    @Published var thermal: ThermalSnapshot = .unavailable()

    // Fans (current snapshot only; fanless machines keep an empty snapshot)
    @Published var fan: FanSnapshot = .unavailable()

    // Network Top-N (nettop, refreshed on demand)
    @Published var topProcesses: [ProcessNetworkUsage] = []
    @Published var processesLoading: Bool = false
    @Published var processError: String?

    // CPU / memory Top-N (sampled only while the system panel is visible)
    @Published var topCPUProcesses: [ProcessResourceUsage] = []
    @Published var topMemoryProcesses: [ProcessResourceUsage] = []
    @Published var resourceLoading: Bool = true

    // MARK: - Update Methods

    func updateCPU(_ usage: Double?) {
        guard let usage else {
            cpuText = "--"
            cpuUsage = 0
            return
        }
        cpuUsage = usage
        cpuText = "\(Int(usage))%"
    }

    func updateMemory(_ stats: MemoryStats?) {
        guard let stats, let usedPercent = stats.usedPercent else {
            memoryText = "--"
            memoryUsage = 0
            memoryPressure = nil
            return
        }
        memoryUsage = usedPercent
        memoryPressure = stats.pressureLevel
        let pressureLabel: String
        switch stats.pressureLevel {
        case .normal: pressureLabel = "OK"
        case .warning: pressureLabel = "WARN"
        case .critical: pressureLabel = "CRIT"
        case .unknown: pressureLabel = "?"
        }
        memoryText = "\(Int(usedPercent))% (\(pressureLabel))"
    }

    func updateNetwork(_ stats: NetworkStats?) {
        guard let stats else {
            networkText = "--"
            networkProgress = 0
            networkDownloadBps = 0
            networkUploadBps = 0
            return
        }
        networkDownloadBps = stats.downloadBytesPerSec
        networkUploadBps = stats.uploadBytesPerSec
        let up = ByteFormatting.format(stats.uploadBytesPerSec)
        let down = ByteFormatting.format(stats.downloadBytesPerSec)
        networkText = "↓\(down)\n↑\(up)"

        let maxBytesPerSec: Double = 100 * 1_000_000 // 100 MB/s
        let total = stats.uploadBytesPerSec + stats.downloadBytesPerSec
        networkProgress = min(total / maxBytesPerSec, 1.0)
    }

    func updateGPU(_ stats: GPUStats?) {
        guard let stats else {
            gpuText = "N/A"
            gpuUsage = 0
            return
        }
        gpuUsage = stats.utilizationPercent
        gpuText = "\(Int(stats.utilizationPercent))%"
    }

    /// nil (desktop / no battery) hides the whole battery section.
    func updateBattery(_ snapshot: BatterySnapshot?) {
        battery = snapshot
        hasBattery = snapshot != nil
    }

    func updateThermal(_ snapshot: ThermalSnapshot) {
        thermal = snapshot
    }

    func updateFans(_ snapshot: FanSnapshot) {
        fan = snapshot
    }
}
