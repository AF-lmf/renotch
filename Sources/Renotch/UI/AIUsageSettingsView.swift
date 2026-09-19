import SwiftUI

/// Settings → AI 用量: where Codex limits come from, the Claude Code status-line
/// connection, and the DeepSeek API key. Copy comes from `AIUsagePresentation`.
struct AIUsageSettingsView: View {
    let aiUsage: AIUsageModel

    var body: some View {
        VStack(spacing: 16) {
            CodexSettingsCard(monitor: aiUsage.codex)
            ClaudeSettingsCard(monitor: aiUsage.claude)
            DeepSeekSettingsCard(monitor: aiUsage.deepSeek)
        }
        .task {
            // One Codex read and one Claude Code check; the Keychain is asked for
            // metadata only, so opening this tab never shows a dialog.
            aiUsage.codex.refreshNow()
            aiUsage.claude.refreshStatus()
            await aiUsage.deepSeek.reloadKeyState()
        }
    }
}

// MARK: - Codex

private struct CodexSettingsCard: View {
    @ObservedObject var monitor: CodexUsageMonitor

    var body: some View {
        SettingCard(title: "Codex", icon: "terminal.fill", iconColor: .gray) {
            VStack(spacing: 0) {
                let row = AIUsagePresentation.codexSettingsRow(reading: monitor.reading, codexPath: monitor.codexHomeDisplayPath)
                SettingRow(title: "限额数据", subtitle: row.subtitle) {
                    if let badge = row.badge {
                        AIUsageBadgeView(badge: badge)
                    }
                }

                Divider().opacity(0.12).padding(.vertical, 8)

                SettingRow(title: "最近记录", subtitle: "Codex 只在你使用时写入限额，久未使用时数据可能过时。") {
                    Text(monitor.reading?.main.map { AIUsageFormatting.shortDateTime($0.observedAt) } ?? "暂无")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Divider().opacity(0.12).padding(.vertical, 8)

                AIUsageSettingsNote(icon: "lock.shield.fill", text: "只读取日志中的限额数字，不读取对话内容和登录凭据，也不会修改 Codex 的任何文件。")
            }
        }
    }
}

// MARK: - Claude Code

private struct ClaudeSettingsCard: View {
    @ObservedObject var monitor: ClaudeUsageMonitor
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingCard(title: "Claude Code", icon: "sparkle", iconColor: .orange) {
            VStack(alignment: .leading, spacing: 0) {
                let row = AIUsagePresentation.claudeSettingsRow(
                    status: monitor.status,
                    hooksDisabled: monitor.hooksDisabled,
                    settingsPath: monitor.settingsDisplayPath
                )
                SettingRow(title: "连接 Claude Code", subtitle: row.subtitle) {
                    HStack(spacing: 8) {
                        if let badge = row.badge {
                            AIUsageBadgeView(badge: badge)
                        }
                        if monitor.isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if let primary = row.primary {
                            Button(primary.title) { perform(primary) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .tint(.blue)
                                .disabled(monitor.isWorking)
                        }
                        if let secondary = row.secondary {
                            Button(secondary.title) { perform(secondary) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(monitor.isWorking)
                                .help(row.secondaryHelp ?? "")
                        }
                    }
                }

                if monitor.state != nil, monitor.status == .installed || monitor.status == .changedExternally {
                    Divider().opacity(0.12).padding(.vertical, 8)

                    SettingRow(title: "原状态栏命令", subtitle: monitor.originalSummary) {
                        if let backup = monitor.backupURL {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([backup])
                            } label: {
                                Label("显示备份", systemImage: "doc.on.doc")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Divider().opacity(0.12).padding(.vertical, 8)

                    SettingRow(title: "最近更新", subtitle: "Claude Code 每次刷新状态栏时更新。") {
                        Text(monitor.snapshot.map { AIUsageFormatting.shortDateTime($0.updatedAt) } ?? "尚未收到")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().opacity(0.12).padding(.vertical, 8)

                VStack(alignment: .leading, spacing: 8) {
                    AIUsageSettingsNote(
                        icon: "info.circle",
                        text: AIUsagePresentation.claudeExplanation(settingsPath: monitor.settingsDisplayPath)
                    )
                    ForEach(row.extraNotes, id: \.self) { note in
                        AIUsageSettingsNote(icon: "exclamationmark.triangle.fill", text: note, tint: .orange)
                    }
                    if let error = monitor.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// No confirmation dialog: the explanation sits next to the button and
    /// 断开 restores the original file.
    private func perform(_ action: ClaudeSettingsAction) {
        Task {
            switch action {
            case .connect, .reconnect:
                if await monitor.connect() {
                    model.showMessage("已连接 Claude Code")
                }
            case .disconnect:
                if let outcome = await monitor.disconnect() {
                    model.showMessage(AIUsagePresentation.claudeDisconnectMessage(outcome))
                }
            }
        }
    }
}

// MARK: - DeepSeek

private struct DeepSeekSettingsCard: View {
    @ObservedObject var monitor: DeepSeekBalanceMonitor
    /// The pasted key, only until 保存; never pre-filled with the stored key.
    @State private var draft = ""
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var isConfirmingClear = false

    var body: some View {
        SettingCard(title: "DeepSeek", icon: "yensign.circle.fill", iconColor: .blue) {
            VStack(alignment: .leading, spacing: 0) {
                SettingRow(title: "API 密钥", subtitle: keySubtitle) {
                    keyControls
                }

                if let status = AIUsagePresentation.deepSeekSettingsStatus(
                    keyState: monitor.keyState,
                    status: monitor.status,
                    snapshot: monitor.snapshot
                ) {
                    statusView(status)
                        .padding(.top, 8)
                }

                Divider().opacity(0.12).padding(.vertical, 8)

                SettingRow(title: "账户余额", subtitle: isKeySaved ? "展开“AI 用量”时查询，之后每 5 分钟刷新一次。" : "保存密钥后显示。") {
                    HStack(spacing: 8) {
                        Text(balanceText)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(monitor.snapshot?.balance.primary == nil ? .secondary : .primary)
                        Button("立即查询") { monitor.refreshManually() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!isKeySaved || monitor.isRefreshing)
                    }
                }

                Divider().opacity(0.12).padding(.vertical, 8)

                HStack(alignment: .center, spacing: 10) {
                    AIUsageSettingsNote(icon: "lock.shield.fill", text: "密钥只用于直接向 api.deepseek.com 查询余额，不会用于其他请求，也不会写入日志或文件。")
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        linkButton("获取 API 密钥", url: DeepSeekBalanceAPI.apiKeysPage)
                        if monitor.snapshot?.balance.isAvailable == false {
                            linkButton("前往充值", url: DeepSeekBalanceAPI.topUpPage)
                        }
                    }
                }
            }
        }
        .confirmationDialog("清除 DeepSeek API 密钥？", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                Task { await monitor.deleteKey() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从“钥匙串”中移除此密钥，DeepSeek 平台上的密钥不受影响。")
        }
    }

    private var isKeySaved: Bool {
        if case .saved = monitor.keyState { return true }
        return false
    }

    private var keySubtitle: String {
        switch monitor.keyState {
        case .unknown: return "正在检查…"
        case .missing: return "用于查询账户余额，只保存在这台 Mac 的“钥匙串”中。"
        case .saved(let hint): return DeepSeekKeyHint.display(hint: hint)
        }
    }

    private var balanceText: String {
        guard let primary = monitor.snapshot?.balance.primary else { return "--" }
        return AIUsageFormatting.money(primary.total, currency: primary.currency)
    }

    @ViewBuilder
    private var keyControls: some View {
        switch monitor.keyState {
        case .unknown:
            EmptyView()
        case .missing:
            keyField(canCancel: false)
        case .saved:
            if isEditing {
                keyField(canCancel: true)
            } else {
                HStack(spacing: 8) {
                    Button("更换…") { isEditing = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("清除", role: .destructive) { isConfirmingClear = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func keyField(canCancel: Bool) -> some View {
        HStack(spacing: 8) {
            SecureField("sk-…", text: $draft)
                .textFieldStyle(.plain)
                .padding(8)
                // Shrinks before the buttons do in a narrow Settings window.
                .frame(minWidth: 140, idealWidth: 220, maxWidth: 220)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .onSubmit(save)

            Button("保存", action: save)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.blue)
                .disabled(DeepSeekKeyHint.sanitize(draft) == nil || isSaving)
                .fixedSize()

            if canCancel {
                Button("取消") {
                    draft = ""
                    isEditing = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private func statusView(_ status: DeepSeekSettingsStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(status.tone.settingsColor)
                    .fixedSize(horizontal: false, vertical: true)
                if status.offersAuthorization {
                    Button("授权读取") { monitor.authorizeKeychainAccess() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(monitor.isRefreshing)
                }
            }
            if let footnote = status.footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func linkButton(_ title: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: "arrow.up.right.square")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
    }

    /// The draft is cleared on every attempt, so the key never lingers in view state.
    private func save() {
        guard !isSaving, DeepSeekKeyHint.sanitize(draft) != nil else { return }
        let raw = draft
        draft = ""
        isSaving = true
        Task {
            let saved = await monitor.saveKey(raw)
            isSaving = false
            if saved { isEditing = false }
        }
    }
}

// MARK: - Shared pieces

/// The 已授权 capsule style from the Focus Blocker tab.
private struct AIUsageBadgeView: View {
    let badge: AIUsageBadge

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: badge.icon)
                .foregroundStyle(badge.tone.settingsColor)
            Text(badge.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(badge.tone.settingsColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(badge.tone.settingsColor.opacity(0.12))
        .clipShape(Capsule())
        .fixedSize()
    }
}

private struct AIUsageSettingsNote: View {
    let icon: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private extension AIUsageTone {
    /// System colors for the Settings window.
    var settingsColor: Color {
        switch self {
        case .primary: return .primary
        case .muted: return .secondary
        case .blue: return .blue
        case .amber: return .orange
        case .rose: return .red
        case .green: return .green
        }
    }
}
