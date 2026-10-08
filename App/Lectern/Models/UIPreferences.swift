import Foundation
import LecternCore

/// App-only preferences that don't belong in `LecternCore.AppSettings`. Persisted as JSON in
/// UserDefaults by `AppModel`.
nonisolated struct UIPreferences: Codable, Sendable, Hashable {
    enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }
    enum QuizStyle: String, Codable, CaseIterable, Sendable { case card, badge }

    var appearance: Appearance = .system
    var showMenuBarWhileRecording = true
    var quizStyle: QuizStyle = .card
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

    init() {}

    /// Missing keys keep their defaults. Synthesized decoding would throw on any key added after
    /// the preferences were saved, and `AppModel` then falls back to resetting them all.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = UIPreferences()
        appearance = value(.appearance, d.appearance)
        showMenuBarWhileRecording = value(.showMenuBarWhileRecording, d.showMenuBarWhileRecording)
        quizStyle = value(.quizStyle, d.quizStyle)
        followUpWhenWrong = value(.followUpWhenWrong, d.followUpWhenWrong)
        showStreaks = value(.showStreaks, d.showStreaks)
        focusPanelAllSpaces = value(.focusPanelAllSpaces, d.focusPanelAllSpaces)
        focusPanelDimWhenIdle = value(.focusPanelDimWhenIdle, d.focusPanelDimWhenIdle)
        announceNewTakeaways = value(.announceNewTakeaways, d.announceNewTakeaways)
        awayThresholdSeconds = value(.awayThresholdSeconds, d.awayThresholdSeconds)
        showRecapWhenBack = value(.showRecapWhenBack, d.showRecapWhenBack)
        collapsedCourses = value(.collapsedCourses, d.collapsedCourses)
        hasSeenSinglePaneTip = value(.hasSeenSinglePaneTip, d.hasSeenSinglePaneTip)
        sidebarVisible = value(.sidebarVisible, d.sidebarVisible)
        inspectorVisible = value(.inspectorVisible, d.inspectorVisible)
        slidesVisible = value(.slidesVisible, d.slidesVisible)
        focusPanelOrigin = value(.focusPanelOrigin, d.focusPanelOrigin)
    }
}

/// Sidebar/detail model status shown by `ModelStatusBadge`.
nonisolated enum ModelStatus: Sendable, Hashable {
    case ready(engine: String)
    case downloading(progress: Double)
    case cloud(provider: String)
    case unavailable(reason: String)
    /// Model state hasn't been reported yet.
    case checking
}
