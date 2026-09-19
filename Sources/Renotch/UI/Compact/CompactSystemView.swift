import SwiftUI

/// Collapsed notch, 系统状态 content. Two columns:
/// left = CPU / GPU / 内存 / 网络, right = Codex 限额 and DeepSeek 余额.
///
/// The AI column is driven by the same monitors as the expanded AI 用量 section,
/// so `AppModel` keeps them active while this content is visible.
struct CompactSystemView: View {
    @ObservedObject var state: SystemMetricsState
    let aiUsage: AIUsageModel
    var showsAIUsage = true

    private var hasMemory: Bool { state.memoryText != "--" }
    private var memoryTint: Color { percentTint(state.memoryUsage, available: hasMemory) }
    private var memoryPercentText: String { hasMemory ? "\(Int(state.memoryUsage))%" : "--" }
    private var hasGPU: Bool {
        state.gpuText != "--" && state.gpuText != SystemMetricsState.unavailableText
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if showsAIUsage {
                columns(detailed: true)
                columns(detailed: false)
            } else {
                systemGrid(detailed: true)
                systemGrid(detailed: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func columns(detailed: Bool) -> some View {
        HStack(spacing: detailed ? 10 : 6) {
            systemGrid(detailed: detailed)
            Spacer(minLength: 0)
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 23)
            aiColumn(detailed: detailed)
        }
    }

    // MARK: - Left: system metrics

    private func systemGrid(detailed: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
            GridRow {
                metric(icon: "cpu", label: "C", value: state.cpuText,
                       tint: percentTint(state.cpuUsage, available: state.cpuText != "--"), detailed: detailed)
                metric(icon: "display", label: "G", value: hasGPU ? state.gpuText : "--",
                       tint: percentTint(state.gpuUsage, available: hasGPU), detailed: detailed)
            }
            GridRow {
                metric(icon: "memorychip", label: "M", value: memoryPercentText,
                       tint: memoryTint, detailed: detailed)
                networkMetric(detailed: detailed)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("系统状态")
        .accessibilityValue("CPU \(state.cpuText)，GPU \(state.gpuText)，内存 \(memoryPercentText)，网络 \(networkAccessibilityText)")
    }

    private func metric(icon: String, label: String, value: String, tint: Color, detailed: Bool) -> some View {
        HStack(spacing: CompactMetricStyle.spacing) {
            metricLabel(icon: icon, label: label, tint: tint, detailed: detailed)
            // Equal widths and trailing alignment keep the % signs in a column,
            // even when adjacent readings have different digit counts.
            CompactMetricStyle.value(value, tint: tint)
                .frame(width: 32, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: 12)
    }

    private func metricLabel(icon: String, label: String, tint: Color, detailed: Bool) -> some View {
        HStack(spacing: CompactMetricStyle.spacing) {
            if detailed { CompactMetricStyle.icon(icon, tint: tint) }
            CompactMetricStyle.caption(label)
                .frame(width: 8, alignment: .center)
        }
    }

    private func networkMetric(detailed: Bool) -> some View {
        HStack(spacing: CompactMetricStyle.spacing) {
            metricLabel(icon: "arrow.up.arrow.down", label: "N", tint: SystemMetricTint.blueText, detailed: detailed)
            CompactMetricStyle.value("↓\(ByteFormatting.format(state.networkDownloadBps))", tint: SystemMetricTint.blueText)
            if detailed {
                CompactMetricStyle.caption("↑\(ByteFormatting.format(state.networkUploadBps))")
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: 12)
        .help(networkAccessibilityText)
    }

    private func percentTint(_ usage: Double, available: Bool) -> Color {
        available ? SystemMetricTint.usageText(usage) : Color.notchMuted
    }

    private var networkAccessibilityText: String {
        "下载 \(ByteFormatting.format(state.networkDownloadBps))，上传 \(ByteFormatting.format(state.networkUploadBps))"
    }

    // MARK: - Right: AI 用量

    private func aiColumn(detailed: Bool) -> some View {
        // Ages and reset countdowns are minute-granular; a 30 s tick matches the
        // expanded AI 用量 section.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                CompactCodexLine(monitor: aiUsage.codex, now: context.date, detailed: detailed)
                CompactDeepSeekLine(monitor: aiUsage.deepSeek, now: context.date, detailed: detailed)
            }
        }
        .fixedSize(horizontal: detailed, vertical: true)
    }
}

// MARK: - Monitor bindings

private struct CompactCodexLine: View {
    @ObservedObject var monitor: CodexUsageMonitor
    let now: Date
    let detailed: Bool

    var body: some View {
        CompactAILine(line: AIUsagePresentation.codexCompactLine(reading: monitor.reading, now: now), detailed: detailed)
    }
}

private struct CompactDeepSeekLine: View {
    @ObservedObject var monitor: DeepSeekBalanceMonitor
    let now: Date
    let detailed: Bool

    var body: some View {
        CompactAILine(
            line: AIUsagePresentation.deepSeekCompactLine(
                keyState: monitor.keyState,
                status: monitor.status,
                snapshot: monitor.snapshot,
                now: now
            ),
            detailed: detailed
        )
    }
}

private struct CompactAILine: View {
    let line: AIUsageCompactLine
    let detailed: Bool

    var body: some View {
        HStack(spacing: CompactMetricStyle.spacing) {
            if detailed { CompactMetricStyle.icon(line.icon, tint: line.tone.textColor) }
            CompactMetricStyle.caption(line.title == "DeepSeek" && !detailed ? "DS" : line.title)
                .fixedSize()
            CompactMetricStyle.value(line.value, tint: line.tone.textColor)
            if detailed, let caption = line.caption {
                CompactMetricStyle.caption(caption)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(height: 12)
        .help([line.accessibilityValue, line.help].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.title)
        .accessibilityValue(line.accessibilityValue)
    }
}

// MARK: - Shared type scale

/// One scale for every icon, caption and value in the compact 系统状态 panel.
/// The metric grid and the AI 用量 lines both build from these, so the two
/// columns cannot drift apart the way hand-written fonts did.
private enum CompactMetricStyle {
    /// Every icon is drawn into the same box so captions line up whatever the
    /// glyph's natural width is (`display` is far wider than `arrow.up.arrow.down`).
    static let iconBox: CGFloat = 11
    static let spacing: CGFloat = 3.5

    static func icon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: iconBox, height: iconBox)
    }

    /// Metric names ("C", "M") and the secondary figure beside a value ("每周").
    static func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(Color.notchMuted)
    }

    /// The one emphasised figure per row.
    ///
    /// Deliberately no `.contentTransition(.numericText())`: the system metrics
    /// refresh every second or two, so the rolling digits were on screen a large
    /// share of the time and read as blurry, misaligned type sitting next to
    /// perfectly static figures.
    static func value(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
    }
}
