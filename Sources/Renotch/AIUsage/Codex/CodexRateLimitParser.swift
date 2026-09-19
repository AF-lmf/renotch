import Darwin
import Foundation

// MARK: - Line parser

/// Parses one rollout JSONL line. Only `event_msg` / `token_count` lines carry
/// `payload.rate_limits`; everything else returns nil without being decoded.
enum CodexRateLimitLineParser {
    /// A rate_limits line is ~0.9 KB; anything much larger is conversation/tool payload.
    static let maxLineLength = 16 * 1024

    private static let rateLimitsKey = Array(#""rate_limits":"#.utf8)
    private static let tokenCountValue = Array(#""token_count""#.utf8)
    private static let timestampPrefix = Array(#"{"timestamp":""#.utf8)

    /// Cheap byte filter. The needles include the closing quote + colon, which
    /// cannot occur inside a JSON string value (there it would be `\"rate_limits\":`).
    static func mightContainRateLimits(_ line: UnsafeRawBufferPointer) -> Bool {
        guard line.count <= maxLineLength else { return false }
        return contains(line, rateLimitsKey) && contains(line, tokenCountValue)
    }

    /// The leading `{"timestamp":"2026-09-18T07:24:55.123Z"` value as raw
    /// bytes, when the line uses that canonical 24-character UTC form. Canonical
    /// timestamps order correctly as plain byte strings.
    static func canonicalTimestamp(_ line: UnsafeRawBufferPointer) -> String? {
        let p = timestampPrefix.count
        guard line.count >= p + 25 else { return nil }
        for i in 0..<p where line[i] != timestampPrefix[i] { return nil }
        guard line[p + 23] == UInt8(ascii: "Z"), line[p + 24] == UInt8(ascii: "\"") else { return nil }
        return String(decoding: UnsafeRawBufferPointer(rebasing: line[p..<(p + 24)]), as: UTF8.self)
    }

    private static let limitIDKey = Array(#""limit_id":""#.utf8)

    /// The `"limit_id":"…"` value without decoding the line, so repeated
    /// buckets inside one file are skipped cheaply.
    static func peekLimitID(_ line: UnsafeRawBufferPointer) -> String? {
        guard let base = line.baseAddress else { return nil }
        let found: UnsafeMutableRawPointer? = limitIDKey.withUnsafeBytes { n in
            memmem(base, line.count, n.baseAddress!, n.count)
        }
        guard let found else { return nil }
        let start = base.distance(to: found) + limitIDKey.count
        var end = start
        while end < line.count, end - start < 128 {
            if line[end] == UInt8(ascii: "\"") { break }
            end += 1
        }
        guard end < line.count, line[end] == UInt8(ascii: "\"") else { return nil }
        return String(decoding: UnsafeRawBufferPointer(rebasing: line[start..<end]), as: UTF8.self)
    }

    static func parse(_ data: Data) -> CodexRateLimitSnapshot? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.type == "event_msg",
              let payload = envelope.payload,
              payload.type == "token_count",
              let raw = payload.rateLimits,
              let observedAt = parseTimestamp(envelope.timestamp)
        else { return nil }

        func window(_ w: RawWindow?) -> CodexRateWindow? {
            guard let w, let used = w.usedPercent, used.isFinite,
                  let minutes = w.windowMinutes, minutes > 0 else { return nil }
            var resetsAt: Date?
            if let at = w.resetsAt, at > 0 {
                resetsAt = Date(timeIntervalSince1970: at)
            } else if let inSeconds = w.resetsInSeconds, inSeconds >= 0 {
                // Older Codex builds sent a relative countdown instead of resets_at.
                resetsAt = observedAt.addingTimeInterval(inSeconds)
            }
            return CodexRateWindow(usedPercent: min(max(used, 0), 100), windowMinutes: minutes, resetsAt: resetsAt)
        }

        let credits = raw.credits.map {
            CodexCredits(hasCredits: $0.hasCredits ?? false, unlimited: $0.unlimited ?? false, balance: $0.balance)
        }
        return CodexRateLimitSnapshot(
            limitID: raw.limitID ?? CodexRateLimitSnapshot.mainLimitID,
            limitName: raw.limitName,
            windows: [window(raw.primary), window(raw.secondary)].compactMap { $0 },
            credits: credits,
            planType: raw.planType,
            reachedType: raw.reachedType,
            observedAt: observedAt
        )
    }

    /// Fast path for Codex's fixed `YYYY-MM-DDTHH:MM:SS.sssZ`; anything else
    /// goes through ISO8601DateFormatter.
    static func parseTimestamp(_ string: String) -> Date? {
        let u = Array(string.utf8)
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r { let d = Int(u[i]) - 48; guard (0...9).contains(d) else { return nil }; v = v * 10 + d }
            return v
        }
        if u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58, u.last == 90,
           let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10),
           let h = num(11..<13), let mi = num(14..<16), let s = num(17..<19) {
            var fraction = 0.0
            if u.count > 20 {
                guard u[19] == 46, let f = num(20..<(u.count - 1)) else { return slowParse(string) }
                fraction = Double(f) / pow(10, Double(u.count - 21))
            } else if u[19] != 90 { return slowParse(string) }
            var t = tm()
            t.tm_year = Int32(y - 1900); t.tm_mon = Int32(mo - 1); t.tm_mday = Int32(d)
            t.tm_hour = Int32(h); t.tm_min = Int32(mi); t.tm_sec = Int32(s)
            let seconds = timegm(&t)
            return Date(timeIntervalSince1970: Double(seconds) + fraction)
        }
        return slowParse(string)
    }

    private static func slowParse(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    private static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { n in
            memmem(base, haystack.count, n.baseAddress!, n.count) != nil
        }
    }

    // MARK: Lenient wire model (unknown / mistyped fields decode as nil)

    private struct Envelope: Decodable {
        let timestamp: String
        let type: String
        let payload: Payload?
    }

    private struct Payload: Decodable {
        let type: String?
        let rateLimits: RawLimits?
        enum CodingKeys: String, CodingKey { case type, rateLimits = "rate_limits" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            rateLimits = try? c.decodeIfPresent(RawLimits.self, forKey: .rateLimits)
        }
    }

    private struct RawLimits: Decodable {
        let limitID: String?
        let limitName: String?
        let primary: RawWindow?
        let secondary: RawWindow?
        let credits: RawCredits?
        let planType: String?
        let reachedType: String?
        enum CodingKeys: String, CodingKey {
            case limitID = "limit_id", limitName = "limit_name", primary, secondary, credits
            case planType = "plan_type", reachedType = "rate_limit_reached_type"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            limitID = try? c.decodeIfPresent(String.self, forKey: .limitID)
            limitName = try? c.decodeIfPresent(String.self, forKey: .limitName)
            primary = try? c.decodeIfPresent(RawWindow.self, forKey: .primary)
            secondary = try? c.decodeIfPresent(RawWindow.self, forKey: .secondary)
            credits = try? c.decodeIfPresent(RawCredits.self, forKey: .credits)
            planType = try? c.decodeIfPresent(String.self, forKey: .planType)
            reachedType = try? c.decodeIfPresent(String.self, forKey: .reachedType)
        }
    }

    private struct RawWindow: Decodable {
        let usedPercent: Double?
        let windowMinutes: Int?
        let resetsAt: Double?
        let resetsInSeconds: Double?
        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent", windowMinutes = "window_minutes"
            case resetsAt = "resets_at", resetsInSeconds = "resets_in_seconds"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try? c.decodeIfPresent(Double.self, forKey: .usedPercent)
            windowMinutes = (try? c.decodeIfPresent(Int.self, forKey: .windowMinutes))
                ?? (try? c.decodeIfPresent(Double.self, forKey: .windowMinutes)).flatMap { $0.map { Int($0) } }
            resetsAt = try? c.decodeIfPresent(Double.self, forKey: .resetsAt)
            resetsInSeconds = try? c.decodeIfPresent(Double.self, forKey: .resetsInSeconds)
        }
    }

    private struct RawCredits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        let balance: String?
        enum CodingKeys: String, CodingKey { case hasCredits = "has_credits", unlimited, balance }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = try? c.decodeIfPresent(Bool.self, forKey: .hasCredits)
            unlimited = try? c.decodeIfPresent(Bool.self, forKey: .unlimited)
            balance = (try? c.decodeIfPresent(String.self, forKey: .balance))
                ?? (try? c.decodeIfPresent(Double.self, forKey: .balance)).flatMap { $0.map { String($0) } }
        }
    }
}
