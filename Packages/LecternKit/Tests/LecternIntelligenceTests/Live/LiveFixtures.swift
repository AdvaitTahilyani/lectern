import Foundation
import LecternCore
import PDFKit
@testable import LecternIntelligence

/// Deck loading and a keyword `SlideSearching` for live evaluation (LecternSlides isn't a
/// dependency of this test target).
enum LiveFixtures {
    static let testData = URL(fileURLWithPath: "/Users/advaittahilyani/Lectern/TestData")

    static func deck(pdf name: String) -> SlideDeck? {
        guard let document = PDFDocument(url: testData.appending(path: name)) else { return nil }
        let pages = (0..<document.pageCount).compactMap { i -> SlidePage? in
            guard let page = document.page(at: i) else { return nil }
            let text = (page.string ?? "").replacingOccurrences(of: "\u{0}", with: "")
            let title = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            return SlidePage(number: i + 1, title: title, text: text)
        }
        return SlideDeck(fileName: name, originalFileName: name, title: pages.first?.title, pages: pages)
    }

    /// "[m:ss] text" caption lines grouped into ~sentence segments of at most `maxSeconds`.
    static func captions(_ name: String, maxSeconds: TimeInterval = 14) throws -> [TranscriptSegment] {
        let text = try String(contentsOf: testData.appending(path: name), encoding: .utf8)
        let lines: [(TimeInterval, String)] = text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let m = line.firstMatch(of: /^\[([\d:]+)\]\s*(.*)$/), let t = TimeFormat.parse(String(m.1)) else { return nil }
            let body = String(m.2).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : (t, body)
        }
        var segments: [TranscriptSegment] = []
        var current: [String] = []
        var start: TimeInterval = 0
        for (i, (t, body)) in lines.enumerated() {
            if current.isEmpty { start = t }
            current.append(body)
            let next = i + 1 < lines.count ? lines[i + 1].0 : t + 4
            let endsSentence = body.hasSuffix(".") || body.hasSuffix("?")
            if next - start >= maxSeconds || (endsSentence && next - start >= 5) || next - t > 20 {
                segments.append(TranscriptSegment(text: current.joined(separator: " "), start: start, end: min(next, t + 8), isFinal: true))
                current = []
            }
        }
        return segments
    }

    /// Scripted lecture as segments: each paragraph is one segment, timed at ~2 words/s (≈120 wpm) with short pauses.
    static func scriptedSegments() -> (segments: [TranscriptSegment], speakers: [UUID: SpeakerRole]) {
        var t: TimeInterval = 5
        var segments: [TranscriptSegment] = []
        var speakers: [UUID: SpeakerRole] = [:]
        for (speaker, text) in ScriptedLecture.lines {
            let words = Double(text.split(separator: " ").count)
            let segment = TranscriptSegment(text: text, start: t, end: t + words / 2.0, isFinal: true)
            segments.append(segment)
            speakers[segment.id] = speaker == "S" ? .audience(index: 1) : .lecturer
            t += words / 2.0 + 1.5
        }
        return (segments, speakers)
    }
}

/// BM25 over slide text with a preference for pages near the current one.
struct KeywordSlides: SlideSearching {
    func backtrackCandidate(forTranscript text: String, current: Int) -> Int? { nil }
    let deck: SlideDeck
    private let index: BM25Index

    init(deck: SlideDeck) {
        self.deck = deck
        index = BM25Index(documents: deck.pages.map { TranscriptRetriever.terms(($0.title ?? "") + " " + $0.text) })
    }

    func search(_ query: String, limit: Int) -> [SlideHit] {
        index.search(TranscriptRetriever.terms(query)).prefix(limit).map {
            SlideHit(page: deck.pages[$0.index].number, score: $0.score, excerpt: String(Text.collapse(deck.pages[$0.index].text).prefix(200)))
        }
    }

    /// Forward-only: the best page among the current one and the next four, moving only on clearly
    /// better evidence.
    func likelySlide(forTranscript text: String, near: Int?) -> Int? {
        let from = near ?? 1
        let hits = index.search(TranscriptRetriever.terms(text)).filter {
            let page = deck.pages[$0.index].number
            return page >= from && page <= from + 4
        }
        guard let best = hits.max(by: { weighted($0, near) < weighted($1, near) }), best.score > 3 else { return nil }
        // Move on only with clearly better evidence than for the current page.
        let current = hits.first { deck.pages[$0.index].number == near }?.score ?? 0
        return best.score >= current * 1.5 ? deck.pages[best.index].number : near
    }

    private func weighted(_ hit: BM25Index.Hit, _ near: Int?) -> Double {
        guard let near else { return hit.score }
        let d = deck.pages[hit.index].number - near
        return hit.score * (d == 0 ? 1.3 : 1)
    }
}
