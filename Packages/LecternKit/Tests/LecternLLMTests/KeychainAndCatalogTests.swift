import Foundation
import LecternCore
import Testing
@testable import LecternLLM

@Suite struct KeychainAndCatalogTests {
    @Test func keychainRoundTripReplaceAndDelete() throws {
        let store = KeychainStore(service: "com.advait.Lectern.tests.\(UUID().uuidString)")
        defer { for kind in ProviderKind.allCases { try? store.delete(for: kind) } }

        #expect(try store.load(for: .openAI) == nil)
        try store.save("sk-one", for: .openAI)
        try store.save("sk-ant", for: .anthropic)
        #expect(try store.load(for: .openAI) == "sk-one")
        #expect(try store.load(for: .anthropic) == "sk-ant")

        try store.save("  sk-two\n", for: .openAI)
        #expect(try store.load(for: .openAI) == "sk-two")

        try store.delete(for: .openAI)
        #expect(try store.load(for: .openAI) == nil)
        try store.delete(for: .openAI)  // deleting a missing key is fine
        #expect(try store.load(for: .anthropic) == "sk-ant")

        try store.save("", for: .anthropic)  // empty means delete
        #expect(try store.load(for: .anthropic) == nil)
    }

    @Test func factoryRequiresKeysForCloudProviders() throws {
        let store = KeychainStore(service: "com.advait.Lectern.tests.\(UUID().uuidString)")
        defer { for kind in ProviderKind.allCases { try? store.delete(for: kind) } }

        #expect(throws: LLMError.missingAPIKey(.openAI)) {
            try LLMProviderFactory.make(ProviderConfig(kind: .openAI, model: "gpt-6-luna"), keychain: store)
        }
        try store.save("sk-ant", for: .anthropic)
        let anthropic = try LLMProviderFactory.make(ProviderConfig(kind: .anthropic, model: "claude-haiku-4-5"), keychain: store)
        #expect(anthropic.kind == .anthropic)
        let local = try LLMProviderFactory.make(ProviderConfig(kind: .localServer, model: "gemma4:12b"), keychain: store)
        #expect(local.kind == .localServer)
        #expect(throws: LLMError.self) {
            try LLMProviderFactory.make(ProviderConfig(kind: .onDevice, model: "x"), keychain: store)
        }
    }

    @Test func everyKindHasSuggestionsWithUniqueIDs() {
        for kind in ProviderKind.allCases {
            let models = ProviderCatalog.suggestedModels(for: kind)
            #expect(!models.isEmpty)
            #expect(Set(models.map(\.id)).count == models.count)
            #expect(ProviderCatalog.defaultModel(for: kind) == models[0].id)
        }
        #expect(ProviderCatalog.defaultModel(for: .anthropic) == "claude-haiku-4-5")
        #expect(ProviderCatalog.defaultModel(for: .onDevice) == AppSettings.defaultOnDeviceModel)
    }

    @Test func pricesAreFormatted() throws {
        let luna = try #require(ProviderCatalog.suggestedModels(for: .openAI).first { $0.id == "gpt-6-luna" })
        #expect(luna.priceDescription == "$0.10 in / $0.50 out per 1M tokens")
        #expect(ProviderCatalog.suggestedModels(for: .localServer)[0].priceDescription == nil)
    }
}
