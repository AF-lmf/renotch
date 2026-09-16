import SwiftUI

struct CompactSystemView: View {
    @ObservedObject var state: SystemMetricsState

    private var hasCPU: Bool { state.cpuText != "--" }
    private var cpuTint: Color { hasCPU ? SystemMetricTint.usage(state.cpuUsage) : Color.notchMuted }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: hasCPU ? min(max(state.cpuUsage / 100, 0), 1) : 0)
                    .stroke(cpuTint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: state.cpuUsage)
                Image(systemName: "cpu")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(cpuTint)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("CPU")
                        .foregroundStyle(.white)
                    Text(state.cpuText)
                        .foregroundStyle(hasCPU ? SystemMetricTint.usageText(state.cpuUsage) : Color.notchMuted)
                        .contentTransition(.numericText())
                        .animation(.smooth(duration: 0.25), value: state.cpuText)
                }
                .font(.system(size: 11, weight: .semibold))
                Text(secondaryText)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.notchMuted)
            }
            .monospacedDigit()
            .lineLimit(1)

            Spacer(minLength: 6)

            SystemSparklineView(samples: state.cpuSamples, color: cpuTint, range: 0...100, maxSamples: 30)
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
        .accessibilityLabel("System metrics")
        .accessibilityValue("CPU \(state.cpuText), \(secondaryText), network \(state.networkText.replacingOccurrences(of: "\n", with: " "))")
    }

    private var secondaryText: String {
        let memory = state.memoryText == "--" ? "--" : "\(Int(state.memoryUsage))%"
        return "MEM \(memory) · GPU \(state.gpuText)"
    }
}
