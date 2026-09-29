import Foundation
import LecternCore
import SwiftUI

/// A run of consecutive final segments shown as one transcript paragraph (≤ ~6 lines), or a
/// pause marker.
nonisolated struct TranscriptParagraph: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case speech, pause }
    var id: UUID
    var kind: Kind
    var start: TimeInterval
    var end: TimeInterval
    var segments: [TranscriptSegment]

    var text: String { segments.map(\.text).joined(separator: " ") }

    /// Segmentation rules: new paragraph after a pause > 1.5 s or once ~420 characters are reached.
    static let maxCharacters = 420
    static let breakGap: TimeInterval = 1.5
}

/// Conventions layered over `LectureSession` without changing the core contract.
nonisolated enum SessionConventions {
    /// The post-lecture summary is stored as a takeaway with a deterministic id derived from the
    /// session id, so it can be told apart from topic takeaways.
    static func summaryID(for sessionID: UUID) -> UUID {
        let hex = sessionID.uuidString.replacingOccurrences(of: "-", with: "").suffix(12)
        return UUID(uuidString: "00000000-0000-4000-8000-\(hex)") ?? UUID()
    }

    static func isSummary(_ takeaway: Takeaway, sessionID: UUID) -> Bool {
        takeaway.id == summaryID(for: sessionID)
    }

    static func summaryTitle(sessionID: UUID) -> String { "Lecture summary" }
}

/// Non-fatal, dismissible notice shown as a glass banner at the top of a column.
nonisolated struct Notice: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable { case info, warning }
    enum Placement: Hashable, Sendable { case takeaways, transcript }
    var id: String
    var kind: Kind
    var symbol: String
    var title: String
    var placement: Placement
    var actionLabel: String?
}

nonisolated enum InspectorTab: String, CaseIterable, Hashable, Sendable, Identifiable {
    case transcript, ask, quiz
    var id: String { rawValue }
    var label: String {
        switch self {
        case .transcript: "Transcript"
        case .ask: "Ask"
        case .quiz: "Quiz"
        }
    }
}

nonisolated enum SessionPane: String, CaseIterable, Hashable, Sendable, Identifiable {
    case takeaways, transcript, slides
    var id: String { rawValue }
    var label: String {
        switch self {
        case .takeaways: "Takeaways"
        case .transcript: "Transcript"
        case .slides: "Slides"
        }
    }
}

nonisolated enum LayoutTier: Hashable, Sendable {
    case three, two, single
    static func forWidth(_ w: CGFloat) -> LayoutTier {
        if w >= DS.Layout.threeColumnMin { .three } else if w >= DS.Layout.twoColumnMin { .two } else { .single }
    }

    /// Tier for a width with 20 pt of hysteresis around each threshold, so a width that hovers
    /// on a breakpoint (or moves because of the tier change itself) can never oscillate.
    static func forWidth(_ w: CGFloat, current: LayoutTier) -> LayoutTier {
        let h: CGFloat = 20
        switch current {
        case .three: return w < DS.Layout.threeColumnMin - h ? forWidth(w) : .three
        case .two:
            if w >= DS.Layout.threeColumnMin + h { return .three }
            if w < DS.Layout.twoColumnMin - h { return .single }
            return .two
        case .single: return w >= DS.Layout.twoColumnMin + h ? forWidth(w) : .single
        }
    }
}

/// Request to scroll the transcript to a time and flash the paragraph.
nonisolated struct TranscriptSeek: Hashable, Sendable {
    var time: TimeInterval
    var token = UUID()
}

/// Internal navigation URLs used by citation links (DESIGN.md §2.3).
nonisolated enum LecternURL {
    static func slide(session: UUID, page: Int) -> URL { URL(string: "lectern://session/\(session.uuidString)/slide/\(page)")! }
    static func time(session: UUID, seconds: TimeInterval) -> URL { URL(string: "lectern://session/\(session.uuidString)/t/\(Int(seconds))")! }

    enum Target: Hashable { case slide(Int), time(TimeInterval) }
    static func parse(_ url: URL) -> (session: UUID, target: Target)? {
        guard url.scheme == "lectern", url.host == "session" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 3, let id = UUID(uuidString: parts[0]) else { return nil }
        switch parts[1] {
        case "slide": return Int(parts[2]).map { (id, .slide($0)) }
        case "t": return Double(parts[2]).map { (id, .time($0)) }
        default: return nil
        }
    }
}

/// What auto-scroll needs from `ScrollGeometry`: enough to tell a user scroll (offset only)
/// from content or inset growth (which must never un-pin the list).
nonisolated struct ScrollSnapshot: Equatable, Sendable {
    var maxY: CGFloat
    var contentHeight: CGFloat
    var bottomInset: CGFloat
    var isAtBottom: Bool { maxY >= contentHeight - 40 }
}

extension ScrollSnapshot {
    @MainActor init(_ g: ScrollGeometry) {
        self.init(maxY: g.visibleRect.maxY, contentHeight: g.contentSize.height, bottomInset: g.contentInsets.bottom)
    }
}
