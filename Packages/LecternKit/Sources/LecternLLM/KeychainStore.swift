import Foundation
import LecternCore
import Security

/// Failure talking to the Keychain.
public enum KeychainError: Error, LocalizedError, Sendable, Hashable {
    case unexpectedStatus(OSStatus)
    case corruptItem

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
            return "Keychain error: \(text)"
        case .corruptItem:
            return "The stored API key couldn't be read."
        }
    }
}

/// Stores one API key per `ProviderKind` as a generic-password Keychain item
/// (service `com.advait.Lectern`, account = the kind's raw value). Stateless, so safe to share.
public struct KeychainStore: Sendable {
    public static let defaultService = "com.advait.Lectern"

    public let service: String

    /// `service` is overridable so tests can use an isolated namespace.
    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    /// Saves (or replaces) the key. An empty or whitespace-only key deletes the item.
    public func save(_ apiKey: String, for kind: ProviderKind) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try delete(for: kind) }
        let data = Data(trimmed.utf8)

        let update = SecItemUpdate(query(for: kind) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query(for: kind)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let add = SecItemAdd(attributes as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError.unexpectedStatus(add) }
        default:
            throw KeychainError.unexpectedStatus(update)
        }
    }

    /// The stored key, or nil when none is saved.
    public func load(for kind: ProviderKind) throws -> String? {
        var request = query(for: kind)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                throw KeychainError.corruptItem
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes the key; succeeds if there was none.
    public func delete(for kind: ProviderKind) throws {
        let status = SecItemDelete(query(for: kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func query(for kind: ProviderKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
    }
}
