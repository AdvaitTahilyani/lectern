import Foundation

/// A slide deck found in a course's slides folder.
public struct DeckCandidate: Sendable, Hashable {
    public var url: URL
    public var modifiedAt: Date

    public init(url: URL, modifiedAt: Date) {
        self.url = url
        self.modifiedAt = modifiedAt
    }

    public var fileName: String { url.lastPathComponent }
    /// Lecture numbers the file name claims ("lec2-3.pdf" → 2...3), if any.
    public var lectureNumbers: ClosedRange<Int>? { DeckSuggester.lectureNumbers(in: fileName) }
}

/// Which deck Setup should offer for the next lecture of a course.
public struct DeckSuggestion: Sendable, Hashable {
    /// The one prominent suggestion, if any deck qualifies.
    public var primary: DeckCandidate?
    /// Every other deck in the folder, in lecture order (unnumbered ones last, newest first).
    public var others: [DeckCandidate]

    public init(primary: DeckCandidate?, others: [DeckCandidate]) {
        self.primary = primary
        self.others = others
    }

    public static let none = DeckSuggestion(primary: nil, others: [])
}

/// Picks the deck for the next lecture from the files in a course's slides folder.
///
/// Ranking: the lowest-numbered deck after the highest lecture number already used by an earlier
/// session of the course (numbers come from names like `lec9…`, `lecture_10`, `L11`, `lec2-3`).
/// When no earlier session used a numbered deck, or every later number is taken, the newest
/// unused deck by modification date wins (ties go to the higher lecture number). Decks already
/// used are never the primary suggestion.
public enum DeckSuggester {
    /// File extensions Setup can open (PDF, plus PowerPoint / Keynote through the converter).
    public static let deckExtensions: Set<String> = ["pdf", "pptx", "key"]

    /// Modification times closer than this count as a tie (a folder copied or synced at once).
    static let modificationTie: TimeInterval = 60

    public static func suggest(_ candidates: [DeckCandidate], usedFileNames: Set<String>) -> DeckSuggestion {
        guard !candidates.isEmpty else { return .none }
        let used = Set(usedFileNames.map { $0.lowercased() })
        func isUsed(_ c: DeckCandidate) -> Bool { used.contains(c.fileName.lowercased()) }

        // Names, not candidates: a deck used earlier may no longer be in the folder.
        let highestUsed = usedFileNames.compactMap { lectureNumbers(in: $0)?.upperBound }.max()
        let unused = candidates.filter { !isUsed($0) }

        var primary: DeckCandidate?
        if let highestUsed {
            primary = unused
                .filter { ($0.lectureNumbers?.lowerBound ?? .min) > highestUsed }
                .min { lectureOrder($0, $1) }
        }
        if primary == nil {
            primary = unused.max { newerOrder($1, $0) }
        }
        let others = candidates.filter { $0 != primary }.sorted(by: lectureOrder)
        return DeckSuggestion(primary: primary, others: others)
    }

    /// Lists the decks directly inside `folder` (not recursive, hidden files skipped).
    public static func scan(folder: URL, extensions: Set<String> = deckExtensions) throws -> [DeckCandidate] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return urls.compactMap { url in
            guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isPackageKey])
            // Keynote documents may be packages (directories); everything else must be a file.
            guard values?.isRegularFile == true || values?.isPackage == true else { return nil }
            return DeckCandidate(url: url, modifiedAt: values?.contentModificationDate ?? .distantPast)
        }
    }

    // MARK: - Lecture numbers

    // Regex isn't Sendable, but these literals are immutable and matching doesn't mutate them.

    /// "lec", "lect", "lecture", or a lone "l", then the number, then an optional "-N" range end.
    /// The prefix must start the name or follow a non-letter, so "final3" or "html5" don't count.
    nonisolated(unsafe) private static let prefixed = /(?i)(?:^|[^a-z])(?:lecture|lect|lec|l)[\s_\-.]*0*(\d{1,3})(?:\s*[-–]\s*0*(\d{1,3}))?(?!\d)/
    /// Fallback: a leading number, e.g. "09 - Parsing.pdf" or "10_ir.pdf".
    nonisolated(unsafe) private static let leading = /^0*(\d{1,3})(?:\s*[-–]\s*0*(\d{1,3}))?(?=[\s_\-.]|$)/

    /// The lecture numbers a deck's file name claims, e.g. "lec9-ir-gen.pdf" → 9...9,
    /// "lec2-3.pdf" → 2...3, "lecture_10.key" → 10...10, "L11.pdf" → 11...11. A range end that
    /// isn't just after the start (e.g. "lec4-parser"'s absent one, or "lec9-2026") is ignored.
    public static func lectureNumbers(in fileName: String) -> ClosedRange<Int>? {
        let stem = (fileName as NSString).deletingPathExtension
        let match = stem.firstMatch(of: prefixed).map { ($0.1, $0.2) } ?? stem.firstMatch(of: leading).map { ($0.1, $0.2) }
        guard let (first, second) = match, let start = Int(first) else { return nil }
        if let second, let end = Int(second), end > start, end - start <= 5 { return start...end }
        return start...start
    }

    // MARK: - Ordering

    /// Numbered decks by lecture number (then name); unnumbered ones after them, newest first.
    private static func lectureOrder(_ a: DeckCandidate, _ b: DeckCandidate) -> Bool {
        switch (a.lectureNumbers, b.lectureNumbers) {
        case let (x?, y?):
            if x.lowerBound != y.lowerBound { return x.lowerBound < y.lowerBound }
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return a.modifiedAt > b.modifiedAt
        }
    }

    /// True when `a` should be preferred over `b` as "newest".
    private static func newerOrder(_ a: DeckCandidate, _ b: DeckCandidate) -> Bool {
        if abs(a.modifiedAt.timeIntervalSince(b.modifiedAt)) >= modificationTie { return a.modifiedAt > b.modifiedAt }
        return (a.lectureNumbers?.upperBound ?? .min) > (b.lectureNumbers?.upperBound ?? .min)
    }
}
