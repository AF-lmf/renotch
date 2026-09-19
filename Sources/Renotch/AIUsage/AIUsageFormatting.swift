import Foundation

/// The one formatter for the AI 用量 section (Codex, Claude Code and DeepSeek
/// cards plus their Settings rows). Foundation-only so the test scripts can
/// compile it without SwiftUI; every time-dependent function takes `now`.
enum AIUsageFormatting {
    // MARK: Windows

    /// 300 → "5 小时", 1440 → "每天", 10080 → "每周", 30 days → "每月", 0 / nil → "限额".
    /// Lengths within 3 minutes of a whole hour snap to it first, so a jittery
    /// 299 reads as 5 小时 and 10079 as 每周.
    static func windowTitle(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "限额" }
        let hour = 60, day = 1_440, week = 10_080
        let nearestHours = (minutes + hour / 2) / hour
        let m = (nearestHours > 0 && abs(minutes - nearestHours * hour) <= 3) ? nearestHours * hour : minutes
        switch m {
        case 300: return "5 小时"
        case day: return "每天"
        case week: return "每周"
        case 28 * day...31 * day: return "每月"
        default: break
        }
        if m % week == 0 { return "\(m / week) 周" }
        if m % day == 0 { return "\(m / day) 天" }
        if m % hour == 0 { return "\(m / hour) 小时" }
        return "\(m) 分钟"
    }

    // MARK: Percentages

    /// Rounded and never negative, but not clamped: a spend limit above 100% reads truthfully.
    static func percentText(_ usedPercent: Double) -> String {
        guard usedPercent.isFinite else { return "--" }
        return "\(Int(max(0, usedPercent).rounded()))%"
    }

    /// Bar fill, 0...1.
    static func ratio(_ usedPercent: Double) -> Double {
        guard usedPercent.isFinite else { return 0 }
        return min(max(usedPercent / 100, 0), 1)
    }

    static func isExhausted(_ usedPercent: Double) -> Bool {
        usedPercent.isFinite && usedPercent >= 100
    }

    /// Same split as `SystemMetricTint.usage`: blue below 60%, amber below 80%, then rose.
    static func tone(forUsage usedPercent: Double) -> AIUsageTone {
        switch usedPercent {
        case ..<60: return .blue
        case ..<80: return .amber
        default: return .rose
        }
    }

    // MARK: Reset times

    /// "已重置", "即将重置", "12 分钟后重置", "2 小时 5 分钟后重置", "3 天 4 小时后重置".
    /// Minutes round up, so the countdown never promises a reset earlier than it happens.
    static func resetText(resetsAt: Date, now: Date) -> String {
        let seconds = resetsAt.timeIntervalSince(now)
        if seconds <= 0 { return "已重置" }
        if seconds < 60 { return "即将重置" }
        let totalMinutes = Int((seconds / 60).rounded(.up))
        if totalMinutes < 60 { return "\(totalMinutes) 分钟后重置" }
        let totalHours = totalMinutes / 60
        if totalHours < 24 {
            let minutes = totalMinutes % 60
            return minutes == 0 ? "\(totalHours) 小时后重置" : "\(totalHours) 小时 \(minutes) 分钟后重置"
        }
        let days = totalHours / 24
        let hours = totalHours % 24
        return hours == 0 ? "\(days) 天后重置" : "\(days) 天 \(hours) 小时后重置"
    }

    /// Tooltip and VoiceOver: "重置时间：9月22日 周二 16:08".
    static func resetAbsoluteText(_ resetsAt: Date) -> String {
        let weekday = resetsAt.formatted(.dateTime.weekday(.abbreviated).locale(AppLocale.chinese))
        return "重置时间：\(dayText(resetsAt)) \(weekday) \(timeText(resetsAt))"
    }

    /// Tooltip: "更新于 9月18日 15:30".
    static func updatedAbsoluteText(_ date: Date) -> String {
        "更新于 \(shortDateTime(date))"
    }

    /// Settings values: "9月18日 15:30".
    static func shortDateTime(_ date: Date) -> String {
        "\(dayText(date)) \(timeText(date))"
    }

    private static func dayText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).day().locale(AppLocale.chinese))
    }

    private static func timeText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: AppLocale.chineseTime))
    }

    // MARK: Freshness

    /// Card-header age: "刚刚", "3 分钟前", "2 小时前", "5 天前". Future dates read as 刚刚.
    static func ageText(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        return "\(hours / 24) 天前"
    }

    /// Log-based data (Codex, Claude Code) only changes when the tool is used, so
    /// being old is never an error; after this long the header age turns amber.
    static let logStaleInterval: TimeInterval = 86_400

    // MARK: Money

    /// "¥110.00", "$5.00", other codes as "1.50 EUR". Thousands separators and
    /// exactly two decimals, rounded toward zero so a balance is never overstated.
    static func money(_ amount: Decimal, currency: String) -> String {
        var magnitude = amount < 0 ? -amount : amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &magnitude, 2, .down)

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .down
        let number = formatter.string(from: rounded as NSDecimalNumber) ?? "\(rounded)"
        // A sign on an amount that rounds to 0.00 would read as a debt.
        let sign = amount < 0 && rounded != 0 ? "-" : ""

        switch currency.uppercased() {
        case "CNY": return sign + "¥" + number
        case "USD": return sign + "$" + number
        default: return sign + number + " " + currency
        }
    }

    /// CNY first, then USD, then anything else. Use with a stable sort so ties
    /// keep the response order.
    static func currencySortKey(_ currency: String) -> Int {
        switch currency.uppercased() {
        case "CNY": return 0
        case "USD": return 1
        default: return 2
        }
    }
}
