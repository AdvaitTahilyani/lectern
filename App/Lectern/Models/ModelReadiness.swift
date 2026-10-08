import Foundation
import LecternCore

/// The sidebar and Setup status: one verdict over every model the lecture will use (speech plus
/// the Summaries, Quizzes and Ask roles), the worst role deciding.
nonisolated enum ModelReadiness {
    /// - Parameters:
    ///   - states: On-device model states as last reported by the download manager.
    ///   - statesKnown: False until the manager has reported once; nothing is judged before that.
    ///   - keyStored: Whether a cloud provider has an API key, nil when that hasn't been looked up.
    ///   - modelName: Display name for an on-device model id.
    static func status(
        settings: AppSettings,
        states: [String: OnDeviceModelState],
        statesKnown: Bool,
        keyStored: (ProviderKind) -> Bool?,
        modelName: (String) -> String
    ) -> ModelStatus {
        var needed: [(id: String, label: String)] = []
        let speechID = settings.transcriptionEngine.rawValue
        if settings.transcriptionEngine == .parakeet { needed.append((speechID, "Parakeet")) }
        var cloud: [ProviderKind] = []
        var problems: [String] = []
        for role in LLMRole.allCases {
            let config = settings.provider(for: role)
            switch config.kind {
            case .onDevice:
                if !needed.contains(where: { $0.id == config.model }) { needed.append((config.model, modelName(config.model))) }
            case .localServer:
                break
            case .openAI, .anthropic:
                if !cloud.contains(config.kind) { cloud.append(config.kind) }
                if keyStored(config.kind) == false { problems.append("No \(config.kind.displayName) API key") }
            }
        }

        var downloading: Double?
        var unknown = false
        for model in needed {
            guard statesKnown else { unknown = true; continue }
            switch states[model.id] {
            case .installed: break
            case .downloading(let p, _), .paused(let p): downloading = min(downloading ?? 1, p)
            case .failed(let reason): problems.append(reason)
            case .notInstalled: problems.append("\(model.label) not downloaded")
            case nil: problems.append("\(model.label) status unknown")
            }
        }

        if let first = problems.first { return .unavailable(reason: first) }
        if let downloading { return .downloading(progress: downloading) }
        if unknown { return .checking }
        if !cloud.isEmpty { return .cloud(provider: cloud.map(\.displayName).joined(separator: ", ")) }
        return .ready(engine: settings.transcriptionEngine == .parakeet ? "Parakeet" : "Apple Speech")
    }
}
