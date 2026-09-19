import Foundation

/// One Codex usage window (`rate_limits.primary` / `rate_limits.secondary`).
struct CodexRateWindow: Equatable, Sendable {
    /// Share of the window already used, 0...100 (Codex sends whole numbers as floats).
    let usedPercent: Double
    /// Window length in minutes (300 = 5 小时, 10080 = 每周). Always > 0.
    let windowMinutes: Int
    /// When Codex says the window resets; nil when it did not say.
    let resetsAt: Date?

    var label: String { AIUsageFormatting.windowTitle(minutes: windowMinutes) }

    /// `resetsAt` has passed since the snapshot was taken. The window has
    /// probably reset, but Codex has not logged a new value yet (logs show
    /// Codex itself reporting 100% for up to ~2 h past resets_at), so views
    /// never present the old value as current.
    func hasReset(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }
}

struct CodexCredits: Equatable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    /// Decimal string exactly as Codex sent it ("0", "12.50"); nil when absent.
    let balance: String?
}

/// The newest `rate_limits` object Codex logged for one limit bucket.
struct CodexRateLimitSnapshot: Equatable, Sendable {
    /// The account-wide Codex bucket. Model-specific buckets use other ids
    /// (seen so far: "codex_bengalfox" = GPT-5.3-Codex-Spark, "premium").
    static let mainLimitID = "codex"

    let limitID: String
    let limitName: String?
    /// primary first, then secondary; windows with no length are dropped.
    let windows: [CodexRateWindow]
    let credits: CodexCredits?
    let planType: String?
    /// Non-nil when Codex reports that a limit has been hit.
    let reachedType: String?
    /// The log event's own timestamp (not the file mtime).
    let observedAt: Date

    var isMain: Bool { limitID == Self.mainLimitID }

    var displayName: String {
        if let limitName, !limitName.isEmpty { return limitName }
        return isMain ? "Codex" : limitID
    }

    /// The window with the highest usage that has not passed its reset time.
    func tightestWindow(now: Date) -> CodexRateWindow? {
        windows
            .filter { !$0.hasReset(at: now) }
            .max { $0.usedPercent < $1.usedPercent }
    }

    /// Plan names as Codex sends them ("plus", "prolite", "pro", "team", ...).
    var planDisplayName: String? {
        guard let planType, !planType.isEmpty else { return nil }
        switch planType.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        case "free": return "Free"
        default: return planType
        }
    }
}

struct CodexUsageReading: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case ok
        /// <codexHome>/sessions and archived_sessions are both missing.
        case codexNotFound
        /// Logs exist but no windowed `rate_limits` was found within the scan budget.
        case noRateLimits
    }

    var status: Status
    /// Newest windowed snapshot for limit id "codex".
    var main: CodexRateLimitSnapshot?
    /// Newest windowed snapshot for every other limit id seen, newest first.
    var additional: [CodexRateLimitSnapshot]
    var scannedFiles: Int
    var scannedBytes: Int
    /// False while older log history is still being explored; the owner may
    /// read again right away (each read is byte-budgeted) instead of waiting
    /// for the next tick.
    var isComplete: Bool = true

    static let empty = CodexUsageReading(status: .noRateLimits, main: nil, additional: [], scannedFiles: 0, scannedBytes: 0)

    /// Equality of what the UI shows. The scan counters change on every read,
    /// so publishing on `==` would redraw the notch every 20 s for nothing.
    func hasSameContent(as other: CodexUsageReading) -> Bool {
        status == other.status
            && main == other.main
            && additional == other.additional
            && isComplete == other.isComplete
    }
}
