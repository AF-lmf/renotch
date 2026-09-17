import SwiftUI

struct CompactSystemView: View {
    @ObservedObject var state: SystemMetricsState

    private var hasMemory: Bool { state.memoryText != "--" }
    private var memoryTint: Color { hasMemory ? SystemMetricTint.usage(state.memoryUsage) : Color.notchMuted }
    private var memoryPercentText: String { hasMemory ? "\(Int(state.memoryUsage))%" : "--" }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: hasMemory ? min(max(state.memoryUsage / 100, 0), 1) : 0)
                    .stroke(memoryTint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: state.memoryUsage)
                Image(systemName: "memorychip")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(memoryTint)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("内存")
                        .foregroundStyle(.white)
                    Text(memoryPercentText)
                        .foregroundStyle(hasMemory ? SystemMetricTint.usageText(state.memoryUsage) : Color.notchMuted)
                        .contentTransition(.numericText())
                        .animation(.smooth(duration: 0.25), value: memoryPercentText)
                }
                .font(.system(size: 11, weight: .semibold))
                Text(secondaryText)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.notchMuted)
            }
            .monospacedDigit()
            .lineLimit(1)

            Spacer(minLength: 6)

            SystemSparklineView(samples: state.memorySamples, color: memoryTint, range: 0...100, maxSamples: 30)
                .frame(width: 42, height: 16)

            VStack(alignment: .trailing, spacing: 1) {
                Text("↓\(ByteFormatting.format(state.networkDownloadBps))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Text("↑\(ByteFormatting.format(state.networkUploadBps))")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.notchMuted)
            }
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("系统状态")
        .accessibilityValue("内存 \(memoryPercentText)，CPU \(state.cpuText)，GPU \(state.gpuText)，网络 \(state.networkText.replacingOccurrences(of: "\n", with: " "))")
    }

    private var secondaryText: String {
        "CPU \(state.cpuText) · GPU \(state.gpuText)"
    }
}
