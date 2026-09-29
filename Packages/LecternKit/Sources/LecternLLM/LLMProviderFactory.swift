import Foundation
import LecternCore

/// Builds the network providers from a `ProviderConfig`, reading API keys from the Keychain.
public enum LLMProviderFactory {
    /// - Throws: `LLMError.missingAPIKey` when a cloud provider has no saved key, and
    ///   `LLMError.invalidResponse` for `.onDevice` (built by `LecternMLX`, not this module).
    public static func make(_ config: ProviderConfig, keychain: KeychainStore = KeychainStore()) throws -> any LLMProvider {
        switch config.kind {
        case .onDevice:
            throw LLMError.invalidResponse("On-device models are provided by LecternMLX.")
        case .localServer:
            return OpenAICompatibleProvider.localServer(
                baseURL: config.baseURL ?? OpenAICompatibleProvider.ollamaBaseURL,
                model: config.model
            )
        case .openAI:
            let key = try requireKey(.openAI, keychain: keychain)
            return OpenAICompatibleProvider.openAI(
                apiKey: key, model: config.model, baseURL: config.baseURL ?? OpenAICompatibleProvider.openAIBaseURL
            )
        case .anthropic:
            let key = try requireKey(.anthropic, keychain: keychain)
            return AnthropicProvider(apiKey: key, model: config.model, baseURL: config.baseURL ?? AnthropicProvider.baseURL)
        }
    }

    private static func requireKey(_ kind: ProviderKind, keychain: KeychainStore) throws -> String {
        guard let key = try keychain.load(for: kind), !key.isEmpty else { throw LLMError.missingAPIKey(kind) }
        return key
    }
}
