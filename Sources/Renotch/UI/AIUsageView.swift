import SwiftUI

/// Expanded AI 用量 section: three equal cards (Codex · Claude Code · DeepSeek).
/// Every string and state comes from `AIUsagePresentation`; this file only lays
/// the models out and maps tones to colors.
struct AIUsageView: View {
    let aiUsage: AIUsageModel
    let onOpenSettings: () -> Void
    let onAuthorizeDeepSeek: () -> Void
    let onRefreshDeepSeek: () -> Void

    var body: some View {
        // Countdowns and ages are minute-granular; a 30 s tick keeps them honest.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                CodexCardView(monitor: aiUsage.codex, now: context.date, onOpenSettings: onOpenSettings)
                ClaudeCardView(monitor: aiUsage.claude, now: context.date, onOpenSettings: onOpenSettings)
                DeepSeekCardView(
                    monitor: aiUsage.deepSeek,
                    now: context.date,
                    onOpenSettings: onOpenSettings,
                    onAuthorize: onAuthorizeDeepSeek,
                    onRefresh: onRefreshDeepSeek
                )
            }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Monitor bindings

private struct CodexCardView: View {
    @ObservedObject var monitor: CodexUsageMonitor
    let now: Date
    let onOpenSettings: () -> Void

    var body: some View {
        AIUsageCard(
            model: AIUsagePresentation.codexCard(reading: monitor.reading, now: now),
            now: now,
            onAction: { _ in onOpenSettings() },
            onRefresh: nil
        )
    }
}

private struct ClaudeCardView: View {
    @ObservedObject var monitor: ClaudeUsageMonitor
    let now: Date
    let onOpenSettings: () -> Void

    var body: some View {
        AIUsageCard(
            model: AIUsagePresentation.claudeCard(
                status: monitor.status,
                snapshot: monitor.snapshot,
                hooksDisabled: monitor.hooksDisabled,
                settingsPath: monitor.settingsDisplayPath,
                now: now
            ),
            now: now,
            onAction: { _ in onOpenSettings() },
            onRefresh: nil
        )
    }
}

private struct DeepSeekCardView: View {
    @ObservedObject var monitor: DeepSeekBalanceMonitor
    let now: Date
    let onOpenSettings: () -> Void
    let onAuthorize: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        AIUsageCard(
            model: AIUsagePresentation.deepSeekCard(
                keyState: monitor.keyState,
                status: monitor.status,
                snapshot: monitor.snapshot,
                isRefreshing: monitor.isRefreshing,
                now: now
            ),
            now: now,
            onAction: { action in
                switch action {
                case .openSettings: onOpenSettings()
                case .retry: onRefresh()
                case .authorizeKeychain: onAuthorize()
                }
            },
            onRefresh: onRefresh
        )
    }
}

// MARK: - Card

private struct AIUsageCard: View {
    let model: AIUsageCardModel
    let now: Date
    let onAction: (AIUsageAction) -> Void
    /// The DeepSeek header doubles as its refresh control.
    let onRefresh: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .frame(height: 16)
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        // minWidth 0 keeps the three cards exactly equal even when a header carries a chip.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.title)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: model.icon)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .accessibilityHidden(true)
            Text(model.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(2)
            Spacer(minLength: 2)
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if model.isRefreshable, let onRefresh {
            // While the body itself shows the loading state, one spinner is enough.
            if model.trailing != .none || (model.isRefreshing && !isLoadingBody) {
                Button(action: onRefresh) {
                    refreshLabel
                }
                .buttonStyle(.plain)
                .help(model.help ?? "")
                .accessibilityLabel("刷新余额")
            }
        } else {
            trailingLabel
                .help(model.help ?? "")
        }
    }

    private var isLoadingBody: Bool {
        if case .loading = model.body { return true }
        return false
    }

    @ViewBuilder
    private var refreshLabel: some View {
        if case .chip = model.trailing {
            trailingLabel
        } else if model.isRefreshing {
            ProgressView()
                .controlSize(.mini)
                .frame(height: 14)
        } else {
            trailingLabel
        }
    }

    @ViewBuilder
    private var trailingLabel: some View {
        switch model.trailing {
        case .none:
            EmptyView()
        case let .age(text, tone):
            ageLabel(text, failed: false, tone: tone)
        case let .refreshFailed(ageText):
            ageLabel(ageText, failed: true, tone: .amber)
        case let .chip(text, tone):
            Text(text)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tone.textColor)
                .padding(.horizontal, 5)
                .frame(height: 14)
                .background(Capsule().fill(tone.textColor.opacity(0.14)))
                .fixedSize()
        }
    }

    /// Falls back to the icon alone when a narrow notch leaves no room for the text.
    private func ageLabel(_ text: String?, failed: Bool, tone: AIUsageTone) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 3) {
                if failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 7.5, weight: .semibold))
                }
                if let text {
                    Text(text)
                        .font(.system(size: 8, weight: .medium))
                        .monospacedDigit()
                }
            }
            .fixedSize()
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "clock")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(tone.textColor)
    }

    @ViewBuilder
    private var content: some View {
        switch model.body {
        case let .loading(text):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(text)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.notchMuted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .message(message):
            messageBody(message)
        case let .limits(rows):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    AIUsageLimitRowView(cardTitle: model.title, row: row, display: row.display(now: now))
                }
            }
        case let .balance(balance):
            balanceBody(balance)
        }
    }

    private func messageBody(_ message: AIUsageMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: message.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(message.tone.textColor)
                    .accessibilityHidden(true)
                Text(message.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            Text(message.detail)
                .font(.system(size: 9))
                .foregroundStyle(Color.notchMuted)
                .lineLimit(4)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action = message.action {
                Button {
                    onAction(action)
                } label: {
                    Text(action.title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func balanceBody(_ balance: AIUsageBalanceBody) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(balance.totalLabel)
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Color.notchMuted)
            if let total = balance.totalText {
                Text(total)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(balance.isAvailable ? Color.white : SystemMetricTint.rose)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.bottom, 3)
            }
            if let empty = balance.emptyText {
                Text(empty)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.notchMuted)
            }
            ForEach(balance.lines) { line in
                HStack(spacing: 4) {
                    Text(line.label)
                        .foregroundStyle(Color.notchMuted)
                    Spacer(minLength: 4)
                    Text(line.value)
                        .foregroundStyle(.white.opacity(0.8))
                        .monospacedDigit()
                }
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.title) 余额")
        .accessibilityValue(balance.accessibilityValue)
    }
}

// MARK: - Limit row

private struct AIUsageLimitRowView: View {
    let cardTitle: String
    let row: AIUsageLimitRow
    let display: AIUsageLimitRowDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(row.title)
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Color.notchMuted)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("已用")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.notchMuted)
                Text(display.percentText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(display.percentTone.textColor)
            }
            SystemRatioBar(ratio: display.ratio, tint: display.percentTone.barColor)
            Text(display.caption)
                .font(.system(size: 8.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(display.captionTone.textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .help(display.help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cardTitle) \(row.title)限额")
        .accessibilityValue(display.accessibilityValue)
    }
}

// MARK: - Tones

extension AIUsageTone {
    /// Numbers, captions and icons.
    var textColor: Color {
        switch self {
        case .primary: return .white
        case .muted: return .notchMuted
        case .blue: return SystemMetricTint.blueText
        case .amber: return SystemMetricTint.amber
        case .rose: return SystemMetricTint.rose
        case .green: return SystemMetricTint.charging
        }
    }

    /// Bar fills.
    var barColor: Color {
        switch self {
        case .primary: return .white
        case .muted: return Color.white.opacity(0.2)
        case .blue: return SystemMetricTint.blue
        case .amber: return SystemMetricTint.amber
        case .rose: return SystemMetricTint.rose
        case .green: return SystemMetricTint.charging
        }
    }
}
