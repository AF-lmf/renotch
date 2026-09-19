import Foundation

/// One entry of `balance_infos` from `GET https://api.deepseek.com/user/balance`
/// (https://api-docs.deepseek.com/api/get-user-balance). Amounts arrive as
/// decimal strings such as "110.00".
struct DeepSeekCurrencyBalance: Equatable, Sendable {
    /// "CNY" or "USD" per the docs; any other code is kept verbatim (uppercased).
    let currency: String
    /// 总的可用余额 = granted + topped up.
    let total: Decimal
    /// 未过期的赠金余额.
    let granted: Decimal
    /// 充值余额.
    let toppedUp: Decimal
}

struct DeepSeekBalance: Equatable, Sendable {
    /// 当前账户是否有余额可供 API 调用.
    let isAvailable: Bool
    /// In response order.
    let balances: [DeepSeekCurrencyBalance]

    /// CNY, then USD, then others; ties keep the response order.
    var sortedBalances: [DeepSeekCurrencyBalance] {
        balances.enumerated()
            .sorted { lhs, rhs in
                let l = AIUsageFormatting.currencySortKey(lhs.element.currency)
                let r = AIUsageFormatting.currencySortKey(rhs.element.currency)
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// The headline figure.
    var primary: DeepSeekCurrencyBalance? { sortedBalances.first }
}

enum DeepSeekBalanceFailure: Error, Equatable, Sendable {
    /// 401: wrong, deleted or malformed key.
    case invalidKey
    /// 429.
    case rateLimited
    /// 500, 502, 503, 504.
    case serverUnavailable(Int)
    case badStatus(Int)
    /// Offline, DNS, TLS, proxy or connection errors.
    case unreachable
    case timedOut
    /// 200 with a body that is not the documented JSON (captive portal, schema change).
    case unreadableResponse
}

enum DeepSeekBalanceAPI {
    static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!
    static let apiKeysPage = URL(string: "https://platform.deepseek.com/api_keys")!
    static let topUpPage = URL(string: "https://platform.deepseek.com/top_up")!
    static let requestTimeout: TimeInterval = 15

    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The only place the key leaves the Keychain: an Authorization header sent
    /// to api.deepseek.com over HTTPS. Never log the request, its headers or the
    /// response body (a 401 body echoes the key's last four characters).
    static func makeRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // "Bearer" is case-sensitive: "bearer sk-…" is rejected with 401.
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Ephemeral: no cookies, no URL cache, no credential storage. Uses the
    /// system proxy settings like every URLSession. Created on first fetch.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout + 5
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static let liveFetch: Fetch = { request in
        try await session.data(for: request)
    }

    static func parse(data: Data, response: URLResponse) -> Result<DeepSeekBalance, DeepSeekBalanceFailure> {
        guard let http = response as? HTTPURLResponse else { return .failure(.unreadableResponse) }
        switch http.statusCode {
        case 200: break
        // An invalid key answers JSON {"error":{"type":"authentication_error",…}};
        // a missing or non-"Bearer " header answers plain text. Both are 401.
        case 401: return .failure(.invalidKey)
        case 429: return .failure(.rateLimited)
        case 500, 502, 503, 504: return .failure(.serverUnavailable(http.statusCode))
        default: return .failure(.badStatus(http.statusCode))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let isAvailable = json["is_available"] as? Bool,
              let infos = json["balance_infos"] as? [[String: Any]] else {
            return .failure(.unreadableResponse)
        }
        var balances: [DeepSeekCurrencyBalance] = []
        for info in infos {
            guard let currency = (info["currency"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !currency.isEmpty,
                  let total = amount(info["total_balance"]),
                  let granted = amount(info["granted_balance"]),
                  let toppedUp = amount(info["topped_up_balance"]) else {
                return .failure(.unreadableResponse)
            }
            balances.append(DeepSeekCurrencyBalance(currency: currency.uppercased(), total: total, granted: granted, toppedUp: toppedUp))
        }
        return .success(DeepSeekBalance(isAvailable: isAvailable, balances: balances))
    }

    static func failure(for error: Error) -> DeepSeekBalanceFailure {
        if let urlError = error as? URLError, urlError.code == .timedOut { return .timedOut }
        return .unreachable
    }

    /// Accepts the documented decimal strings, and plain JSON numbers in case the
    /// API ever switches type. Rejects partial numbers such as "12abc" and booleans.
    static func amount(_ value: Any?) -> Decimal? {
        let text: String
        switch value {
        case let string as String:
            text = string.trimmingCharacters(in: .whitespaces)
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            text = number.stringValue
        default:
            return nil
        }
        guard text.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// What Settings may show about a stored key without reading it.
enum DeepSeekKeyHint {
    /// Trims whitespace and newlines from a paste; rejects empty keys, keys
    /// longer than 256 characters and anything outside printable ASCII (a header
    /// value cannot carry it, and it is never a real key).
    static func sanitize(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.unicodeScalars.count <= 256,
              key.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
        return key
    }

    /// "sk-…ab12" (or "…ab12" without the sk- prefix): the last four characters,
    /// only for keys long enough that four characters reveal little (DeepSeek
    /// keys are "sk-" + 32 hex digits). Stored as the Keychain item's comment so
    /// Settings can show it without reading the secret.
    static func hint(for key: String) -> String? {
        guard key.count >= 12 else { return nil }
        return (key.hasPrefix("sk-") ? "sk-…" : "…") + key.suffix(4)
    }

    static func display(hint: String?) -> String {
        guard let hint, !hint.isEmpty else { return "已保存" }
        return "已保存 · " + hint
    }
}
