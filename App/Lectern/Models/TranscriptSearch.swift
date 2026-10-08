import Foundation

/// In-lecture transcript search. Pure so the matching and the cache rules are testable.
nonisolated enum TranscriptSearch {
    static let minimumQueryLength = 2

    /// The query as typed, trimmed; searching starts at `minimumQueryLength` characters.
    static func normalized(_ query: String) -> String { query.trimmingCharacters(in: .whitespaces) }

    /// Ids of the speech paragraphs containing `query`, in transcript order (case-insensitive).
    static func hitIDs(in paragraphs: [TranscriptParagraph], query: String) -> [UUID] {
        let q = normalized(query)
        guard q.count >= minimumQueryLength else { return [] }
        return paragraphs.filter { $0.kind == .speech && $0.text.range(of: q, options: .caseInsensitive) != nil }.map(\.id)
    }

    /// What the view should be showing: changes whenever the query, the current hit, or which paragraph is
    /// the current hit changes, so the list scrolls to the first hit as soon as a new query has one, even
    /// though the hit index was already 0 (observing the index alone missed that).
    struct Focus: Equatable {
        var query: String
        var index: Int
        var hitID: UUID?
    }
}

/// Memoized hits for the search bar and every highlighted row, which all ask on each body pass. Keyed by the
/// query and the transcript revision (bumped by every change to the paragraphs), not by structural counts:
/// an edit that keeps the paragraph and segment counts the same, or a re-grouping by a late speaker label,
/// still invalidates it.
@MainActor
final class TranscriptHitCache {
    private var key: Key?
    private var ids: [UUID] = []
    private(set) var computations = 0

    private struct Key: Equatable { var query: String; var revision: Int }

    func hits(query: String, revision: Int, paragraphs: [TranscriptParagraph]) -> [UUID] {
        let q = TranscriptSearch.normalized(query)
        let key = Key(query: q, revision: revision)
        if self.key == key { return ids }
        computations += 1
        ids = TranscriptSearch.hitIDs(in: paragraphs, query: q)
        self.key = key
        return ids
    }
}
