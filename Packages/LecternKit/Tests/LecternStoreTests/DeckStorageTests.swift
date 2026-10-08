import Foundation
import LecternCore
import Testing
@testable import LecternStore

/// A lecture with several slide decks: storage, migration from one `deck`, and what older builds see.
@Suite struct DeckStorageTests {
    let root = Fixtures.temporaryRoot()

    private func deck(_ file: String, _ name: String, pages: [String]) -> SlideDeck {
        SlideDeck(fileName: file, originalFileName: name, title: name, pages: pages.enumerated().map {
            SlidePage(number: $0.offset + 1, title: $0.element, text: "\($0.element) text")
        })
    }

    private func sessionJSON(_ id: UUID) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appending(path: "Sessions/\(id.uuidString)/session.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["session"] as? [String: Any])
    }

    @Test func severalDecksRoundTripInOrder() async throws {
        let store = FileSessionStore(root: root)
        var session = Fixtures.session()
        session.decks = [deck("slides-a.pdf", "A.pdf", pages: ["A1", "A2"]), deck("slides-b.pdf", "B.pdf", pages: ["B1"])]
        try await store.save(session)
        let loaded = try await store.loadSession(id: session.id)
        #expect(loaded.decks == session.decks)
        #expect(loaded.deck?.pages.map(\.title) == ["A1", "A2", "B1"])

        // Older builds read only `deck`: they get every page's text (and the first deck's file).
        let json = try sessionJSON(session.id)
        #expect((json["decks"] as? [Any])?.count == 2)
        let legacy = try #require(json["deck"] as? [String: Any])
        #expect(legacy["fileName"] as? String == "slides-a.pdf")
        #expect((legacy["pages"] as? [Any])?.count == 3)
    }

    @Test func oneDeckIsWrittenExactlyAsBefore() async throws {
        let store = FileSessionStore(root: root)
        var session = Fixtures.session()
        session.decks = [deck("slides.pdf", "A.pdf", pages: ["A1"])]
        try await store.save(session)
        let json = try sessionJSON(session.id)
        #expect(json["decks"] == nil)
        #expect((json["deck"] as? [String: Any])?["fileName"] as? String == "slides.pdf")
        let page = try #require(((json["deck"] as? [String: Any])?["pages"] as? [[String: Any]])?.first)
        #expect(page["sourceFile"] == nil && page["sourcePage"] == nil)
    }

    @Test func aFileWithOneDeckMigratesToDecks() async throws {
        let id = UUID()
        let file = root.appending(path: "Sessions/\(id.uuidString)/session.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"""
        {"schemaVersion":1,"session":{"id":"\#(id.uuidString)","title":"Old","createdAt":"2026-01-01T00:00:00Z",
         "duration":0,"status":"finished","transcript":[],"takeaways":[],"quiz":[],"chat":[],"vocabulary":[],
         "deck":{"fileName":"slides.pdf","originalFileName":"a.pdf","pages":[{"number":1,"text":"hi"},{"number":2,"text":"there"}]}}}
        """#.write(to: file, atomically: true, encoding: .utf8)
        let loaded = try await FileSessionStore(root: root).loadSession(id: id)
        #expect(loaded.decks.count == 1)
        #expect(loaded.decks.first?.fileName == "slides.pdf")
        #expect(loaded.deck?.pages.map(\.number) == [1, 2])
        #expect(loaded.deck?.location(ofPage: 2) == SlideLocation(fileName: "slides.pdf", page: 2))

        // The plain Codable path (used outside the store) migrates the same way.
        let data = try Data(contentsOf: file)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessionData = try JSONSerialization.data(withJSONObject: try #require(object["session"]))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(LectureSession.self, from: sessionData).decks == loaded.decks)
    }

    @Test func aDamagedDeckInDecksIsDroppedAlone() async throws {
        let id = UUID()
        let file = root.appending(path: "Sessions/\(id.uuidString)/session.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"""
        {"schemaVersion":1,"session":{"id":"\#(id.uuidString)","title":"Two","createdAt":"2026-01-01T00:00:00Z",
         "decks":[{"fileName":"slides-a.pdf","originalFileName":"a.pdf","pages":[{"number":1,"text":"a"}]},
                  {"fileName":42}],
         "deck":{"fileName":"slides-a.pdf","originalFileName":"a.pdf","pages":[]}}}
        """#.write(to: file, atomically: true, encoding: .utf8)
        let library = try await FileSessionStore(root: root).loadLibrary()
        #expect(library.sessions.first?.decks.map(\.fileName) == ["slides-a.pdf"])
        #expect(library.issues.first?.kind == .partiallyRecovered)
    }
}
