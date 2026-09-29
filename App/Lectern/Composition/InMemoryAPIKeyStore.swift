import Foundation
import LecternCore
import os

/// Process-lifetime API key store used by the demo stack. The real store lives in the Keychain.
nonisolated final class InMemoryAPIKeyStore: APIKeyStoring {
    private let keys = OSAllocatedUnfairLock<[ProviderKind: String]>(initialState: [:])

    func apiKey(for provider: ProviderKind) throws -> String? {
        keys.withLock { $0[provider] }
    }

    func setAPIKey(_ key: String?, for provider: ProviderKind) throws {
        keys.withLock { $0[provider] = key?.isEmpty == true ? nil : key }
    }
}
