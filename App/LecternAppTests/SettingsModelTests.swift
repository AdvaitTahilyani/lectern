import Foundation
import LecternCore
import Synchronization
import Testing
@testable import Lectern

/// An API-key store in memory: tests never touch the real Keychain.
nonisolated private final class FakeKeyStore: APIKeyStoring, Sendable {
    private let keys = Mutex<[ProviderKind: String]>([:])
    func apiKey(for provider: ProviderKind) throws -> String? { keys.withLock { $0[provider] } }
    func setAPIKey(_ key: String?, for provider: ProviderKind) throws { keys.withLock { $0[provider] = key } }
}

/// Records every health check and answers with `reply`.
nonisolated private final class HealthProbe: Sendable {
    typealias Call = (config: ProviderConfig, key: String?)
    private let recorded = Mutex<[Call]>([])
    var calls: [Call] { recorded.withLock { $0 } }

    func check(reply: @escaping @Sendable (Int) async throws -> ProviderHealth) -> @Sendable (ProviderConfig, String?) async throws -> ProviderHealth {
        { config, key in
            let index = self.recorded.withLock { calls -> Int in calls.append((config, key)); return calls.count - 1 }
            return try await reply(index)
        }
    }
}

@MainActor
private func makeModel(keys: FakeKeyStore, health: @escaping @Sendable (ProviderConfig, String?) async throws -> ProviderHealth) -> (SettingsModel, AppModel) {
    var services = AppServices.demo
    services.keychain = keys
    services.providerHealthCheck = health
    let app = AppModel(services: services, isDemo: true)
    return (app.settingsModel, app)
}

private func settle(until condition: @MainActor () -> Bool) async {
    for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

@Suite(.serialized) @MainActor struct SettingsModelTests {
    private let ok = ProviderHealth(latencyMilliseconds: 7, detail: nil)

    // B16: the audit's fixture, then the draft states around it.

    @Test func testConnectionPreservesStoredKeyWhenDraftIsEmpty() async throws {
        let keys = FakeKeyStore()
        try keys.setAPIKey("audit-placeholder", for: .openAI)
        let probe = HealthProbe()
        let (model, _) = makeModel(keys: keys, health: probe.check { _ in ProviderHealth(latencyMilliseconds: 1, detail: "fake") })
        model.test(.openAI)
        await settle { model.testState(.openAI) != .testing }
        #expect(try keys.apiKey(for: .openAI) == "audit-placeholder")
        #expect(model.isKeyStored(.openAI))
        #expect(probe.calls.first?.key == "audit-placeholder", "the stored key is what gets tested")
        #expect(model.testState(.openAI) == .ok(latencyMs: 1, detail: "fake"))
    }

    @Test func savingAnEmptyDraftNeverDeletesTheKey_removeIsExplicit() throws {
        let keys = FakeKeyStore()
        try keys.setAPIKey("sk-stored-key", for: .anthropic)
        let (model, _) = makeModel(keys: keys, health: HealthProbe().check { _ in ProviderHealth(latencyMilliseconds: 1, detail: nil) })
        model.setKeyDraft("   ", for: .anthropic)
        model.commitKey(.anthropic)
        #expect(try keys.apiKey(for: .anthropic) == "sk-stored-key")
        #expect(model.isKeyStored(.anthropic))

        model.removeKey(.anthropic)
        #expect(try keys.apiKey(for: .anthropic) == nil)
        #expect(!model.isKeyStored(.anthropic))
    }

    @Test func aTypedKeyIsTestedButOnlySavedWhenCommitted() async throws {
        let keys = FakeKeyStore()
        try keys.setAPIKey("sk-old-key", for: .openAI)
        let probe = HealthProbe()
        let (model, _) = makeModel(keys: keys, health: probe.check { _ in ProviderHealth(latencyMilliseconds: 1, detail: nil) })
        model.setKeyDraft("  sk-new-key  ", for: .openAI)
        model.test(.openAI)
        await settle { model.testState(.openAI) != .testing }
        #expect(probe.calls.first?.key == "sk-new-key")
        #expect(try keys.apiKey(for: .openAI) == "sk-old-key", "testing never saves")

        model.commitKey(.openAI)
        #expect(try keys.apiKey(for: .openAI) == "sk-new-key")
        #expect(model.keyDraft(.openAI).isEmpty)
    }

    @Test func testingWithNoKeyFailsWithoutCallingTheProvider() {
        let probe = HealthProbe()
        let (model, _) = makeModel(keys: FakeKeyStore(), health: probe.check { _ in ProviderHealth(latencyMilliseconds: 1, detail: nil) })
        model.test(.anthropic)
        guard case .failed(let message) = model.testState(.anthropic) else { Issue.record("expected a failure"); return }
        #expect(message.contains("No API key"))
        #expect(probe.calls.isEmpty)
    }

    // B20: a test checks what's on screen and changes nothing.

    @Test func testingAPartialServerAddressIsRejectedAndNothingIsSaved() {
        let probe = HealthProbe()
        let (model, app) = makeModel(keys: FakeKeyStore(), health: probe.check { _ in ProviderHealth(latencyMilliseconds: 1, detail: nil) })
        let before = app.settings.providers
        model.localServerURL = "localhost"
        model.test(.localServer)
        guard case .failed = model.testState(.localServer) else { Issue.record("expected a failure"); return }
        #expect(probe.calls.isEmpty)
        #expect(app.settings.providers == before)
        model.commitLocalServer()
        #expect(app.settings.providers == before, "a bad address is never saved")
    }

    @Test func testingALocalServerDoesNotWriteItIntoTheRoles() async {
        let probe = HealthProbe()
        let (model, app) = makeModel(keys: FakeKeyStore(), health: probe.check { _ in ProviderHealth(latencyMilliseconds: 3, detail: nil) })
        let before = app.settings.providers
        model.localServerURL = "http://127.0.0.1:1234/v1"
        model.localServerModel = "draft-model"
        model.test(.localServer)
        await settle { model.testState(.localServer) != .testing }
        #expect(probe.calls.first?.config.baseURL == URL(string: "http://127.0.0.1:1234/v1"))
        #expect(probe.calls.first?.config.model == "draft-model")
        #expect(app.settings.providers == before)
    }

    @Test func serverURLValidation() {
        #expect(SettingsModel.serverURL(from: "http://localhost:11434/v1")?.host() == "localhost")
        #expect(SettingsModel.serverURL(from: " https://example.com ") != nil)
        for bad in ["", "localhost", "localhost:11434", "http://", "ftp://example.com", "http:///v1"] {
            #expect(SettingsModel.serverURL(from: bad) == nil, "\(bad)")
        }
    }

    @Test func aSlowEarlierTestCannotOverwriteALaterResult() async {
        let probe = HealthProbe()
        // The first answer is slow and ignores cancellation; the second is immediate.
        let (model, _) = makeModel(keys: FakeKeyStore(), health: probe.check { index in
            if index == 0 {
                let deadline = ContinuousClock.now + .milliseconds(300)
                while ContinuousClock.now < deadline { await Task.yield() }
                return ProviderHealth(latencyMilliseconds: 999, detail: "stale")
            }
            return ProviderHealth(latencyMilliseconds: 5, detail: "fresh")
        })
        model.localServerURL = "http://localhost:11434/v1"
        model.localServerModel = "m"
        model.test(.localServer)
        model.test(.localServer)
        await settle { model.testState(.localServer) == .ok(latencyMs: 5, detail: "fresh") }
        try? await Task.sleep(for: .milliseconds(500))
        #expect(model.testState(.localServer) == .ok(latencyMs: 5, detail: "fresh"))
    }

    @Test func savingAKeyDropsAPendingTestResult() async throws {
        let keys = FakeKeyStore()
        try keys.setAPIKey("sk-old-key", for: .openAI)
        let probe = HealthProbe()
        let (model, _) = makeModel(keys: keys, health: probe.check { _ in
            let deadline = ContinuousClock.now + .milliseconds(200)
            while ContinuousClock.now < deadline { await Task.yield() }
            return ProviderHealth(latencyMilliseconds: 1, detail: "old key result")
        })
        model.test(.openAI)
        #expect(model.testState(.openAI) == .testing)
        model.setKeyDraft("sk-new-key", for: .openAI)
        model.commitKey(.openAI)
        #expect(model.testState(.openAI) == .idle)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(model.testState(.openAI) == .idle, "the old key's result no longer applies")
    }

    @Test func aCloudTestChecksEverySelectedModel() async {
        let probe = HealthProbe()
        let (model, app) = makeModel(keys: FakeKeyStore(), health: probe.check { _ in ProviderHealth(latencyMilliseconds: 4, detail: nil) })
        // Settings go to the demo suite the test host runs in; restore the defaults afterwards.
        let saved = app.settings.providers
        defer { app.updateSettings { $0.providers = saved } }
        app.updateSettings { s in
            s.providers[.summaries] = ProviderConfig(kind: .openAI, model: "gpt-4.1-mini")
            s.providers[.quizzes] = ProviderConfig(kind: .openAI, model: "gpt-5-mini")
            s.providers[.ask] = ProviderConfig(kind: .openAI, model: "gpt-4.1-mini")
        }
        model.setKeyDraft("sk-typed-key", for: .openAI)
        model.test(.openAI)
        await settle { model.testState(.openAI) != .testing }
        #expect(probe.calls.map(\.config.model) == ["gpt-4.1-mini", "gpt-5-mini"])
        #expect(model.testState(.openAI) == .ok(latencyMs: 4, detail: "2 models"))
    }
}
