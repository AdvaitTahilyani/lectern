import Foundation
import Testing
@testable import LecternCore

/// Fields added after release must never cost a saved course, segment or settings blob.
@Suite struct TolerantDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func courseWithoutOrWithABadSlidesFolderStillLoads() throws {
        let id = UUID()
        let old = try decode(Course.self, #"{"id":"\#(id)","code":"CS 426","name":"Compilers","createdAt":0}"#)
        #expect(old.slidesFolder == nil && old.code == "CS 426")
        let bad = try decode(Course.self, #"{"id":"\#(id)","code":"CS 426","name":"Compilers","createdAt":0,"slidesFolder":42}"#)
        #expect(bad.slidesFolder == nil)

        let course = Course(code: "CS 426", name: "Compilers", slidesFolder: URL(filePath: "/Users/me/Documents/CS 426 Lecture Slides"))
        let again = try JSONDecoder().decode(Course.self, from: JSONEncoder().encode(course))
        #expect(again == course)
    }

    @Test func segmentOriginalTextIsOptionalAndTolerant() throws {
        let id = UUID()
        let old = try decode(TranscriptSegment.self, #"{"id":"\#(id)","text":"hi","start":1,"end":2,"isFinal":true}"#)
        #expect(old.originalText == nil && old.speaker == nil)
        let bad = try decode(TranscriptSegment.self, #"{"id":"\#(id)","text":"hi","start":1,"end":2,"isFinal":true,"originalText":[1]}"#)
        #expect(bad.originalText == nil)
        let fixed = TranscriptSegment(text: "genExpr", start: 0, end: 1, isFinal: true, speaker: .lecturer, originalText: "gen expression")
        #expect(try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(fixed)) == fixed)
    }

    @Test func settingsFromAnOlderBuildGetTheNewDefaults() throws {
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings(hasCompletedOnboarding: true))) as! [String: Any]
        legacy.removeValue(forKey: "fixesJargonFromSlides")
        legacy.removeValue(forKey: "monthlyCloudCapUSD")
        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(settings.hasCompletedOnboarding)
        #expect(settings.fixesJargonFromSlides)
        #expect(settings.monthlyCloudCapUSD == nil)

        legacy["fixesJargonFromSlides"] = "yes"   // unreadable → default, not a failed decode
        legacy["monthlyCloudCapUSD"] = 12.5
        let odd = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(odd.fixesJargonFromSlides && odd.monthlyCloudCapUSD == 12.5)
    }

    @Test func usageCacheFieldsAreOptional() throws {
        let old = try decode(LLMUsage.self, #"{"inputTokens":10,"outputTokens":2}"#)
        #expect(old.cachedInputTokens == nil && old.cacheWriteTokens == nil)
    }
}

@Suite struct TranscriptEditTests {
    @Test func findsTheChangedWordRuns() {
        let edits = TranscriptEdit.edits(from: "so gen expression calls new reg name, then L are", to: "so genExpr calls new_reg_name, then LR")
        #expect(edits.map(\.original) == ["gen expression", "new reg name,", "L are"])
        #expect(edits.map(\.corrected) == ["genExpr", "new_reg_name,", "LR"])
        let text = "so genExpr calls new_reg_name, then LR"
        #expect(edits.map { String(text[$0.range]) } == ["genExpr", "new_reg_name,", "LR"])
    }

    @Test func noOriginalMeansNoEdits() {
        #expect(TranscriptEdit.edits(from: nil, to: "anything").isEmpty)
        #expect(TranscriptEdit.edits(from: "same", to: "same").isEmpty)
        let segment = TranscriptSegment(text: "plain", start: 0, end: 1, isFinal: true)
        #expect(segment.corrections.isEmpty)
    }
}
