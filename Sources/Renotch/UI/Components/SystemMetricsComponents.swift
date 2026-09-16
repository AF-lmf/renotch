import SwiftUI

/// Load colors from MacStatus's dark palette (the notch is always dark):
/// normal = blue, elevated = amber, overloaded = rose, split at 60% / 80%.
enum SystemMetricTint {
    static let blue = Color(red: 0x4D / 255, green: 0xA3 / 255, blue: 0xFF / 255)
    static let blueText = Color(red: 0x7A / 255, green: 0xB6 / 255, blue: 0xFF / 255)
    static let amber = Color(red: 0xE3 / 255, green: 0xA2 / 255, blue: 0x4A / 255)
    static let rose = Color(red: 0xF2 / 255, green: 0x6D / 255, blue: 0x7D / 255)
    static let charging = Color(red: 0x5C / 255, green: 0xD9 / 255, blue: 0x8A / 255)

    /// Accent for rings, bars and sparklines.
    static func usage(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return blue
        case ..<80: return amber
        default: return rose
        }
    }

    /// Slightly lighter variant for large numbers.
    static func usageText(_ percent: Double) -> Color {
        percent < 60 ? blueText : usage(percent)
    }

    static func memoryPressure(_ level: MemoryPressureLevel?) -> Color {
        switch level {
        case .warning: return amber
        case .critical: return rose
        default: return Color.notchMuted
        }
    }

    static func thermal(_ state: SystemThermalState) -> Color {
        switch state {
        case .fair: return amber
        case .serious, .critical: return rose
        case .nominal, .unknown: return Color.notchMuted
        }
    }
}

/// Rolling line chart for recent metric history, ported from MacStatus `SparklineView`.
/// Pass `range` to draw on a fixed scale (e.g. 0...100 for percentages); without it the
/// chart auto-scales to the visible samples like the original.
struct SystemSparklineView: View {
    let samples: [Double]
    let color: Color
    var range: ClosedRange<Double>?
    var maxSamples: Int = SystemMetricsState.sparklineCapacity
    var showFill: Bool = true

    var body: some View {
        Canvas { context, size in
            let displaySamples = Array(samples.suffix(maxSamples))
            guard displaySamples.count >= 2 else { return }

            let minValue = range?.lowerBound ?? displaySamples.min() ?? 0
            let maxValue = range?.upperBound ?? displaySamples.max() ?? 100
            let span = max(maxValue - minValue, 1)
            let stepX = size.width / CGFloat(displaySamples.count - 1)
            let padding: CGFloat = 1.5

            func point(_ index: Int, _ value: Double) -> CGPoint {
                let clamped = min(max(value, minValue), maxValue)
                let normalizedY = CGFloat((clamped - minValue) / span)
                return CGPoint(
                    x: CGFloat(index) * stepX,
                    y: size.height - padding - normalizedY * (size.height - 2 * padding)
                )
            }

            var line = Path()
            var fill = Path()
            for (index, value) in displaySamples.enumerated() {
                let current = point(index, value)
                if index == 0 {
                    line.move(to: current)
                    fill.move(to: CGPoint(x: current.x, y: size.height))
                    fill.addLine(to: current)
                } else {
                    line.addLine(to: current)
                    fill.addLine(to: current)
                }
            }
            let last = point(displaySamples.count - 1, displaySamples[displaySamples.count - 1])
            fill.addLine(to: CGPoint(x: last.x, y: size.height))
            fill.closeSubpath()

            if showFill {
                context.fill(
                    fill,
                    with: .linearGradient(
                        Gradient(colors: [color.opacity(0.30), color.opacity(0.02)]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
            }
            context.stroke(
                line,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)),
                with: .color(color)
            )
        }
        .accessibilityHidden(true)
    }
}

/// Thin proportional bar used by the process list.
struct SystemRatioBar: View {
    let ratio: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.09))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * CGFloat(min(max(ratio, 0), 1)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
