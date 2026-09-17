import SwiftUI

/// Expanded System section: CPU / GPU / memory / network tiles, a power and
/// thermal strip, and the top processes by CPU, memory or network.
struct SystemMetricsView: View {
    @ObservedObject var state: SystemMetricsState
    var onRefreshNetwork: () -> Void = {}
    @State private var processMode: ProcessMode = .cpu

    private static let processRowCount = 3

    enum ProcessMode: String, CaseIterable, Identifiable {
        case cpu
        case memory
        case network

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cpu: return "CPU"
            case .memory: return "内存"
            case .network: return "网络"
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SystemMetricTile(
                    label: "CPU",
                    value: state.cpuText,
                    samples: state.cpuSamples,
                    tint: percentTint(state.cpuUsage, available: state.cpuText != "--"),
                    range: 0...100
                )
                SystemMetricTile(
                    label: "GPU",
                    value: state.gpuText,
                    samples: state.gpuSamples,
                    tint: percentTint(state.gpuUsage, available: state.gpuText != SystemMetricsState.unavailableText && state.gpuText != "--"),
                    range: 0...100
                )
                SystemMetricTile(
                    label: "内存",
                    value: state.memoryText == "--" ? "--" : "\(Int(state.memoryUsage))%",
                    detail: memoryPressureLabel,
                    detailTint: SystemMetricTint.memoryPressure(state.memoryPressure),
                    samples: state.memorySamples,
                    tint: percentTint(state.memoryUsage, available: state.memoryText != "--"),
                    range: 0...100
                )
                SystemMetricTile(
                    label: "网络",
                    value: state.networkText == "--" ? "--" : "↓\(ByteFormatting.format(state.networkDownloadBps))",
                    detail: state.networkText == "--" ? nil : "↑\(ByteFormatting.format(state.networkUploadBps))",
                    samples: state.networkSamples,
                    tint: SystemMetricTint.blue
                )
            }
            .frame(height: 64)

            statusStrip
                .frame(height: 22)

            processSection
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Status Strip

    private var statusStrip: some View {
        HStack(spacing: 6) {
            if let battery = state.battery {
                SystemStatusChip(
                    icon: batterySymbol(battery),
                    text: batteryText(battery),
                    tint: battery.isCharging ? SystemMetricTint.charging : .white.opacity(0.85)
                )
            }
            if let watts = state.battery?.systemPowerWatts {
                SystemStatusChip(icon: "bolt.fill", text: String(format: "%.1fW", watts))
            }
            SystemStatusChip(
                icon: "thermometer.medium",
                text: thermalText,
                tint: SystemMetricTint.thermal(state.thermal.systemState)
            )
            if let fanText {
                SystemStatusChip(icon: "fan", text: fanText)
            }
            Spacer(minLength: 0)
        }
    }

    private var memoryPressureLabel: String? {
        switch state.memoryPressure {
        case .normal: return "正常"
        case .warning: return "警告"
        case .critical: return "严重"
        case .unknown, nil: return nil
        }
    }

    private func batterySymbol(_ battery: BatterySnapshot) -> String {
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.chargePercent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private func batteryText(_ battery: BatterySnapshot) -> String {
        guard let watts = battery.watts else { return "\(battery.chargePercent)%" }
        return String(format: "%d%% · %@%.1fW", battery.chargePercent, watts > 0 ? "+" : "−", abs(watts))
    }

    private var thermalText: String {
        let temperature = state.thermal.cpuSocTemperatureCelsius.map { "\(Int($0.rounded()))°C" } ?? "--"
        switch state.thermal.systemState {
        case .fair: return "\(temperature) · 偏高"
        case .serious: return "\(temperature) · 过高"
        case .critical: return "\(temperature) · 危急"
        case .nominal, .unknown: return temperature
        }
    }

    private var fanText: String? {
        switch state.fan.supportState {
        case .unsupported:
            return nil
        case .expectedButUnreadable:
            return "--"
        case .supported:
            let speeds = state.fan.fans.compactMap(\.currentRPM).map { "\(Int($0.rounded()))" }
            return speeds.isEmpty ? "--" : speeds.joined(separator: " · ") + " 转/分"
        }
    }

    private func percentTint(_ percent: Double, available: Bool) -> Color {
        available ? SystemMetricTint.usage(percent) : Color.notchMuted
    }

    // MARK: - Processes

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("进程排行")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Color.notchMuted)

                // nettop is a one-shot measurement, so the network list gets a manual refresh.
                if processMode == .network {
                    Button(action: onRefreshNetwork) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.notchMuted)
                            .frame(width: 20, height: 18)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.045)))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.processesLoading)
                    .help("重新测量网络用量")
                    .accessibilityLabel("刷新网络用量")
                }

                Spacer(minLength: 6)

                ForEach(ProcessMode.allCases) { mode in
                    processModeButton(mode)
                }
            }
            .frame(height: 18)

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<Self.processRowCount, id: \.self) { index in
                        if index < processRows.count {
                            SystemProcessRow(row: processRows[index])
                        } else {
                            Color.clear.frame(height: 17)
                        }
                    }
                }
                if let placeholder = processPlaceholder {
                    Text(placeholder)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.notchMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 17)
                }
            }
        }
    }

    private func processModeButton(_ mode: ProcessMode) -> some View {
        let isSelected = processMode == mode
        return Button {
            processMode = mode
        } label: {
            Text(mode.title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isSelected ? .white : Color.notchMuted)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.13) : Color.white.opacity(0.045))
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var processRows: [SystemProcessRow.Model] {
        switch processMode {
        case .cpu:
            let processes = state.topCPUProcesses.prefix(Self.processRowCount)
            let scale = max(100, processes.compactMap(\.cpuPercent).max() ?? 0)
            return processes.map { process in
                let percent = process.cpuPercent ?? 0
                return SystemProcessRow.Model(
                    id: "cpu-\(process.pid)",
                    name: process.processName,
                    value: process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                    ratio: percent / scale,
                    tint: SystemMetricTint.usage(percent)
                )
            }
        case .memory:
            let processes = state.topMemoryProcesses.prefix(Self.processRowCount)
            let scale = Double(max(processes.map(\.memoryBytes).max() ?? 1, 1))
            return processes.map { process in
                SystemProcessRow.Model(
                    id: "memory-\(process.pid)",
                    name: process.processName,
                    value: ByteFormatting.format(Double(process.memoryBytes)),
                    ratio: Double(process.memoryBytes) / scale,
                    tint: SystemMetricTint.blue
                )
            }
        case .network:
            let processes = state.topProcesses.prefix(Self.processRowCount)
            let scale = max(processes.map(\.totalBytesPerSec).max() ?? 1, 1)
            return processes.map { process in
                SystemProcessRow.Model(
                    id: "network-\(process.stableID)",
                    name: process.processName,
                    value: "↓\(ByteFormatting.format(process.downloadBytesPerSec)) ↑\(ByteFormatting.format(process.uploadBytesPerSec))",
                    ratio: process.totalBytesPerSec / scale,
                    tint: SystemMetricTint.blue
                )
            }
        }
    }

    private var processPlaceholder: String? {
        guard processRows.isEmpty else { return nil }
        switch processMode {
        case .cpu, .memory:
            return state.resourceLoading ? "正在采样进程…" : "暂无进程数据"
        case .network:
            if state.processesLoading { return "正在测量网络用量…" }
            return state.processError.map(Self.processErrorText) ?? "没有网络活动"
        }
    }

    /// `ProcessNetworkReader` reports English reasons (kept identical to MacStatus);
    /// map them here. Anything else is raw nettop stderr.
    nonisolated static func processErrorText(_ reason: String) -> String {
        switch reason {
        case "Unable to start nettop.": return "无法启动 nettop"
        case "nettop sampling timed out.": return "nettop 采样超时"
        case "No nettop samples were returned.": return "nettop 未返回采样数据"
        default: return "nettop 运行出错"
        }
    }
}

// MARK: - Tile

private struct SystemMetricTile: View {
    let label: String
    let value: String
    var detail: String?
    var detailTint: Color = Color.notchMuted
    let samples: [Double]
    let tint: Color
    var range: ClosedRange<Double>?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Color.notchMuted)
                if let detail {
                    Text(detail)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(detailTint)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint == Color.notchMuted ? tint : tintedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
            }
            SystemSparklineView(samples: samples, color: tint, range: range)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, detail].compactMap { $0 }.joined(separator: "，"))
    }

    private var tintedText: Color {
        tint == SystemMetricTint.blue ? SystemMetricTint.blueText : tint
    }
}

// MARK: - Status Chip

private struct SystemStatusChip: View {
    let icon: String
    let text: String
    var tint: Color = .white.opacity(0.85)

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Process Row

private struct SystemProcessRow: View {
    struct Model: Identifiable {
        let id: String
        let name: String
        let value: String
        let ratio: Double
        let tint: Color
    }

    let row: Model

    var body: some View {
        HStack(spacing: 8) {
            Text(row.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
            SystemRatioBar(ratio: row.ratio, tint: row.tint)
            Text(row.value)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .frame(width: 84, alignment: .trailing)
        }
        .frame(height: 17)
        .accessibilityElement(children: .combine)
    }
}
