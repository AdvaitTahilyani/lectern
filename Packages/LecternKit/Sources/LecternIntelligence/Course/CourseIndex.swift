import Foundation
import LecternCore

/// Retrieval across every lecture of a course: transcript windows, takeaways and slide pages share
/// one BM25 index (so scores are comparable across lectures), blended with lecture recency and
/// with explicit references in the question ("lecture 8", "last time").
struct CourseIndex: Sendable {
    enum Kind: Sendable, Hashable {
        case transcript(start: TimeInterval)
        case takeaway(start: TimeInterval, end: TimeInterval)
        case slide(page: Int)
    }

    struct Document: Sendable, Hashable {
        var lecture: Int
        var kind: Kind
        var text: String
    }

    struct Lecture: Sendable {
        var ordinal: Int
        var id: UUID
        var title: String
        var date: Date
        /// Latest transcript time, for validating [L# T…] citations.
        var duration: TimeInterval
        var pages: Set<Int>
        var outline: [String]
        var search: (any SlideSearching)?
    }

    let lectures: [Int: Lecture]
    let documents: [Document]
    private let bm25: BM25Index

    static let windowSeconds: TimeInterval = 60
    /// How much the newest lecture is favoured over the oldest at equal relevance.
    static let recencyWeight = 0.25
    static let explicitBoost = 2.5
    static let recentBoost = 1.6
    static let slideSearchBoost = 1.3

    init(lectures: [CourseLecture]) {
        var infos: [Int: Lecture] = [:]
        var documents: [Document] = []
        for lecture in lectures {
            let session = lecture.session
            let transcript = session.transcript.filter(\.isFinal)
            let outline = session.takeaways.isEmpty
                ? (session.deck?.pages.compactMap(\.title).map(Text.collapse) ?? []).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                : session.takeaways.map(\.title)
            infos[lecture.ordinal] = Lecture(
                ordinal: lecture.ordinal, id: session.id, title: session.title,
                date: session.startedAt ?? session.createdAt,
                duration: max(session.duration, transcript.last?.end ?? 0),
                pages: Set(session.deck?.pages.map(\.number) ?? []), outline: outline, search: lecture.slides)

            for window in TranscriptRetriever.windows(transcript, seconds: Self.windowSeconds) {
                documents.append(Document(lecture: lecture.ordinal, kind: .transcript(start: window.start),
                                          text: window.segments.map(TranscriptText.spoken).joined(separator: " ")))
            }
            for t in session.takeaways {
                let details = t.detail.map { " " + $0.bullets.joined(separator: " ") } ?? ""
                documents.append(Document(lecture: lecture.ordinal, kind: .takeaway(start: t.start, end: t.end), text: "\(t.title): \(t.summary)\(details)"))
            }
            for page in session.deck?.pages ?? [] {
                let notes = page.notes.map { " Notes: " + Text.collapse($0) } ?? ""
                documents.append(Document(lecture: lecture.ordinal, kind: .slide(page: page.number), text: DeckDigest.pageText(page) + notes))
            }
        }
        self.lectures = infos
        self.documents = documents
        bm25 = BM25Index(documents: documents.map { TranscriptRetriever.terms($0.text) })
    }

    var sessions: [Int: UUID] { lectures.mapValues(\.id) }

    // MARK: Prompt pieces

    /// One line per lecture ("L8 — "IR 3" (Sep 22): SSA; Phi placement; …"), for the stable prefix.
    func lectureIndex(budgetTokens: Int = TokenBudget.courseIndex) -> String {
        let ordered = lectures.values.sorted { $0.ordinal < $1.ordinal }
        guard !ordered.isEmpty else { return "(no lectures yet)" }
        let perLecture = max(80, budgetTokens * 4 / ordered.count)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return ordered.map { l in
            let outline = l.outline.isEmpty ? "" : ": " + l.outline.joined(separator: "; ")
            return Text.truncate("L\(l.ordinal) — \"\(Text.collapse(l.title))\" (\(formatter.string(from: l.date)))\(outline)", maxChars: perLecture)
        }.joined(separator: "\n")
    }

    /// Retrieved material grouped by lecture, with citation-ready markers, or nil if nothing matched.
    func material(for question: String) -> String? {
        let selected = retrieve(question)
        guard !selected.isEmpty else { return nil }
        let grouped = Dictionary(grouping: selected, by: \.lecture)
        return grouped.keys.sorted().compactMap { ordinal -> String? in
            guard let lecture = lectures[ordinal] else { return nil }
            let docs = grouped[ordinal]!.sorted(by: Self.readingOrder)
            let lines = docs.map { doc -> String in
                switch doc.kind {
                case .slide(let page): "[L\(ordinal) S\(page)] " + Text.truncate(doc.text, maxChars: SlideExcerpts.maxCharsPerSlide)
                case .transcript(let start): "[L\(ordinal) T\(TimeFormat.clock(start))] " + doc.text
                case .takeaway(let start, let end): "Topic [L\(ordinal) T\(TimeFormat.clock(start))–\(TimeFormat.clock(end))] " + doc.text
                }
            }
            return "LECTURE \(ordinal) — \"\(Text.collapse(lecture.title))\"\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Whether a citation points at something that exists.
    func isValid(_ citation: CourseCitation) -> Bool {
        guard let lecture = lectures[citation.ordinal] else { return false }
        switch citation.citation {
        case .slide(let page): return lecture.pages.contains(page)
        case .time(let t): return t <= lecture.duration + 5
        }
    }

    // MARK: Retrieval

    /// Best documents under per-kind budgets, after relevance × recency × reference boosts.
    func retrieve(_ question: String) -> [Document] {
        let boosts = lectureBoosts(for: question)
        let ordinals = lectures.keys.sorted()
        let (oldest, newest) = (Double(ordinals.first ?? 0), Double(ordinals.last ?? 0))

        var searchHits = Set<Document>()
        for lecture in lectures.values {
            for hit in lecture.search?.search(question, limit: 3) ?? [] {
                searchHits.insert(Document(lecture: lecture.ordinal, kind: .slide(page: hit.page), text: ""))
            }
        }

        var scored = bm25.search(TranscriptRetriever.terms(question)).map { hit -> (doc: Document, score: Double) in
            let doc = documents[hit.index]
            let recency = newest > oldest ? (Double(doc.lecture) - oldest) / (newest - oldest) : 1
            var score = hit.score * (1 + Self.recencyWeight * recency) * (boosts[doc.lecture] ?? 1)
            if case .slide(let page) = doc.kind, searchHits.contains(Document(lecture: doc.lecture, kind: .slide(page: page), text: "")) {
                score *= Self.slideSearchBoost
            }
            return (doc, score)
        }
        // An explicitly named lecture always contributes its topics ("what did we do in lecture 8?").
        for (ordinal, boost) in boosts where boost >= Self.explicitBoost {
            for doc in documents where doc.lecture == ordinal {
                if case .takeaway = doc.kind, !scored.contains(where: { $0.doc == doc }) { scored.append((doc, 0.01)) }
            }
        }
        scored.sort { $0.score > $1.score }

        var budgets: [String: Int] = ["transcript": TokenBudget.courseTranscript, "takeaway": TokenBudget.courseTakeaways, "slide": TokenBudget.courseSlides]
        var result: [Document] = []
        for (doc, _) in scored {
            let key = switch doc.kind { case .transcript: "transcript"; case .takeaway: "takeaway"; case .slide: "slide" }
            let cost = TokenBudget.estimate(doc.text) + 8
            guard let left = budgets[key], cost <= left else { continue }
            budgets[key] = left - cost
            result.append(doc)
        }
        return result
    }

    /// ×2.5 for lectures named in the question ("lecture 8", "L8"); ×1.6 for the most recent two
    /// when it says "last time", "last lecture", "last week", "previous lecture" or "today".
    func lectureBoosts(for question: String) -> [Int: Double] {
        var boosts: [Int: Double] = [:]
        // "lecture 8", "lec 8", "L8" (capital L only: "l1 regularization" is not a lecture).
        for match in question.matches(of: /\b(?:[Ll]ecture|[Ll]ec)\s*#?\s*(\d+)\b|\bL(\d+)\b/) {
            if let n = Int(match.1 ?? match.2 ?? ""), lectures[n] != nil { boosts[n] = Self.explicitBoost }
        }
        let ordinals = lectures.keys.sorted()
        if question.range(of: #"(?i)\b(last|previous|yesterday'?s?)\s+(time|lecture|class|week)\b|\btoday\b"#, options: .regularExpression) != nil {
            for n in ordinals.suffix(2) where boosts[n] == nil { boosts[n] = Self.recentBoost }
        }
        return boosts
    }

    private static func readingOrder(_ a: Document, _ b: Document) -> Bool {
        func rank(_ k: Kind) -> (Int, Double) {
            switch k {
            case .takeaway(let s, _): (0, s)
            case .slide(let p): (1, Double(p))
            case .transcript(let s): (2, s)
            }
        }
        return rank(a.kind) < rank(b.kind)
    }
}
