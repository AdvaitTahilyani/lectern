import Foundation
import LecternCore

/// App-only preferences that don't belong in `LecternCore.AppSettings`. Persisted as JSON in
/// UserDefaults by `AppModel`.
nonisolated struct UIPreferences: Codable, Sendable, Hashable {
    enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }
    enum QuizStyle: String, Codable, CaseIterable, Sendable { case card, badge }

    var appearance: Appearance = .system
    var showMenuBarWhileRecording = true
    var keepAudioRecordings = false
    var voiceIsolation = true
    var quizStyle: QuizStyle = .card
    var quizTimeToAnswer: Double = 90
    var followUpWhenWrong = true
    var showStreaks = true
    var focusPanelAllSpaces = true
    var focusPanelDimWhenIdle = true
    var announceNewTakeaways = true
    /// Seconds Lectern must be in the background before "While you were away" kicks in.
    var awayThresholdSeconds: Double = 90
    var showRecapWhenBack = true
    var collapsedCourses: Set<UUID> = []
    var hasSeenSinglePaneTip = false
    var sidebarVisible = true
    var inspectorVisible = true
    var slidesVisible = true
    /// Top-left corner of the Focus panel in screen coordinates.
    var focusPanelOrigin: CGPoint?
}

/// Sidebar/detail model status shown by `ModelStatusBadge`.
nonisolated enum ModelStatus: Sendable, Hashable {
    case ready(engine: String)
    case downloading(progress: Double)
    case cloud(provider: String)
    case unavailable(reason: String)
}
