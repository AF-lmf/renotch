import Foundation

// Foundation-only view models for the AI 用量 cards and Settings rows. Every
// user-facing string lives here so tests can assert it; the SwiftUI views only
// map tones to colors and lay the models out.

enum AIUsageTone: Equatable, Sendable {
    case primary, muted, blue, amber, rose, green
}

enum AIUsageAction: Equatable, Sendable {
    case openSettings, retry, authorizeKeychain

    var title: String {
        switch self {
        case .openSettings: return "前往设置"
        case .retry: return "重试"
        case .authorizeKeychain: return "授权"
        }
    }
}

struct AIUsageMessage: Equatable, Sendable {
    let icon: String
    let title: String
    let detail: String
    let tone: AIUsageTone
    let action: AIUsageAction?
}

struct AIUsageLimitRowDisplay: Equatable, Sendable {
    let percentText: String
    let ratio: Double
    let percentTone: AIUsageTone
    let caption: String
    let captionTone: AIUsageTone
    let help: String?
    let accessibilityValue: String
}

struct AIUsageLimitRow: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetsAt: Date?
    let limitReached: Bool

    func display(now: Date) -> AIUsageLimitRowDisplay {
        let percent = AIUsageFormatting.percentText(usedPercent)

        if let resetsAt, resetsAt <= now {
            // The window has reset, but the tool has not reported a new value
            // yet: 0% is unknown and the old value is no longer current.
            return AIUsageLimitRowDisplay(
                percentText: "--",
                ratio: 0,
                percentTone: .muted,
                caption: "已重置 · 使用后更新",
                captionTone: .muted,
                help: "上次记录：已用 \(percent)\n\(AIUsageFormatting.resetAbsoluteText(resetsAt))",
                accessibilityValue: "已重置，使用后更新"
            )
        }

        let reset = resetsAt.map { AIUsageFormatting.resetText(resetsAt: $0, now: now) }
        let help = resetsAt.map(AIUsageFormatting.resetAbsoluteText)

        if limitReached || AIUsageFormatting.isExhausted(usedPercent) {
            return AIUsageLimitRowDisplay(
                percentText: percent,
                ratio: 1,
                percentTone: .rose,
                caption: reset.map { "已达上限 · \($0)" } ?? "已达上限",
                captionTone: .rose,
                help: help,
                accessibilityValue: ["已用 \(percent)", "已达上限", reset].compactMap { $0 }.joined(separator: "，")
            )
        }

        let caption = reset ?? "未提供重置时间"
        return AIUsageLimitRowDisplay(
            percentText: percent,
            ratio: AIUsageFormatting.ratio(usedPercent),
            percentTone: AIUsageFormatting.tone(forUsage: usedPercent),
            caption: caption,
            captionTone: .muted,
            help: help,
            accessibilityValue: "已用 \(percent)，\(caption)"
        )
    }
}

struct AIUsageBalanceLine: Equatable, Sendable, Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

struct AIUsageBalanceBody: Equatable, Sendable {
    let isAvailable: Bool
    let totalLabel = "可用余额"
    /// nil when the response listed no balances.
    let totalText: String?
    let lines: [AIUsageBalanceLine]
    let emptyText: String?
    let accessibilityValue: String
}

enum AIUsageCardBody: Equatable, Sendable {
    case loading(String)
    case message(AIUsageMessage)
    case limits([AIUsageLimitRow])
    case balance(AIUsageBalanceBody)
}

enum AIUsageTrailing: Equatable, Sendable {
    case none
    case age(text: String, tone: AIUsageTone)
    case refreshFailed(ageText: String?)
    case chip(text: String, tone: AIUsageTone)
}

struct AIUsageCardModel: Equatable, Sendable {
    let title: String
    let icon: String
    let trailing: AIUsageTrailing
    let help: String?
    let body: AIUsageCardBody
    let isRefreshable: Bool
    let isRefreshing: Bool
}

/// One line of the collapsed notch's AI 用量 column (Codex / DeepSeek). The
/// compact panel only has room for a title, a value and one short caption, so
/// every monitor state collapses into exactly those plus a tone.
struct AIUsageCompactLine: Equatable, Sendable {
    let title: String
    let icon: String
    /// "12% · 40%" or "¥42.50"; "--" while unknown.
    let value: String
    /// Window labels ("5 小时 · 每周") or freshness ("3 分钟前"); nil when bare.
    let caption: String?
    let tone: AIUsageTone
    let help: String?
    let accessibilityValue: String
}

/// Capsule shown next to a Settings row (the 已授权 style).
struct AIUsageBadge: Equatable, Sendable {
    let text: String
    let icon: String
    let tone: AIUsageTone
}

struct CodexSettingsRow: Equatable, Sendable {
    let subtitle: String
    let badge: AIUsageBadge?
}

enum ClaudeSettingsAction: Equatable, Sendable {
    case connect, reconnect, disconnect

    var title: String {
        switch self {
        case .connect: return "连接"
        case .reconnect: return "重新连接"
        case .disconnect: return "断开"
        }
    }
}

struct ClaudeSettingsRow: Equatable, Sendable {
    let subtitle: String
    let badge: AIUsageBadge?
    let primary: ClaudeSettingsAction?
    let secondary: ClaudeSettingsAction?
    /// Tooltip for the secondary button.
    let secondaryHelp: String?
    let extraNotes: [String]
}

struct DeepSeekSettingsStatus: Equatable, Sendable {
    let text: String
    let tone: AIUsageTone
    /// Show 授权读取 next to the text.
    let offersAuthorization: Bool
    let footnote: String?

    init(_ text: String, tone: AIUsageTone, offersAuthorization: Bool = false, footnote: String? = nil) {
        self.text = text
        self.tone = tone
        self.offersAuthorization = offersAuthorization
        self.footnote = footnote
    }
}

extension DeepSeekBalanceFailure {
    var icon: String {
        switch self {
        case .unreachable, .timedOut: return "wifi.slash"
        case .rateLimited: return "clock"
        case .invalidKey, .serverUnavailable, .badStatus, .unreadableResponse: return "exclamationmark.triangle.fill"
        }
    }

    var title: String {
        switch self {
        case .invalidKey: return "API 密钥无效"
        case .unreachable: return "无法连接到 DeepSeek"
        case .timedOut: return "连接 DeepSeek 超时"
        case .rateLimited: return "请求过于频繁"
        case .serverUnavailable: return "DeepSeek 服务暂时不可用"
        case .badStatus: return "DeepSeek 返回了意外的响应"
        case .unreadableResponse: return "无法识别 DeepSeek 返回的数据"
        }
    }

    var detail: String {
        switch self {
        case .invalidKey: return "DeepSeek 拒绝了此密钥，请在设置中重新填写。"
        case .unreachable: return "请检查网络连接，稍后会自动重试。"
        case .timedOut, .rateLimited, .unreadableResponse: return "稍后会自动重试。"
        case .serverUnavailable(let code), .badStatus(let code): return "HTTP \(code)，稍后会自动重试。"
        }
    }
}

enum AIUsagePresentation {
    static let codexTitle = "Codex"
    static let claudeTitle = "Claude Code"
    static let deepSeekTitle = "DeepSeek"

    // MARK: - Codex card

    static func codexCard(reading: CodexUsageReading?, now: Date) -> AIUsageCardModel {
        func card(_ body: AIUsageCardBody, trailing: AIUsageTrailing = .none, help: String? = nil) -> AIUsageCardModel {
            AIUsageCardModel(title: codexTitle, icon: "terminal", trailing: trailing, help: help,
                             body: body, isRefreshable: false, isRefreshing: false)
        }
        let loading = AIUsageCardBody.loading("正在读取 Codex 记录…")

        guard let reading else { return card(loading) }
        if reading.status == .codexNotFound {
            return card(.message(AIUsageMessage(
                icon: "questionmark.circle",
                title: "未检测到 Codex",
                detail: "使用 Codex CLI 或 Codex App 后，这里会显示限额。",
                tone: .muted,
                action: nil
            )))
        }
        guard let main = reading.main else {
            if !reading.isComplete { return card(loading) }
            return card(.message(AIUsageMessage(
                icon: "clock", title: "暂无限额数据",
                detail: "最近 8 天没有 Codex 限额记录，在 Codex 中发送一条消息后显示。",
                tone: .muted, action: nil
            )))
        }
        let rows = main.windows.sorted { $0.windowMinutes < $1.windowMinutes }.prefix(2).map { window in
            AIUsageLimitRow(id: "codex.\(window.windowMinutes)", title: window.label,
                            usedPercent: window.usedPercent, resetsAt: window.resetsAt,
                            limitReached: main.reachedType != nil)
        }
        var help = [AIUsageFormatting.updatedAbsoluteText(main.observedAt),
                    "额度来自本机 Codex 日志。",
                    "记录可能滞后；其他设备的使用会在 Codex 下次更新记录后反映。"]
        if let plan = main.planDisplayName { help.append("套餐：\(plan)") }
        return card(.limits(Array(rows)), trailing: logAge(main.observedAt, now: now),
                    help: help.joined(separator: "\n"))
    }

    // MARK: - Claude Code card

    static func claudeCard(
        status: ClaudeBridgeStatus?,
        snapshot: ClaudeUsageSnapshot?,
        hooksDisabled: Bool,
        settingsPath: String,
        now: Date
    ) -> AIUsageCardModel {
        func card(_ body: AIUsageCardBody, trailing: AIUsageTrailing = .none, help: String? = nil) -> AIUsageCardModel {
            AIUsageCardModel(title: claudeTitle, icon: "sparkle", trailing: trailing, help: help,
                             body: body, isRefreshable: false, isRefreshing: false)
        }
        func message(_ icon: String, _ title: String, _ detail: String, _ tone: AIUsageTone, _ action: AIUsageAction?) -> AIUsageCardModel {
            card(.message(AIUsageMessage(icon: icon, title: title, detail: detail, tone: tone, action: action)))
        }

        guard let status else { return card(.loading("正在检查 Claude Code…")) }
        switch status {
        case .claudeNotFound:
            return message("questionmark.circle", "未检测到 Claude Code",
                           "未找到 \(directoryPath(of: settingsPath))，使用过 Claude Code 后可在设置中连接。", .muted, nil)
        case .settingsUnreadable:
            return message("exclamationmark.triangle.fill", "无法读取 Claude Code 设置",
                           "\(settingsPath) 不是有效的 JSON。", .amber, .openSettings)
        case .notInstalled:
            return message("link", "未连接 Claude Code",
                           "在设置中连接后，Claude Code 刷新状态栏时会同步限额。", .muted, .openSettings)
        case .changedExternally:
            return message("exclamationmark.triangle.fill", "连接已失效",
                           "Claude Code 的状态栏设置已被更改，请在设置中重新连接。", .amber, .openSettings)
        case .recordMissing:
            return message("exclamationmark.triangle.fill", "连接记录已丢失",
                           "状态栏仍指向 Re:notch 的脚本，请在设置中查看处理方法。", .amber, .openSettings)
        case .installed:
            break
        }

        guard let snapshot else {
            if hooksDisabled {
                return message("exclamationmark.triangle.fill", "状态栏已被禁用",
                               "settings.json 设置了 disableAllHooks，Claude Code 不会运行状态栏命令。", .amber, nil)
            }
            return message("clock", "等待 Claude Code 数据",
                           "已连接。在 Claude Code 中发送一条消息后显示（仅 Pro 和 Max 订阅提供限额）。", .muted, nil)
        }

        var rows: [AIUsageLimitRow] = []
        func add(_ id: String, _ title: String, _ window: ClaudeUsageSnapshot.Window?) {
            guard let window else { return }
            rows.append(AIUsageLimitRow(id: id, title: title, usedPercent: window.usedPercent,
                                        resetsAt: window.resetsAt, limitReached: false))
        }
        add("claude.five_hour", "5 小时", snapshot.fiveHour)
        add("claude.seven_day", "每周", snapshot.sevenDay)
        if rows.count < 2 { add("claude.spend_limit", "支出限额", snapshot.spendLimit) }

        return card(
            .limits(rows),
            trailing: logAge(snapshot.updatedAt, now: now),
            help: "\(AIUsageFormatting.updatedAbsoluteText(snapshot.updatedAt))\n来自 Claude Code 状态栏，Claude Code 每次回复后更新。"
        )
    }

    // MARK: - DeepSeek card

    static func deepSeekCard(
        keyState: DeepSeekBalanceMonitor.KeyState,
        status: DeepSeekBalanceMonitor.Status,
        snapshot: DeepSeekBalanceMonitor.Snapshot?,
        isRefreshing: Bool,
        now: Date
    ) -> AIUsageCardModel {
        func card(_ body: AIUsageCardBody, trailing: AIUsageTrailing = .none, help: String? = nil) -> AIUsageCardModel {
            AIUsageCardModel(title: deepSeekTitle, icon: "yensign.circle", trailing: trailing, help: help,
                             body: body, isRefreshable: true, isRefreshing: isRefreshing)
        }
        func message(_ icon: String, _ title: String, _ detail: String, _ tone: AIUsageTone, _ action: AIUsageAction?) -> AIUsageCardModel {
            card(.message(AIUsageMessage(icon: icon, title: title, detail: detail, tone: tone, action: action)))
        }

        if keyState == .missing || status == .notConfigured {
            return message("key", "未设置 API 密钥", "在设置中填写 DeepSeek API 密钥后显示余额。", .muted, .openSettings)
        }
        if status == .needsKeychainAccess {
            return message("lock.shield.fill", "需要授权读取密钥",
                           "Re:notch 重新构建后，需要你允许读取“钥匙串”中的密钥。", .amber, .authorizeKeychain)
        }
        if case .keychainError = status {
            return message("exclamationmark.triangle.fill", "无法读取“钥匙串”中的密钥",
                           "请在设置中重新保存 API 密钥。", .rose, .openSettings)
        }
        if status == .failed(.invalidKey) {
            let failure = DeepSeekBalanceFailure.invalidKey
            return message(failure.icon, failure.title, failure.detail, .rose, .openSettings)
        }

        var failure: DeepSeekBalanceFailure?
        if case .failed(let f) = status { failure = f }

        if let snapshot {
            let fetched = AIUsageFormatting.updatedAbsoluteText(snapshot.fetchedAt)
            let age = AIUsageFormatting.ageText(since: snapshot.fetchedAt, now: now)
            let trailing: AIUsageTrailing
            if !snapshot.balance.isAvailable {
                trailing = .chip(text: "余额不足", tone: .rose)
            } else if failure != nil {
                trailing = .refreshFailed(ageText: age)
            } else {
                trailing = .age(text: age, tone: .muted)
            }
            let help = failure.map { "刷新失败：\($0.title)\n\(fetched)\n点按以重试" } ?? "\(fetched)\n点按以刷新余额"
            return card(.balance(balanceBody(snapshot.balance)), trailing: trailing, help: help)
        }

        if let failure {
            return message(failure.icon, failure.title, failure.detail, .amber, .retry)
        }
        return card(.loading("正在查询余额…"))
    }

    static func balanceBody(_ balance: DeepSeekBalance) -> AIUsageBalanceBody {
        let sorted = balance.sortedBalances
        let shortage = balance.isAvailable ? "" : "，余额不足"
        guard let primary = sorted.first else {
            return AIUsageBalanceBody(isAvailable: balance.isAvailable, totalText: nil, lines: [],
                                      emptyText: "暂无余额信息", accessibilityValue: "暂无余额信息" + shortage)
        }
        let total = AIUsageFormatting.money(primary.total, currency: primary.currency)
        var lines = [
            AIUsageBalanceLine(label: "充值余额", value: AIUsageFormatting.money(primary.toppedUp, currency: primary.currency)),
            AIUsageBalanceLine(label: "赠金余额", value: AIUsageFormatting.money(primary.granted, currency: primary.currency)),
        ]
        for other in sorted.dropFirst() {
            lines.append(AIUsageBalanceLine(label: "\(currencyName(other.currency))余额",
                                            value: AIUsageFormatting.money(other.total, currency: other.currency)))
        }
        return AIUsageBalanceBody(isAvailable: balance.isAvailable, totalText: total, lines: lines,
                                  emptyText: nil, accessibilityValue: "可用余额 \(total)" + shortage)
    }

    // MARK: - Settings copy

    static func codexSettingsRow(reading: CodexUsageReading?, codexPath: String) -> CodexSettingsRow {
        guard let reading else { return CodexSettingsRow(subtitle: "正在读取…", badge: nil) }
        if reading.status == .codexNotFound {
            return CodexSettingsRow(
                subtitle: "未找到 \(codexPath)/sessions。使用 Codex CLI 或 Codex App 后会自动显示。",
                badge: AIUsageBadge(text: "未找到", icon: "questionmark.circle", tone: .muted)
            )
        }
        return CodexSettingsRow(
            subtitle: "从 \(codexPath) 读取 Codex CLI 和 Codex App 记录的限额，无需额外设置。",
            badge: AIUsageBadge(text: "已找到", icon: "checkmark.circle.fill", tone: .green)
        )
    }

    /// Always shown next to the 连接 button.
    static func claudeExplanation(settingsPath: String) -> String {
        "连接会修改 \(settingsPath) 中的 statusLine：Claude Code 刷新状态栏时，Re:notch 先记下其中的 5 小时和每周限额，再把同样的数据交给你原来的状态栏命令（如 claude-hud），因此原状态栏照常显示。修改前会备份原文件，点按“断开”即可原样恢复。"
    }

    static func claudeSettingsRow(status: ClaudeBridgeStatus?, hooksDisabled: Bool, settingsPath: String) -> ClaudeSettingsRow {
        var notes: [String] = []
        if case .notInstalled(hasStatusLine: false) = status {
            notes.append("你目前没有设置状态栏，连接后 Claude Code 的状态栏会保持空白。")
        }
        if hooksDisabled {
            notes.append("settings.json 中设置了 disableAllHooks，Claude Code 不会运行状态栏命令，连接后也收不到限额。")
        }
        func row(_ subtitle: String, badge: AIUsageBadge? = nil, primary: ClaudeSettingsAction? = nil,
                 secondary: ClaudeSettingsAction? = nil, secondaryHelp: String? = nil) -> ClaudeSettingsRow {
            ClaudeSettingsRow(subtitle: subtitle, badge: badge, primary: primary, secondary: secondary,
                              secondaryHelp: secondaryHelp, extraNotes: notes)
        }

        guard let status else { return row("正在检查…") }
        switch status {
        case .claudeNotFound:
            return row("未找到 \(directoryPath(of: settingsPath))。安装并运行过 Claude Code 后再连接。",
                       badge: AIUsageBadge(text: "未找到", icon: "questionmark.circle", tone: .muted))
        case .settingsUnreadable:
            return row("无法读取 \(settingsPath)：文件不是有效的 JSON。修复后再连接。",
                       badge: AIUsageBadge(text: "无法读取", icon: "exclamationmark.triangle.fill", tone: .amber))
        case .notInstalled:
            return row("通过 Claude Code 的状态栏读取 5 小时和每周限额（仅 Pro 和 Max 订阅提供）。", primary: .connect)
        case .installed:
            return row("已连接。Claude Code 刷新状态栏时会同步限额。",
                       badge: AIUsageBadge(text: "已连接", icon: "checkmark.circle.fill", tone: .green),
                       secondary: .disconnect)
        case .changedExternally:
            return row("\(settingsPath) 中的状态栏已被其他程序修改，Re:notch 不再收到限额。",
                       badge: AIUsageBadge(text: "连接已失效", icon: "exclamationmark.triangle.fill", tone: .amber),
                       primary: .reconnect, secondary: .disconnect,
                       secondaryHelp: "只清理 Re:notch 的脚本和记录，不会修改 settings.json。")
        case .recordMissing:
            return row("状态栏仍指向 Re:notch 的脚本，但连接记录已丢失，无法自动还原。请在 \(settingsPath) 中手动修改 statusLine。",
                       badge: AIUsageBadge(text: "需要处理", icon: "exclamationmark.triangle.fill", tone: .amber))
        }
    }

    static func claudeDisconnectMessage(_ outcome: ClaudeStatusLineBridge.UninstallOutcome) -> String {
        switch outcome {
        case .restoredBackupExactly, .restoredCommand: return "已断开，已恢复原状态栏"
        case .removedStatusLine, .removedFile: return "已断开，已移除 Re:notch 添加的状态栏"
        case .leftAlone: return "已断开，状态栏设置由其他程序管理，未做更改"
        case .notInstalled: return "未连接 Claude Code"
        }
    }

    /// Subtitle of the 原状态栏命令 row. Never shows the command itself.
    static func claudeOriginalSummary(_ original: ClaudeBridgeState.Original?) -> String {
        let description = ClaudeStatusLineBridge.describeOriginal(original)
        if case .command(let decoded, _) = original,
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "已保留并照常运行：\(description)"
        }
        return description
    }

    static func deepSeekSettingsStatus(
        keyState: DeepSeekBalanceMonitor.KeyState,
        status: DeepSeekBalanceMonitor.Status,
        snapshot: DeepSeekBalanceMonitor.Snapshot?
    ) -> DeepSeekSettingsStatus? {
        switch status {
        case .notConfigured, .idle:
            return nil
        case .loading:
            return DeepSeekSettingsStatus("正在查询余额…", tone: .muted)
        case .loaded:
            guard let balance = snapshot?.balance else { return DeepSeekSettingsStatus("已连接", tone: .green) }
            if !balance.isAvailable { return DeepSeekSettingsStatus("已连接 · 余额不足", tone: .amber) }
            guard let primary = balance.primary else { return DeepSeekSettingsStatus("已连接", tone: .green) }
            return DeepSeekSettingsStatus(
                "已连接 · 可用余额 \(AIUsageFormatting.money(primary.total, currency: primary.currency))",
                tone: .green
            )
        case .failed(.invalidKey):
            return DeepSeekSettingsStatus("DeepSeek 拒绝了此密钥（401），请检查后重新填写。", tone: .rose)
        case .failed(.unreachable), .failed(.timedOut):
            return DeepSeekSettingsStatus("暂时无法连接到 DeepSeek，密钥已保存，稍后会自动重试。", tone: .amber)
        case .failed(let failure):
            return DeepSeekSettingsStatus("\(failure.title)，稍后会自动重试。", tone: .amber)
        case .needsKeychainAccess:
            return DeepSeekSettingsStatus(
                "此版本的 Re:notch 需要你授权才能读取“钥匙串”中的密钥。",
                tone: .amber,
                offersAuthorization: true,
                footnote: "macOS 会弹出系统对话框，可能需要输入登录密码，请选择“始终允许”。重新构建 Re:notch 后需要再次授权。"
            )
        case .keychainError(.notOwner):
            return DeepSeekSettingsStatus(
                "无法清除：该密钥由其他版本的 Re:notch 保存。请在“钥匙串访问”中删除“Re:notch DeepSeek API 密钥”。",
                tone: .rose
            )
        case .keychainError(.denied):
            return DeepSeekSettingsStatus("已取消“钥匙串”授权。", tone: .amber)
        case .keychainError(.accessRequired):
            return DeepSeekSettingsStatus("无法访问“钥匙串”：钥匙串可能已锁定。", tone: .rose)
        case .keychainError(.unexpected(let code)):
            return DeepSeekSettingsStatus("“钥匙串”错误（错误代码 \(code)）。", tone: .rose)
        }
    }

    // MARK: - Compact (collapsed notch) lines

    /// Codex line for the collapsed notch: every un-reset window, tightest tone
    /// wins. Mirrors `codexCard`'s states so the two never disagree.
    static func codexCompactLine(reading: CodexUsageReading?, now: Date) -> AIUsageCompactLine {
        func line(
            _ value: String,
            _ caption: String?,
            _ tone: AIUsageTone,
            help: String? = nil,
            accessibility: String
        ) -> AIUsageCompactLine {
            AIUsageCompactLine(title: codexTitle, icon: "terminal", value: value, caption: caption,
                               tone: tone, help: help, accessibilityValue: accessibility)
        }
        let pending = line("--", "读取中", .muted, accessibility: "正在读取 Codex 记录")

        guard let reading else { return pending }
        if reading.status == .codexNotFound {
            return line("--", "未检测到", .muted,
                        help: "使用 Codex CLI 或 Codex App 后，这里会显示限额。",
                        accessibility: "未检测到 Codex")
        }
        guard let main = reading.main else {
            if !reading.isComplete { return pending }
            return line("--", "暂无记录", .muted,
                        help: "最近 8 天没有 Codex 限额记录，在 Codex 中发送一条消息后显示。",
                        accessibility: "暂无 Codex 限额数据")
        }

        let windows = main.windows
            .filter { !$0.hasReset(at: now) }
            .sorted { $0.windowMinutes < $1.windowMinutes }
            .prefix(2)
        guard !windows.isEmpty else {
            return line("--", "已重置", .muted,
                        help: "\(AIUsageFormatting.updatedAbsoluteText(main.observedAt))\n使用后更新。",
                        accessibility: "Codex 限额已重置，使用后更新")
        }

        let values = windows.map { AIUsageFormatting.percentText($0.usedPercent) }.joined(separator: " · ")
        let labels = windows.map(\.label).joined(separator: " · ")
        let tightest = windows.map(\.usedPercent).max() ?? 0
        let reached = main.reachedType != nil || AIUsageFormatting.isExhausted(tightest)
        let tone: AIUsageTone = reached ? .rose : AIUsageFormatting.tone(forUsage: tightest)

        var help = [AIUsageFormatting.updatedAbsoluteText(main.observedAt)]
        if let plan = main.planDisplayName { help.append("套餐：\(plan)") }
        if reached { help.append("已达上限") }
        return line(values, labels, tone, help: help.joined(separator: "\n"),
                    accessibility: "Codex 已用 \(values)，\(labels)")
    }

    /// DeepSeek line for the collapsed notch: the available balance, with the
    /// key/failure states reduced to a caption.
    static func deepSeekCompactLine(
        keyState: DeepSeekBalanceMonitor.KeyState,
        status: DeepSeekBalanceMonitor.Status,
        snapshot: DeepSeekBalanceMonitor.Snapshot?,
        now: Date
    ) -> AIUsageCompactLine {
        func line(
            _ value: String,
            _ caption: String?,
            _ tone: AIUsageTone,
            help: String? = nil,
            accessibility: String
        ) -> AIUsageCompactLine {
            AIUsageCompactLine(title: deepSeekTitle, icon: "yensign.circle", value: value, caption: caption,
                               tone: tone, help: help, accessibilityValue: accessibility)
        }

        if keyState == .missing || status == .notConfigured {
            return line("未设置", nil, .muted,
                        help: "在设置中填写 DeepSeek API 密钥后显示余额。",
                        accessibility: "未设置 DeepSeek API 密钥")
        }
        if status == .needsKeychainAccess {
            return line("--", "需授权", .amber,
                        help: "需要你允许读取“钥匙串”中的密钥。",
                        accessibility: "需要授权读取 DeepSeek 密钥")
        }
        if case .keychainError = status {
            return line("--", "密钥错误", .rose,
                        help: "请在设置中重新保存 API 密钥。",
                        accessibility: "无法读取 DeepSeek 密钥")
        }
        if status == .failed(.invalidKey) {
            return line("--", "密钥无效", .rose,
                        help: DeepSeekBalanceFailure.invalidKey.detail,
                        accessibility: "DeepSeek API 密钥无效")
        }

        var failure: DeepSeekBalanceFailure?
        if case .failed(let f) = status { failure = f }

        if let snapshot {
            let body = balanceBody(snapshot.balance)
            let value = body.totalText ?? "--"
            let fetched = AIUsageFormatting.updatedAbsoluteText(snapshot.fetchedAt)
            if !snapshot.balance.isAvailable {
                return line(value, "余额不足", .rose,
                            help: "\(fetched)\n余额不足，请及时充值。",
                            accessibility: "DeepSeek 可用余额 \(value)，余额不足")
            }
            let age = AIUsageFormatting.ageText(since: snapshot.fetchedAt, now: now)
            if let failure {
                return line(value, age, .amber,
                            help: "刷新失败：\(failure.title)\n\(fetched)\n稍后会自动重试。",
                            accessibility: "DeepSeek 可用余额 \(value)，刷新失败")
            }
            return line(value, age, .green,
                        help: "\(fetched)\n展开刘海可刷新余额。",
                        accessibility: "DeepSeek 可用余额 \(value)，更新于 \(age)")
        }

        if let failure {
            return line("--", failure.title, .amber, help: failure.detail,
                        accessibility: "DeepSeek \(failure.title)")
        }
        return line("--", "查询中", .muted, accessibility: "正在查询 DeepSeek 余额")
    }

    // MARK: - Helpers

    /// Log-based data is never "wrong" for being old; after a day it turns amber.
    private static func logAge(_ date: Date, now: Date) -> AIUsageTrailing {
        let stale = now.timeIntervalSince(date) > AIUsageFormatting.logStaleInterval
        return .age(text: AIUsageFormatting.ageText(since: date, now: now), tone: stale ? .amber : .muted)
    }

    private static func currencyName(_ code: String) -> String {
        switch code.uppercased() {
        case "CNY": return "人民币"
        case "USD": return "美元"
        default: return "\(code) "
        }
    }

    /// "~/.claude/settings.json" → "~/.claude".
    private static func directoryPath(of settingsPath: String) -> String {
        (settingsPath as NSString).deletingLastPathComponent
    }
}
