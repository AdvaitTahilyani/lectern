import Foundation
import LecternCore
import Testing
@testable import Lectern

/// B18: the Ready badge reflects every role the lecture uses, and says "checking" before it knows.
struct ModelReadinessTests {
    private let defaultModel = AppSettings.defaultOnDeviceModel
    private let other = "mlx-community/other-model"

    private func settings(summaries: ProviderConfig? = nil, quizzes: ProviderConfig? = nil, ask: ProviderConfig? = nil, engine: TranscriptionEngineID = .parakeet) -> AppSettings {
        var s = AppSettings()
        s.transcriptionEngine = engine
        for (role, config) in [(LLMRole.summaries, summaries), (.quizzes, quizzes), (.ask, ask)] {
            s.providers[role] = config ?? ProviderConfig(kind: .onDevice, model: defaultModel)
        }
        return s
    }

    private func status(_ s: AppSettings, _ states: [String: OnDeviceModelState], known: Bool = true, keys: [ProviderKind: Bool] = [:]) -> ModelStatus {
        ModelReadiness.status(settings: s, states: states, statesKnown: known, keyStored: { keys[$0] }, modelName: { $0 })
    }

    private var allInstalled: [String: OnDeviceModelState] {
        [TranscriptionEngineID.parakeet.rawValue: .installed, defaultModel: .installed]
    }

    @Test func readyWhenEverythingIsInstalled() {
        #expect(status(settings(), allInstalled) == .ready(engine: "Parakeet"))
    }

    @Test func anUndownloadedAskModelMakesItUnavailableEvenWhenSummariesAreReady() {
        let s = settings(ask: ProviderConfig(kind: .onDevice, model: other))
        #expect(status(s, allInstalled + [other: .notInstalled]) == .unavailable(reason: "\(other) not downloaded"))
    }

    @Test func aMissingStateIsUnknownNotReady() {
        let s = settings(quizzes: ProviderConfig(kind: .onDevice, model: other))
        #expect(status(s, allInstalled) == .unavailable(reason: "\(other) status unknown"))
    }

    @Test func nothingIsJudgedBeforeTheFirstReport() {
        #expect(status(settings(), [:], known: false) == .checking)
    }

    @Test func aDownloadInAnyRoleShowsTheSlowestProgress() {
        let s = settings(quizzes: ProviderConfig(kind: .onDevice, model: other))
        #expect(status(s, allInstalled + [other: .downloading(progress: 0.4, bytesPerSecond: nil)]) == .downloading(progress: 0.4))
    }

    @Test func aFailureBeatsADownload() {
        let s = settings(quizzes: ProviderConfig(kind: .onDevice, model: other))
        let states: [String: OnDeviceModelState] = [TranscriptionEngineID.parakeet.rawValue: .downloading(progress: 0.5, bytesPerSecond: nil), defaultModel: .installed, other: .failed("disk full")]
        #expect(status(s, states) == .unavailable(reason: "disk full"))
    }

    @Test func aCloudRoleWithoutAKeyIsUnavailableButAnUnknownKeyIsNot() {
        let s = settings(ask: ProviderConfig(kind: .openAI, model: "gpt-4.1-mini"))
        #expect(status(s, allInstalled, keys: [.openAI: false]) == .unavailable(reason: "No OpenAI API key"))
        #expect(status(s, allInstalled, keys: [.openAI: true]) == .cloud(provider: "OpenAI"))
        #expect(status(s, allInstalled) == .cloud(provider: "OpenAI"))
    }

    @Test func appleSpeechNeedsNoDownload() {
        #expect(status(settings(engine: .apple), [defaultModel: .installed]) == .ready(engine: "Apple Speech"))
    }
}

private func + (lhs: [String: OnDeviceModelState], rhs: [String: OnDeviceModelState]) -> [String: OnDeviceModelState] {
    lhs.merging(rhs) { _, new in new }
}
