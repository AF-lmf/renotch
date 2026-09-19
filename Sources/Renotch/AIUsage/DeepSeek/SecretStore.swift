import Foundation
import Security

/// Non-secret facts about a stored key; reading them never prompts, even when
/// the Keychain is locked or this build is not on the item's access list.
struct SecretMetadata: Equatable, Sendable {
    let hint: String?
    let modifiedAt: Date?
}

enum SecretStoreError: Error, Equatable, Sendable {
    /// The item exists but this build may not read it without asking the user
    /// (ad-hoc rebuild → new cdhash) or the Keychain is locked.
    case accessRequired
    /// The user clicked 拒绝 / cancelled the system dialog.
    case denied
    /// A different build created the item and it cannot be deleted silently.
    case notOwner
    case unexpected(OSStatus)
}

/// Blocking calls: run them only inside `Task.detached`, never on the main
/// actor (an interactive read waits for the user to answer the SecurityAgent
/// dialog).
protocol SecretStore: AnyObject, Sendable {
    func metadata() throws -> SecretMetadata?
    /// nil when no item exists.
    func read(allowUI: Bool) throws -> String?
    func write(_ secret: String, hint: String?) throws
    func delete(allowUI: Bool) throws
}

/// Generic password in the file-based (login) keychain. The data protection
/// keychain needs keychain-access-groups / application-identifier entitlements
/// authorized by a provisioning profile (Apple TN3137); Re:notch is ad-hoc
/// signed, so it uses the default file-based keychain. No any-app ACL and no
/// iCloud sync: only the build that saved the key reads it silently.
final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    static let deepSeek = KeychainSecretStore(
        service: "com.vincentyosi.renotch.deepseek",
        account: "api-key",
        label: "Re:notch DeepSeek API 密钥"
    )

    let service: String
    let account: String
    let label: String
    /// nil = the user's default keychain. Only experiments pass a keychain.
    private let keychain: SecKeychain?
    /// Serializes every call: the no-UI switch below is process-wide.
    private let queue = DispatchQueue(label: "com.vincentyosi.renotch.keychain")

    init(service: String, account: String, label: String, keychain: SecKeychain? = nil) {
        self.service = service
        self.account = account
        self.label = label
        self.keychain = keychain
    }

    func metadata() throws -> SecretMetadata? {
        try queue.sync {
            var query = baseQuery()
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = Self.withoutUI { SecItemCopyMatching(query as CFDictionary, &result) }
            switch status {
            case errSecSuccess:
                let attributes = result as? [String: Any] ?? [:]
                return SecretMetadata(
                    hint: attributes[kSecAttrComment as String] as? String,
                    modifiedAt: attributes[kSecAttrModificationDate as String] as? Date
                )
            case errSecItemNotFound: return nil
            default: throw Self.error(for: status)
            }
        }
    }

    func read(allowUI: Bool) throws -> String? {
        try queue.sync {
            var query = baseQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = allowUI
                ? SecItemCopyMatching(query as CFDictionary, &result)
                : Self.withoutUI { SecItemCopyMatching(query as CFDictionary, &result) }
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
                    throw SecretStoreError.unexpected(errSecDecode)
                }
                return secret
            case errSecItemNotFound: return nil
            default: throw Self.error(for: status)
            }
        }
    }

    /// Replaces the secret. Delete + add when this build owns the item, so the
    /// new item trusts the running build; otherwise update in place (allowed
    /// for any app, but the access list keeps the old build).
    func write(_ secret: String, hint: String?) throws {
        try queue.sync {
            let data = Data(secret.utf8)
            let deleteStatus = Self.withoutUI { SecItemDelete(baseQuery() as CFDictionary) }
            switch deleteStatus {
            case errSecSuccess, errSecItemNotFound:
                var add = baseQuery(forAdd: true)
                add[kSecValueData as String] = data
                add[kSecAttrLabel as String] = label
                if let hint { add[kSecAttrComment as String] = hint }
                // Ignored by the file-based keychain; right value if this ever
                // moves to the data protection keychain.
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                let status = Self.withoutUI { SecItemAdd(add as CFDictionary, nil) }
                guard status == errSecSuccess else { throw Self.error(for: status) }
            default:
                // Another build owns the item: updating in place is still allowed.
                let deleteError = Self.error(for: deleteStatus)
                guard deleteError == .notOwner || deleteError == .accessRequired else { throw deleteError }
                var changes: [String: Any] = [kSecValueData as String: data]
                changes[kSecAttrComment as String] = hint ?? ""
                let status = Self.withoutUI { SecItemUpdate(baseQuery() as CFDictionary, changes as CFDictionary) }
                guard status == errSecSuccess else { throw Self.error(for: status) }
            }
        }
    }

    func delete(allowUI: Bool) throws {
        try queue.sync {
            let status = allowUI
                ? SecItemDelete(baseQuery() as CFDictionary)
                : Self.withoutUI { SecItemDelete(baseQuery() as CFDictionary) }
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(for: status) }
        }
    }

    private func baseQuery(forAdd: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let keychain {
            if forAdd {
                query[kSecUseKeychain as String] = keychain
            } else {
                query[kSecMatchSearchList as String] = [keychain]
            }
        }
        return query
    }

    static func error(for status: OSStatus) -> SecretStoreError {
        switch status {
        // Measured on macOS 26.6: with user interaction disabled, both an ACL
        // mismatch (rebuilt ad-hoc binary) and a locked keychain return -25293.
        case errSecAuthFailed, errSecInteractionNotAllowed: return .accessRequired
        case errSecUserCanceled: return .denied
        case errSecInvalidOwnerEdit: return .notOwner
        default: return .unexpected(status)
        }
    }

    /// kSecUseAuthenticationUIFail does NOT suppress the file-based keychain's
    /// ACL dialog (measured: SecurityAgent showed a dialog and the call blocked).
    /// The deprecated process-wide switch does, so flip it around the call.
    private static func withoutUI<T>(_ body: () -> T) -> T {
        var previous = DarwinBoolean(true)
        SecKeychainGetUserInteractionAllowed(&previous)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return body()
    }
}
