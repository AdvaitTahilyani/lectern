import Foundation
import Testing
import LecternCore
@testable import LecternStore

/// Audit B29/P11: the result limit used to be spent before the scope was applied.
@Suite struct LibrarySearchScopeTests {
    private static func needleLibrary(_ count: Int) -> [LectureSession] {
        (0..<count).map { n in
            var s = LectureSession(title: "needle \(n)", status: .finished)
            s.transcript = [TranscriptSegment(text: "needle in transcript", start: 0, end: 1, isFinal: true)]
            return s
        }
    }

    /// Ported from the audit's `titleHitsDoNotCrowdOutScopedTranscriptSearch`: 201 lectures, title and transcript both match.
    @Test func titleHitsDoNotCrowdOutTranscriptHits() {
        let hits = LibrarySearch.search("needle", in: Self.needleLibrary(201))
        #expect(hits.count == 200)
        #expect(hits.filter { $0.kind == .transcript }.count > 0)
        #expect(hits.filter { $0.kind == .title }.count > 0)
        // Still ordered titles first.
        #expect(hits.map(\.kind) == hits.map(\.kind).sorted { $0.rawValue == "title" && $1.rawValue != "title" })
    }

    @Test func transcriptScopeReturnsTranscriptHitsUpToTheFullLimit() {
        let hits = LibrarySearch.search("needle", in: Self.needleLibrary(201), kinds: [.transcript])
        #expect(hits.count == 200)
        #expect(hits.allSatisfy { $0.kind == .transcript })
    }

    @Test func titleScopeIgnoresTranscriptMatches() {
        let hits = LibrarySearch.search("needle", in: Self.needleLibrary(5), kinds: [.title])
        #expect(hits.count == 5)
        #expect(hits.allSatisfy { $0.kind == .title })
        #expect(LibrarySearch.search("needle", in: Self.needleLibrary(5), kinds: []).isEmpty)
    }

    @Test func limitIsSharedBetweenKindsWithSurplusGoingToTheOthers() {
        #expect(LibrarySearch.allocate([201, 0, 0, 201], limit: 200) == [100, 0, 0, 100])
        #expect(LibrarySearch.allocate([1, 0, 0, 20], limit: 3) == [1, 0, 0, 2])
        #expect(LibrarySearch.allocate([5, 5, 0, 5], limit: 1) == [1, 0, 0, 0])
        #expect(LibrarySearch.allocate([2, 300], limit: 200) == [2, 198])
        #expect(LibrarySearch.allocate([0, 0], limit: 10) == [0, 0])
        #expect(LibrarySearch.allocate([3, 3], limit: 100) == [3, 3])
    }

    @Test func aCancelledSearchStopsEarly() async {
        let library = Self.needleLibrary(50)
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return LibrarySearch.search("needle", in: library)
        }.value
        #expect(result.isEmpty)
    }
}
