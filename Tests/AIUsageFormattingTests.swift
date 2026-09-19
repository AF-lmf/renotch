import Foundation

/// AIUsageFormatting and every string the AI 用量 cards and Settings rows show.
@main
struct AIUsageFormattingTests {
    static func main() {
        var failures: [String] = []
        func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String, line: UInt = #line) {
            if actual != expected { failures.append("line \(line): \(label): expected \(expected), got \(actual)") }
        }
        func expectTrue(_ condition: Bool, _ label: String, line: UInt = #line) {
            if !condition { failures.append("line \(line): \(label)") }
        }

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

        // MARK: Window titles

        for (minutes, title) in [(300, "5 小时"), (299, "5 小时"), (10_080, "每周"), (10_079, "每周"), (1_440, "每天"),
                                 (43_200, "每月"), (40_320, "每月"), (60, "1 小时"), (180, "3 小时"), (90, "90 分钟"),
                                 (2_880, "2 天"), (20_160, "2 周"), (0, "限额"), (-5, "限额")] {
            expect(AIUsageFormatting.windowTitle(minutes: minutes), title, "window \(minutes)")
        }
        expect(AIUsageFormatting.windowTitle(minutes: nil), "限额", "window nil")

        // MARK: Percent, ratio, tone

        expect(AIUsageFormatting.percentText(85), "85%", "whole percent")
        expect(AIUsageFormatting.percentText(23.5), "24%", "rounded percent")
        expect(AIUsageFormatting.percentText(112.4), "112%", "over-limit percent is not clamped")
        expect(AIUsageFormatting.percentText(102.5), "103%", "spend limit percent")
        expect(AIUsageFormatting.percentText(-3), "0%", "negative percent")
        expect(AIUsageFormatting.percentText(.nan), "--", "NaN percent")
        expect(AIUsageFormatting.percentText(.infinity), "--", "infinite percent")
        expect(AIUsageFormatting.ratio(112), 1.0, "bar clamps to full")
        expect(AIUsageFormatting.ratio(-4), 0.0, "bar clamps to empty")
        expect(AIUsageFormatting.ratio(42), 0.42, "bar ratio")
        expect(AIUsageFormatting.ratio(.nan), 0.0, "NaN ratio")
        expect(AIUsageFormatting.isExhausted(100), true, "100 is exhausted")
        expect(AIUsageFormatting.isExhausted(99.9), false, "99.9 is not exhausted")
        expect(AIUsageFormatting.tone(forUsage: 59.9), .blue, "tone 59.9")
        expect(AIUsageFormatting.tone(forUsage: 60), .amber, "tone 60")
        expect(AIUsageFormatting.tone(forUsage: 79.9), .amber, "tone 79.9")
        expect(AIUsageFormatting.tone(forUsage: 80), .rose, "tone 80")

        // MARK: Reset countdown and age

        func reset(_ seconds: TimeInterval) -> String { AIUsageFormatting.resetText(resetsAt: now.addingTimeInterval(seconds), now: now) }
        expect(reset(-1), "已重置", "past reset")
        expect(reset(0), "已重置", "reset now")
        expect(reset(30), "即将重置", "under a minute")
        expect(reset(61), "2 分钟后重置", "minutes round up")
        expect(reset(47 * 60), "47 分钟后重置", "minutes")
        expect(reset(2 * 3600), "2 小时后重置", "whole hours")
        expect(reset(2 * 3600 + 5 * 60), "2 小时 5 分钟后重置", "hours and minutes")
        expect(reset(3 * 86400), "3 天后重置", "whole days")
        expect(reset(3 * 86400 + 4 * 3600), "3 天 4 小时后重置", "days and hours")
        expect(reset(6 * 86400 + 23 * 3600 + 59 * 60), "6 天 23 小时后重置", "days drop minutes")

        func age(_ seconds: TimeInterval) -> String { AIUsageFormatting.ageText(since: now.addingTimeInterval(-seconds), now: now) }
        expect(age(10), "刚刚", "just now")
        expect(age(3 * 60), "3 分钟前", "minutes ago")
        expect(age(5 * 3600), "5 小时前", "hours ago")
        expect(age(8 * 86400), "8 天前", "days ago")
        expect(age(-60), "刚刚", "future clamps")
        expect(AIUsageFormatting.logStaleInterval, 86_400, "stale after a day")

        // MARK: Absolute times (time zone and 12/24-hour dependent: stable parts only)

        let resetDate = Date(timeIntervalSince1970: 1_790_064_535)
        let absolute = AIUsageFormatting.resetAbsoluteText(resetDate)
        expectTrue(absolute.hasPrefix("重置时间：9月") && absolute.contains("日 周"), "absolute reset text shape: \(absolute)")
        let updated = AIUsageFormatting.updatedAbsoluteText(now)
        let short = AIUsageFormatting.shortDateTime(now)
        expectTrue(updated == "更新于 \(short)", "updated text: \(updated)")
        expectTrue(short.hasPrefix("9月") && short.contains("日 ") && !short.contains("更新于"), "short date time: \(short)")

        // MARK: Money

        expect(AIUsageFormatting.money(dec("110.00"), currency: "CNY"), "¥110.00", "CNY")
        expect(AIUsageFormatting.money(dec("12345.6"), currency: "CNY"), "¥12,345.60", "grouping")
        expect(AIUsageFormatting.money(dec("5"), currency: "USD"), "$5.00", "USD pads decimals")
        expect(AIUsageFormatting.money(dec("1.5"), currency: "EUR"), "1.50 EUR", "other currency")
        expect(AIUsageFormatting.money(dec("1.239"), currency: "CNY"), "¥1.23", "rounds down")
        expect(AIUsageFormatting.money(dec("0.29"), currency: "CNY"), "¥0.29", "exact decimals")
        expect(AIUsageFormatting.money(dec("0"), currency: "CNY"), "¥0.00", "zero")
        expect(AIUsageFormatting.money(dec("-1"), currency: "CNY"), "-¥1.00", "negative sign before the symbol")
        expect(AIUsageFormatting.money(dec("-0.001"), currency: "CNY"), "¥0.00", "no sign on a rounded zero")
        expect(AIUsageFormatting.money(dec("1234567.891"), currency: "usd"), "$1,234,567.89", "lowercase code")
        expect(["EUR", "USD", "GBP", "CNY"].map(AIUsageFormatting.currencySortKey), [2, 1, 2, 0], "currency sort keys")

        // MARK: Limit rows

        do {
            let normal = AIUsageLimitRow(id: "r", title: "每周", usedPercent: 88, resetsAt: now.addingTimeInterval(4 * 86400), limitReached: false)
            let d = normal.display(now: now)
            expect(d.percentText, "88%", "normal percent")
            expect(d.ratio, 0.88, "normal ratio")
            expect(d.percentTone, .rose, "normal tone")
            expect(d.caption, "4 天后重置", "normal caption")
            expect(d.captionTone, .muted, "normal caption tone")
            expect(d.help, AIUsageFormatting.resetAbsoluteText(now.addingTimeInterval(4 * 86400)), "normal help")
            expect(d.accessibilityValue, "已用 88%，4 天后重置", "normal accessibility")

            let low = AIUsageLimitRow(id: "r", title: "5 小时", usedPercent: 12, resetsAt: nil, limitReached: false).display(now: now)
            expect(low.caption, "未提供重置时间", "no reset time")
            expect(low.help, nil, "no reset time help")
            expect(low.percentTone, .blue, "low tone")
            expect(low.accessibilityValue, "已用 12%，未提供重置时间", "no reset accessibility")

            let passed = AIUsageLimitRow(id: "r", title: "每周", usedPercent: 88, resetsAt: now.addingTimeInterval(-60), limitReached: true).display(now: now)
            expect(passed.percentText, "--", "reset percent")
            expect(passed.ratio, 0.0, "reset ratio")
            expect(passed.percentTone, .muted, "reset tone")
            expect(passed.caption, "已重置 · 使用后更新", "reset caption")
            expect(passed.captionTone, .muted, "reset caption tone")
            expect(passed.help, "上次记录：已用 88%\n\(AIUsageFormatting.resetAbsoluteText(now.addingTimeInterval(-60)))", "reset help")
            expect(passed.accessibilityValue, "已重置，使用后更新", "reset accessibility")

            let full = AIUsageLimitRow(id: "r", title: "5 小时", usedPercent: 100, resetsAt: now.addingTimeInterval(47 * 60), limitReached: false).display(now: now)
            expect(full.percentText, "100%", "exhausted percent")
            expect(full.ratio, 1.0, "exhausted ratio")
            expect(full.percentTone, .rose, "exhausted tone")
            expect(full.caption, "已达上限 · 47 分钟后重置", "exhausted caption")
            expect(full.captionTone, .rose, "exhausted caption tone")
            expect(full.accessibilityValue, "已用 100%，已达上限，47 分钟后重置", "exhausted accessibility")

            let reached = AIUsageLimitRow(id: "r", title: "5 小时", usedPercent: 95, resetsAt: nil, limitReached: true).display(now: now)
            expect(reached.caption, "已达上限", "limit reached without reset time")
            expect(reached.ratio, 1.0, "limit reached fills the bar")
            expect(reached.accessibilityValue, "已用 95%，已达上限", "limit reached accessibility")

            let spend = AIUsageLimitRow(id: "r", title: "支出限额", usedPercent: 102.5, resetsAt: now.addingTimeInterval(86400), limitReached: false).display(now: now)
            expect(spend.percentText, "103%", "spend over 100%")
            expect(spend.percentTone, .rose, "spend over 100% is rose")
        }

        // MARK: Codex card

        do {
            func card(_ reading: CodexUsageReading?) -> AIUsageCardModel { AIUsagePresentation.codexCard(reading: reading, now: now) }
            let loading = card(nil)
            expect(loading.title, "Codex", "codex title")
            expect(loading.icon, "terminal", "codex icon")
            expect(loading.body, .loading("正在读取 Codex 记录…"), "codex loading")
            expect(loading.trailing, .none, "codex loading trailing")
            expect(loading.isRefreshable, false, "codex is not refreshable")

            let notFound = card(CodexUsageReading(status: .codexNotFound, main: nil, additional: [], scannedFiles: 0, scannedBytes: 0))
            expect(notFound.body, .message(AIUsageMessage(icon: "questionmark.circle", title: "未检测到 Codex",
                                                         detail: "使用 Codex CLI 或 Codex App 后，这里会显示限额。", tone: .muted, action: nil)), "codex not found")
            var incomplete = CodexUsageReading.empty
            incomplete.isComplete = false
            expect(card(incomplete).body, .loading("正在读取 Codex 记录…"), "codex incomplete")
            expect(card(.empty).body, .message(AIUsageMessage(icon: "clock", title: "暂无限额数据",
                                                               detail: "最近 8 天没有 Codex 限额记录，在 Codex 中发送一条消息后显示。", tone: .muted, action: nil)), "codex no data")

            let main = CodexRateLimitSnapshot(
                limitID: "codex", limitName: nil,
                windows: [
                    CodexRateWindow(usedPercent: 85, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
                    CodexRateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
                    CodexRateWindow(usedPercent: 1, windowMinutes: 43200, resetsAt: nil),
                ],
                credits: CodexCredits(hasCredits: false, unlimited: false, balance: "0"),
                planType: "prolite", reachedType: nil, observedAt: now.addingTimeInterval(-180)
            )
            let sparkRecent = CodexRateLimitSnapshot(
                limitID: "codex_bengalfox", limitName: "GPT-5.3-Codex-Spark",
                windows: [
                    CodexRateWindow(usedPercent: 0, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
                    CodexRateWindow(usedPercent: 1, windowMinutes: 300, resetsAt: now.addingTimeInterval(600)),
                ],
                credits: nil, planType: nil, reachedType: nil, observedAt: now.addingTimeInterval(-86400)
            )
            let reading = CodexUsageReading(status: .ok, main: main, additional: [sparkRecent], scannedFiles: 1, scannedBytes: 10)
            let loaded = card(reading)
            if case .limits(let rows) = loaded.body {
                expect(rows.map(\.id), ["codex.300", "codex.10080"], "codex rows sorted by length, capped at two")
                expect(rows.map(\.title), ["5 小时", "每周"], "codex row titles")
                expect(rows.map(\.usedPercent), [12, 85], "codex row values")
                expect(rows.map(\.limitReached), [false, false], "codex limits not reached")
            } else {
                failures.append("codex limits body")
            }
            expect(loaded.trailing, .age(text: "3 分钟前", tone: .muted), "codex fresh age")
            let help = loaded.help ?? ""
            let helpLines = help.components(separatedBy: "\n")
            expect(helpLines.first, AIUsageFormatting.updatedAbsoluteText(main.observedAt), "codex help starts with the update time")
            expectTrue(helpLines.contains("套餐：Pro Lite"), "codex help plan: \(help)")
            expectTrue(helpLines.contains("GPT-5.3-Codex-Spark（独立限额）：5 小时 已用 1%，每周 已用 0%"), "codex help spark: \(help)")
            expect(helpLines.last, "只统计这台 Mac 上的 Codex 使用，其他设备的用量会在下次使用后更新。", "codex help ends with the scope note")
            expectTrue(!help.contains("credit") && !help.contains("额度"), "credits never shown")

            var old = sparkRecent
            old = CodexRateLimitSnapshot(limitID: old.limitID, limitName: old.limitName, windows: old.windows, credits: nil,
                                         planType: nil, reachedType: nil, observedAt: now.addingTimeInterval(-8 * 86400))
            var staleMain = main
            staleMain = CodexRateLimitSnapshot(limitID: "codex", limitName: nil, windows: main.windows, credits: nil,
                                               planType: nil, reachedType: "primary", observedAt: now.addingTimeInterval(-25 * 3600))
            let stale = card(CodexUsageReading(status: .ok, main: staleMain, additional: [old], scannedFiles: 1, scannedBytes: 1))
            expect(stale.trailing, .age(text: "1 天前", tone: .amber), "codex stale age turns amber")
            expectTrue(!(stale.help ?? "").contains("Spark") && !(stale.help ?? "").contains("套餐"), "old buckets and missing plans are left out")
            if case .limits(let rows) = stale.body {
                expect(rows.map(\.limitReached), [true, true], "reached type marks the rows")
            } else {
                failures.append("codex stale body")
            }
        }

        // MARK: Claude Code card

        do {
            let path = "~/.claude/settings.json"
            func card(_ status: ClaudeBridgeStatus?, _ snapshot: ClaudeUsageSnapshot? = nil, hooks: Bool = false) -> AIUsageCardModel {
                AIUsagePresentation.claudeCard(status: status, snapshot: snapshot, hooksDisabled: hooks, settingsPath: path, now: now)
            }
            func message(_ icon: String, _ title: String, _ detail: String, _ tone: AIUsageTone, _ action: AIUsageAction?) -> AIUsageCardBody {
                .message(AIUsageMessage(icon: icon, title: title, detail: detail, tone: tone, action: action))
            }
            expect(card(nil).title, "Claude Code", "claude title")
            expect(card(nil).icon, "sparkle", "claude icon")
            expect(card(nil).body, .loading("正在检查 Claude Code…"), "claude loading")
            expect(card(.claudeNotFound).body, message("questionmark.circle", "未检测到 Claude Code", "未找到 ~/.claude，使用过 Claude Code 后可在设置中连接。", .muted, nil), "claude not found")
            expect(card(.settingsUnreadable).body, message("exclamationmark.triangle.fill", "无法读取 Claude Code 设置", "~/.claude/settings.json 不是有效的 JSON。", .amber, .openSettings), "claude unreadable")
            expect(card(.notInstalled(hasStatusLine: true)).body, message("link", "未连接 Claude Code", "在设置中连接后，Claude Code 刷新状态栏时会同步限额。", .muted, .openSettings), "claude not connected")
            expect(card(.notInstalled(hasStatusLine: false)).body, card(.notInstalled(hasStatusLine: true)).body, "claude not connected without a status line")
            expect(card(.changedExternally).body, message("exclamationmark.triangle.fill", "连接已失效", "Claude Code 的状态栏设置已被更改，请在设置中重新连接。", .amber, .openSettings), "claude changed externally")
            expect(card(.recordMissing).body, message("exclamationmark.triangle.fill", "连接记录已丢失", "状态栏仍指向 Re:notch 的脚本，请在设置中查看处理方法。", .amber, .openSettings), "claude record missing")
            expect(card(.installed, hooks: true).body, message("exclamationmark.triangle.fill", "状态栏已被禁用", "settings.json 设置了 disableAllHooks，Claude Code 不会运行状态栏命令。", .amber, nil), "claude hooks disabled")
            expect(card(.installed).body, message("clock", "等待 Claude Code 数据", "已连接。在 Claude Code 中发送一条消息后显示（仅 Pro 和 Max 订阅提供限额）。", .muted, nil), "claude waiting")
            expect(card(.installed).trailing, .none, "claude waiting trailing")

            let updatedAt = now.addingTimeInterval(-120)
            let both = ClaudeUsageSnapshot(
                updatedAt: updatedAt,
                fiveHour: .init(usedPercent: 56.99999999999999, resetsAt: now.addingTimeInterval(3600)),
                sevenDay: .init(usedPercent: 23, resetsAt: now.addingTimeInterval(4 * 86400)),
                spendLimit: .init(usedPercent: 102.5, resetsAt: now.addingTimeInterval(20 * 86400))
            )
            let loaded = card(.installed, both)
            if case .limits(let rows) = loaded.body {
                expect(rows.map(\.id), ["claude.five_hour", "claude.seven_day"], "claude rows")
                expect(rows.map(\.title), ["5 小时", "每周"], "claude row titles")
                expect(rows.first?.display(now: now).percentText, "57%", "claude 57%")
                expect(rows.map(\.limitReached), [false, false], "claude never marks reached")
            } else {
                failures.append("claude limits body")
            }
            expect(loaded.trailing, .age(text: "2 分钟前", tone: .muted), "claude age")
            expect(loaded.help, "\(AIUsageFormatting.updatedAbsoluteText(updatedAt))\n来自 Claude Code 状态栏，Claude Code 每次回复后更新。", "claude help")

            let weeklyAndSpend = ClaudeUsageSnapshot(updatedAt: now.addingTimeInterval(-2 * 86400), fiveHour: nil,
                                                     sevenDay: both.sevenDay, spendLimit: both.spendLimit)
            let spendCard = card(.installed, weeklyAndSpend, hooks: true)
            if case .limits(let rows) = spendCard.body {
                expect(rows.map(\.title), ["每周", "支出限额"], "spend limit fills a free slot")
                expect(rows.last?.display(now: now).percentText, "103%", "spend 103%")
                expect(rows.last?.display(now: now).percentTone, .rose, "spend rose")
            } else {
                failures.append("claude spend body")
            }
            expect(spendCard.trailing, .age(text: "2 天前", tone: .amber), "claude stale age")
        }

        // MARK: DeepSeek card

        do {
            let fetchedAt = now.addingTimeInterval(-300)
            func balance(_ available: Bool, _ infos: [(String, String, String, String)]) -> DeepSeekBalanceMonitor.Snapshot {
                DeepSeekBalanceMonitor.Snapshot(
                    balance: DeepSeekBalance(isAvailable: available, balances: infos.map {
                        DeepSeekCurrencyBalance(currency: $0.0, total: dec($0.1), granted: dec($0.2), toppedUp: dec($0.3))
                    }),
                    fetchedAt: fetchedAt
                )
            }
            let cny = balance(true, [("CNY", "110.00", "10.00", "100.00")])
            let saved = DeepSeekBalanceMonitor.KeyState.saved(hint: "sk-…ab12")
            func card(_ key: DeepSeekBalanceMonitor.KeyState = .saved(hint: "sk-…ab12"), _ status: DeepSeekBalanceMonitor.Status,
                      _ snapshot: DeepSeekBalanceMonitor.Snapshot? = nil, refreshing: Bool = false) -> AIUsageCardModel {
                AIUsagePresentation.deepSeekCard(keyState: key, status: status, snapshot: snapshot, isRefreshing: refreshing, now: now)
            }
            func message(_ icon: String, _ title: String, _ detail: String, _ tone: AIUsageTone, _ action: AIUsageAction?) -> AIUsageCardBody {
                .message(AIUsageMessage(icon: icon, title: title, detail: detail, tone: tone, action: action))
            }
            let noKey = message("key", "未设置 API 密钥", "在设置中填写 DeepSeek API 密钥后显示余额。", .muted, .openSettings)
            expect(card(.missing, .idle).body, noKey, "missing key")
            expect(card(saved, .notConfigured, cny).body, noKey, "not configured wins over a snapshot")
            expect(card(.missing, .needsKeychainAccess).body, noKey, "missing key wins")
            let needsAccess = message("lock.shield.fill", "需要授权读取密钥", "Re:notch 重新构建后，需要你允许读取“钥匙串”中的密钥。", .amber, .authorizeKeychain)
            expect(card(saved, .needsKeychainAccess, cny).body, needsAccess, "needs Keychain access wins over a snapshot")
            expect(card(saved, .keychainError(.denied), cny).body,
                   message("exclamationmark.triangle.fill", "无法读取“钥匙串”中的密钥", "请在设置中重新保存 API 密钥。", .rose, .openSettings), "keychain error")
            expect(card(saved, .failed(.invalidKey), cny).body,
                   message("exclamationmark.triangle.fill", "API 密钥无效", "DeepSeek 拒绝了此密钥，请在设置中重新填写。", .rose, .openSettings), "invalid key")

            let loaded = card(saved, .loaded, cny)
            expect(loaded.title, "DeepSeek", "deepseek title")
            expect(loaded.icon, "yensign.circle", "deepseek icon")
            expect(loaded.isRefreshable, true, "deepseek refreshable")
            expect(loaded.trailing, .age(text: "5 分钟前", tone: .muted), "deepseek age")
            expect(loaded.help, "\(AIUsageFormatting.updatedAbsoluteText(fetchedAt))\n点按以刷新余额", "deepseek help")
            expect(loaded.body, .balance(AIUsageBalanceBody(
                isAvailable: true, totalText: "¥110.00",
                lines: [AIUsageBalanceLine(label: "充值余额", value: "¥100.00"), AIUsageBalanceLine(label: "赠金余额", value: "¥10.00")],
                emptyText: nil, accessibilityValue: "可用余额 ¥110.00"
            )), "deepseek balance body")
            expect(card(saved, .loading, cny, refreshing: true).isRefreshing, true, "refreshing passes through")
            expect(card(.unknown, .loaded, cny).body, loaded.body, "a balance shows before the key state is known")

            let failed = card(saved, .failed(.unreachable), cny)
            expect(failed.trailing, .refreshFailed(ageText: "5 分钟前"), "refresh failed trailing")
            expect(failed.help, "刷新失败：无法连接到 DeepSeek\n\(AIUsageFormatting.updatedAbsoluteText(fetchedAt))\n点按以重试", "refresh failed help")
            let dry = balance(false, [("CNY", "0.00", "0.00", "0.00")])
            expect(card(saved, .failed(.unreachable), dry).trailing, .chip(text: "余额不足", tone: .rose), "chip wins over a failure")
            expect(card(saved, .loaded, dry).trailing, .chip(text: "余额不足", tone: .rose), "insufficient balance chip")
            if case .balance(let body) = card(saved, .loaded, dry).body {
                expect(body.accessibilityValue, "可用余额 ¥0.00，余额不足", "insufficient accessibility")
                expect(body.isAvailable, false, "insufficient flag")
            } else {
                failures.append("dry body")
            }
            let multi = balance(true, [("USD", "1.50", "0.00", "1.50"), ("EUR", "2", "0", "2"), ("CNY", "23.45", "5.00", "18.45")])
            if case .balance(let body) = card(saved, .loaded, multi).body {
                expect(body.totalLabel, "可用余额", "total label")
                expect(body.totalText, "¥23.45", "CNY headline")
                expect(body.lines.map(\.label), ["充值余额", "赠金余额", "美元余额", "EUR 余额"], "balance line labels")
                expect(body.lines.map(\.value), ["¥18.45", "¥5.00", "$1.50", "2.00 EUR"], "balance line values")
            } else {
                failures.append("multi body")
            }
            let usdOnly = balance(true, [("USD", "4.87", "0.00", "4.87"), ("CNY", "1", "0", "1")])
            if case .balance(let body) = card(saved, .loaded, usdOnly).body {
                expect(body.lines.last?.label, "美元余额", "other currency label")
            }
            let usdFirst = balance(true, [("USD", "4.87", "0.00", "4.87")])
            if case .balance(let body) = card(saved, .loaded, usdFirst).body {
                expect(body.totalText, "$4.87", "USD headline")
            }
            let empty = balance(false, [])
            expect(card(saved, .loaded, empty).body, .balance(AIUsageBalanceBody(
                isAvailable: false, totalText: nil, lines: [], emptyText: "暂无余额信息", accessibilityValue: "暂无余额信息，余额不足"
            )), "empty balance infos")

            let failureCopy: [(DeepSeekBalanceFailure, String, String, String)] = [
                (.unreachable, "wifi.slash", "无法连接到 DeepSeek", "请检查网络连接，稍后会自动重试。"),
                (.timedOut, "wifi.slash", "连接 DeepSeek 超时", "稍后会自动重试。"),
                (.rateLimited, "clock", "请求过于频繁", "稍后会自动重试。"),
                (.serverUnavailable(503), "exclamationmark.triangle.fill", "DeepSeek 服务暂时不可用", "HTTP 503，稍后会自动重试。"),
                (.badStatus(418), "exclamationmark.triangle.fill", "DeepSeek 返回了意外的响应", "HTTP 418，稍后会自动重试。"),
                (.unreadableResponse, "exclamationmark.triangle.fill", "无法识别 DeepSeek 返回的数据", "稍后会自动重试。"),
                (.invalidKey, "exclamationmark.triangle.fill", "API 密钥无效", "DeepSeek 拒绝了此密钥，请在设置中重新填写。"),
            ]
            for (failure, icon, title, detail) in failureCopy {
                expect(failure.icon, icon, "\(failure) icon")
                expect(failure.title, title, "\(failure) title")
                expect(failure.detail, detail, "\(failure) detail")
                if failure != .invalidKey {
                    expect(card(saved, .failed(failure)).body, message(icon, title, detail, .amber, .retry), "\(failure) without a balance")
                }
            }
            expect(card(saved, .loading).body, .loading("正在查询余额…"), "loading")
            expect(card(.unknown, .idle).body, .loading("正在查询余额…"), "unknown key state loads")
            expect(card(saved, .loading).trailing, .none, "loading trailing")
        }

        // MARK: Settings copy

        do {
            expect(AIUsageAction.openSettings.title, "前往设置", "open settings")
            expect(AIUsageAction.retry.title, "重试", "retry")
            expect(AIUsageAction.authorizeKeychain.title, "授权", "authorize")

            let reading = CodexUsageReading.empty
            expect(AIUsagePresentation.codexSettingsRow(reading: nil, codexPath: "~/.codex"), CodexSettingsRow(subtitle: "正在读取…", badge: nil), "codex settings loading")
            expect(AIUsagePresentation.codexSettingsRow(reading: CodexUsageReading(status: .codexNotFound, main: nil, additional: [], scannedFiles: 0, scannedBytes: 0), codexPath: "~/.codex"),
                   CodexSettingsRow(subtitle: "未找到 ~/.codex/sessions。使用 Codex CLI 或 Codex App 后会自动显示。",
                                    badge: AIUsageBadge(text: "未找到", icon: "questionmark.circle", tone: .muted)), "codex settings not found")
            expect(AIUsagePresentation.codexSettingsRow(reading: reading, codexPath: "~/.codex"),
                   CodexSettingsRow(subtitle: "从 ~/.codex 读取 Codex CLI 和 Codex App 记录的限额，无需额外设置。",
                                    badge: AIUsageBadge(text: "已找到", icon: "checkmark.circle.fill", tone: .green)), "codex settings found")

            let path = "~/.claude/settings.json"
            func row(_ status: ClaudeBridgeStatus?, hooks: Bool = false) -> ClaudeSettingsRow {
                AIUsagePresentation.claudeSettingsRow(status: status, hooksDisabled: hooks, settingsPath: path)
            }
            expect(row(nil), ClaudeSettingsRow(subtitle: "正在检查…", badge: nil, primary: nil, secondary: nil, secondaryHelp: nil, extraNotes: []), "claude settings loading")
            expect(row(.claudeNotFound), ClaudeSettingsRow(subtitle: "未找到 ~/.claude。安装并运行过 Claude Code 后再连接。",
                                                          badge: AIUsageBadge(text: "未找到", icon: "questionmark.circle", tone: .muted),
                                                          primary: nil, secondary: nil, secondaryHelp: nil, extraNotes: []), "claude settings not found")
            expect(row(.settingsUnreadable), ClaudeSettingsRow(subtitle: "无法读取 ~/.claude/settings.json：文件不是有效的 JSON。修复后再连接。",
                                                              badge: AIUsageBadge(text: "无法读取", icon: "exclamationmark.triangle.fill", tone: .amber),
                                                              primary: nil, secondary: nil, secondaryHelp: nil, extraNotes: []), "claude settings unreadable")
            expect(row(.notInstalled(hasStatusLine: true)), ClaudeSettingsRow(subtitle: "通过 Claude Code 的状态栏读取 5 小时和每周限额（仅 Pro 和 Max 订阅提供）。",
                                                                             badge: nil, primary: .connect, secondary: nil, secondaryHelp: nil, extraNotes: []), "claude settings connect")
            expect(row(.notInstalled(hasStatusLine: false)).extraNotes, ["你目前没有设置状态栏，连接后 Claude Code 的状态栏会保持空白。"], "no status line note")
            expect(row(.installed), ClaudeSettingsRow(subtitle: "已连接。Claude Code 刷新状态栏时会同步限额。",
                                                     badge: AIUsageBadge(text: "已连接", icon: "checkmark.circle.fill", tone: .green),
                                                     primary: nil, secondary: .disconnect, secondaryHelp: nil, extraNotes: []), "claude settings connected")
            expect(row(.changedExternally), ClaudeSettingsRow(subtitle: "~/.claude/settings.json 中的状态栏已被其他程序修改，Re:notch 不再收到限额。",
                                                             badge: AIUsageBadge(text: "连接已失效", icon: "exclamationmark.triangle.fill", tone: .amber),
                                                             primary: .reconnect, secondary: .disconnect,
                                                             secondaryHelp: "只清理 Re:notch 的脚本和记录，不会修改 settings.json。", extraNotes: []), "claude settings broken")
            expect(row(.recordMissing), ClaudeSettingsRow(subtitle: "状态栏仍指向 Re:notch 的脚本，但连接记录已丢失，无法自动还原。请在 ~/.claude/settings.json 中手动修改 statusLine。",
                                                         badge: AIUsageBadge(text: "需要处理", icon: "exclamationmark.triangle.fill", tone: .amber),
                                                         primary: nil, secondary: nil, secondaryHelp: nil, extraNotes: []), "claude settings record missing")
            expect(row(.installed, hooks: true).extraNotes, ["settings.json 中设置了 disableAllHooks，Claude Code 不会运行状态栏命令，连接后也收不到限额。"], "hooks note")
            expect(ClaudeSettingsAction.connect.title + ClaudeSettingsAction.reconnect.title + ClaudeSettingsAction.disconnect.title, "连接重新连接断开", "action titles")
            expect(AIUsagePresentation.claudeExplanation(settingsPath: path),
                   "连接会修改 ~/.claude/settings.json 中的 statusLine：Claude Code 刷新状态栏时，Re:notch 先记下其中的 5 小时和每周限额，再把同样的数据交给你原来的状态栏命令（如 claude-hud），因此原状态栏照常显示。修改前会备份原文件，点按“断开”即可原样恢复。",
                   "claude explanation")

            let outcomes: [(ClaudeStatusLineBridge.UninstallOutcome, String)] = [
                (.restoredBackupExactly, "已断开，已恢复原状态栏"),
                (.restoredCommand, "已断开，已恢复原状态栏"),
                (.removedStatusLine, "已断开，已移除 Re:notch 添加的状态栏"),
                (.removedFile, "已断开，已移除 Re:notch 添加的状态栏"),
                (.leftAlone, "已断开，状态栏设置由其他程序管理，未做更改"),
                (.notInstalled, "未连接 Claude Code"),
            ]
            for (outcome, text) in outcomes {
                expect(AIUsagePresentation.claudeDisconnectMessage(outcome), text, "disconnect \(outcome)")
            }
            expect(AIUsagePresentation.claudeOriginalSummary(.command(decoded: "bash -c 'exec node ~/claude-hud/dist/index.js'", rawJSON: "")), "已保留并照常运行：claude-hud", "summary claude-hud")
            expect(AIUsagePresentation.claudeOriginalSummary(.command(decoded: "npx -y ccstatusline@latest", rawJSON: "")), "已保留并照常运行：ccstatusline", "summary ccstatusline")
            expect(AIUsagePresentation.claudeOriginalSummary(.command(decoded: "~/bin/status.sh", rawJSON: "")), "已保留并照常运行：自定义命令", "summary custom")
            expect(AIUsagePresentation.claudeOriginalSummary(.statusLineAbsent), "无（原来没有设置状态栏）", "summary none")
            expect(AIUsagePresentation.claudeOriginalSummary(nil), "无（原来没有设置状态栏）", "summary nil")

            let snapshot = DeepSeekBalanceMonitor.Snapshot(
                balance: DeepSeekBalance(isAvailable: true, balances: [DeepSeekCurrencyBalance(currency: "CNY", total: dec("110"), granted: dec("10"), toppedUp: dec("100"))]),
                fetchedAt: now
            )
            let drySnapshot = DeepSeekBalanceMonitor.Snapshot(balance: DeepSeekBalance(isAvailable: false, balances: []), fetchedAt: now)
            func status(_ s: DeepSeekBalanceMonitor.Status, _ snap: DeepSeekBalanceMonitor.Snapshot? = nil) -> DeepSeekSettingsStatus? {
                AIUsagePresentation.deepSeekSettingsStatus(keyState: .saved(hint: "sk-…ab12"), status: s, snapshot: snap)
            }
            expect(status(.notConfigured), nil, "settings status not configured")
            expect(status(.idle), nil, "settings status idle")
            expect(status(.loading), DeepSeekSettingsStatus("正在查询余额…", tone: .muted), "settings status loading")
            expect(status(.loaded, snapshot), DeepSeekSettingsStatus("已连接 · 可用余额 ¥110.00", tone: .green), "settings status loaded")
            expect(status(.loaded, drySnapshot), DeepSeekSettingsStatus("已连接 · 余额不足", tone: .amber), "settings status dry")
            expect(status(.failed(.invalidKey)), DeepSeekSettingsStatus("DeepSeek 拒绝了此密钥（401），请检查后重新填写。", tone: .rose), "settings status 401")
            expect(status(.failed(.unreachable)), DeepSeekSettingsStatus("暂时无法连接到 DeepSeek，密钥已保存，稍后会自动重试。", tone: .amber), "settings status offline")
            expect(status(.failed(.timedOut)), status(.failed(.unreachable)), "settings status timeout")
            expect(status(.failed(.rateLimited)), DeepSeekSettingsStatus("请求过于频繁，稍后会自动重试。", tone: .amber), "settings status 429")
            expect(status(.failed(.serverUnavailable(502))), DeepSeekSettingsStatus("DeepSeek 服务暂时不可用，稍后会自动重试。", tone: .amber), "settings status 502")
            expect(status(.needsKeychainAccess), DeepSeekSettingsStatus(
                "此版本的 Re:notch 需要你授权才能读取“钥匙串”中的密钥。", tone: .amber, offersAuthorization: true,
                footnote: "macOS 会弹出系统对话框，可能需要输入登录密码，请选择“始终允许”。重新构建 Re:notch 后需要再次授权。"
            ), "settings status needs access")
            expect(status(.keychainError(.notOwner)), DeepSeekSettingsStatus("无法清除：该密钥由其他版本的 Re:notch 保存。请在“钥匙串访问”中删除“Re:notch DeepSeek API 密钥”。", tone: .rose), "settings status not owner")
            expect(status(.keychainError(.denied)), DeepSeekSettingsStatus("已取消“钥匙串”授权。", tone: .amber), "settings status denied")
            expect(status(.keychainError(.accessRequired)), DeepSeekSettingsStatus("无法访问“钥匙串”：钥匙串可能已锁定。", tone: .rose), "settings status locked")
            expect(status(.keychainError(.unexpected(-25_299))), DeepSeekSettingsStatus("“钥匙串”错误（错误代码 -25299）。", tone: .rose), "settings status unexpected")
        }

        // MARK: Compact (collapsed notch) lines

        do {
            func codex(_ reading: CodexUsageReading?) -> AIUsageCompactLine {
                AIUsagePresentation.codexCompactLine(reading: reading, now: now)
            }
            func deepSeek(
                _ key: DeepSeekBalanceMonitor.KeyState = .saved(hint: "sk-…ab12"),
                _ status: DeepSeekBalanceMonitor.Status,
                _ snapshot: DeepSeekBalanceMonitor.Snapshot? = nil
            ) -> AIUsageCompactLine {
                AIUsagePresentation.deepSeekCompactLine(keyState: key, status: status, snapshot: snapshot, now: now)
            }

            let loading = codex(nil)
            expect(loading.title, "Codex", "compact codex title")
            expect(loading.icon, "terminal", "compact codex icon")
            expect(loading.value, "--", "compact codex loading value")
            expect(loading.caption, "读取中", "compact codex loading caption")
            expect(loading.tone, .muted, "compact codex loading tone")

            var incomplete = CodexUsageReading.empty
            incomplete.isComplete = false
            expect(codex(incomplete).caption, "读取中", "compact codex incomplete reads as loading")
            expect(codex(CodexUsageReading(status: .codexNotFound, main: nil, additional: [], scannedFiles: 0, scannedBytes: 0)).caption,
                   "未检测到", "compact codex not found")

            let main = CodexRateLimitSnapshot(
                limitID: "codex", limitName: nil,
                windows: [
                    CodexRateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600)),
                    CodexRateWindow(usedPercent: 85, windowMinutes: 10080, resetsAt: now.addingTimeInterval(86400)),
                    CodexRateWindow(usedPercent: 99, windowMinutes: 43200, resetsAt: now.addingTimeInterval(86400)),
                ],
                credits: nil, planType: "prolite", reachedType: nil, observedAt: now.addingTimeInterval(-180)
            )
            let loaded = codex(CodexUsageReading(status: .ok, main: main, additional: [], scannedFiles: 1, scannedBytes: 10))
            expect(loaded.value, "12% · 85%", "compact codex shows the two shortest windows")
            expect(loaded.caption, "5 小时 · 每周", "compact codex window labels")
            expect(loaded.tone, .rose, "compact codex tone follows the tightest window")
            expectTrue((loaded.help ?? "").contains("套餐：Pro Lite"), "compact codex help keeps the plan")

            // A window past its reset time reads as unknown, never as its stale value.
            let resetMain = CodexRateLimitSnapshot(
                limitID: "codex", limitName: nil,
                windows: [CodexRateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: now.addingTimeInterval(-60))],
                credits: nil, planType: nil, reachedType: nil, observedAt: now.addingTimeInterval(-3600)
            )
            let reset = codex(CodexUsageReading(status: .ok, main: resetMain, additional: [], scannedFiles: 1, scannedBytes: 1))
            expect(reset.value, "--", "compact codex hides a reset window")
            expect(reset.caption, "已重置", "compact codex reset caption")

            let reachedMain = CodexRateLimitSnapshot(
                limitID: "codex", limitName: nil,
                windows: [CodexRateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: now.addingTimeInterval(600))],
                credits: nil, planType: nil, reachedType: "primary", observedAt: now
            )
            let reached = codex(CodexUsageReading(status: .ok, main: reachedMain, additional: [], scannedFiles: 1, scannedBytes: 1))
            expect(reached.tone, .rose, "compact codex reached is rose even below the tone threshold")
            expectTrue((reached.help ?? "").contains("已达上限"), "compact codex reached help")

            let fetchedAt = now.addingTimeInterval(-300)
            let cny = DeepSeekBalanceMonitor.Snapshot(
                balance: DeepSeekBalance(isAvailable: true, balances: [
                    DeepSeekCurrencyBalance(currency: "CNY", total: dec("110.00"), granted: dec("10.00"), toppedUp: dec("100.00"))
                ]),
                fetchedAt: fetchedAt
            )
            let noKey = deepSeek(.missing, .idle)
            expect(noKey.value, "未设置", "compact deepseek without a key")
            expect(noKey.caption, nil, "compact deepseek without a key has no caption")
            expect(noKey.tone, .muted, "compact deepseek missing key tone")
            expect(deepSeek(.saved(hint: nil), .notConfigured, cny).value, "未设置", "compact deepseek not configured wins over a snapshot")
            expect(deepSeek(.saved(hint: nil), .needsKeychainAccess, cny).caption, "需授权", "compact deepseek needs Keychain access")
            expect(deepSeek(.saved(hint: nil), .keychainError(.denied), cny).caption, "密钥错误", "compact deepseek keychain error")
            expect(deepSeek(.saved(hint: nil), .failed(.invalidKey), cny).caption, "密钥无效", "compact deepseek invalid key")
            expect(deepSeek(.unknown, .idle).caption, "查询中", "compact deepseek loading")

            let balanceLoaded = deepSeek(.saved(hint: nil), .loaded, cny)
            expect(balanceLoaded.title, "DeepSeek", "compact deepseek title")
            expect(balanceLoaded.icon, "yensign.circle", "compact deepseek icon")
            expect(balanceLoaded.value, "¥110.00", "compact deepseek balance")
            expect(balanceLoaded.caption, "5 分钟前", "compact deepseek age")
            expect(balanceLoaded.tone, .green, "compact deepseek loaded tone")

            let dry = DeepSeekBalanceMonitor.Snapshot(
                balance: DeepSeekBalance(isAvailable: false, balances: []), fetchedAt: fetchedAt)
            let short = deepSeek(.saved(hint: nil), .loaded, dry)
            expect(short.value, "--", "compact deepseek dry balance has no total")
            expect(short.caption, "余额不足", "compact deepseek dry caption")
            expect(short.tone, .rose, "compact deepseek dry tone")

            let staleFailure = deepSeek(.saved(hint: nil), .failed(.unreachable), cny)
            expect(staleFailure.value, "¥110.00", "compact deepseek keeps the last balance through a failure")
            expect(staleFailure.caption, "5 分钟前", "compact deepseek keeps the age through a failure")
            expect(staleFailure.tone, .amber, "compact deepseek failure tone")

            let failedOnly = deepSeek(.saved(hint: nil), .failed(.unreachable))
            expect(failedOnly.value, "--", "compact deepseek without a snapshot shows no value")
            expect(failedOnly.caption, "无法连接到 DeepSeek", "compact deepseek failure title")
            expect(failedOnly.tone, .amber, "compact deepseek failure tone without a snapshot")
        }

        if failures.isEmpty {
            print("All AI usage formatting tests passed.")
        } else {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
    }
}
