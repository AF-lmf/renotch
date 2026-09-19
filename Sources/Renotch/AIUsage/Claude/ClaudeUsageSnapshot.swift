import Foundation

/// What the statusLine wrapper writes to `claude-rate-limits.json`:
/// `{"schema":1,"source":"claude-code-statusline","updated_at":<epoch s>,"rate_limits":{…}}`,
/// where `rate_limits` is copied verbatim from the JSON Claude Code passes to
/// its status line (Pro and Max subscriptions only).
struct ClaudeUsageSnapshot: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        /// 0...100 for the 5-hour and weekly windows; a spend limit can exceed 100.
        var usedPercent: Double
        var resetsAt: Date
    }

    var updatedAt: Date
    var fiveHour: Window?
    var sevenDay: Window?
    var spendLimit: Window?

    /// nil for anything that is not a schema-1 snapshot with at least one usable window.
    static func decode(_ data: Data) -> ClaudeUsageSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              number(root["schema"]) == 1,
              let updated = number(root["updated_at"]), updated.isFinite, updated > 0,
              let limits = root["rate_limits"] as? [String: Any] else { return nil }

        func window(_ key: String) -> Window? {
            guard let w = limits[key] as? [String: Any],
                  let percent = number(w["used_percentage"]), percent.isFinite, percent >= 0,
                  let reset = number(w["resets_at"]), reset.isFinite, reset > 0 else { return nil }
            // resets_at is Unix epoch seconds (Claude Code rounds the header value).
            return Window(usedPercent: percent, resetsAt: Date(timeIntervalSince1970: reset))
        }

        let snapshot = ClaudeUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: updated),
            fiveHour: window("five_hour"),
            sevenDay: window("seven_day"),
            spendLimit: window("spend_limit")
        )
        return (snapshot.fiveHour ?? snapshot.sevenDay ?? snapshot.spendLimit) == nil ? nil : snapshot
    }

    /// JSON numbers only: strings and booleans (which bridge to NSNumber) are rejected.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}
