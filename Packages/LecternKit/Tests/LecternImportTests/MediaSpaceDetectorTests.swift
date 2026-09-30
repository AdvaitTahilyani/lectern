import Foundation
import LecternCore
import Testing
@testable import LecternImport

@Suite struct MediaSpaceDetectorTests {
    static let page = URL(string: "https://mediaspace.illinois.edu/media/t/1_oj3ppr67/414259392")!
    static let token = "djJ8MTMyOTk3MnxsZWN0ZXJuLXRlc3QtdG9rZW4tbm90LXJlYWw"

    @Test func combinesPartialSignalsIntoASource() {
        var detector = MediaSpaceDetector()
        detector.pageChanged(to: Self.page)
        #expect(detector.titleChanged("Compiler Construction - Illinois Media Space") == nil)   // nothing complete yet
        #expect(detector.ingest(.init(partnerID: "1329972")) == nil)          // no token yet
        let source = detector.ingest(.init(ks: Self.token))
        #expect(source == MediaSpaceSource(partnerID: "1329972", entryID: "1_oj3ppr67", ks: Self.token, title: "Compiler Construction", pageURL: Self.page))
        #expect(detector.ingest(.init(partnerID: "1329972", entryID: "1_oj3ppr67", ks: Self.token)) == nil)   // no change → no repeat
    }

    @Test func aLateTitleRepublishesTheSource() {
        var detector = MediaSpaceDetector()
        detector.pageChanged(to: Self.page)
        #expect(detector.ingest(.init(partnerID: "1329972", ks: Self.token))?.title == nil)
        #expect(detector.titleChanged("Lecture 5 - Illinois Media Space")?.title == "Lecture 5")
        #expect(detector.titleChanged("Lecture 5 - Illinois Media Space") == nil)
    }

    @Test func pageAddressWinsOverRelatedEntries() {
        var detector = MediaSpaceDetector()
        detector.pageChanged(to: Self.page)
        _ = detector.ingest(.init(partnerID: "1", entryID: "1_ao4hilv7"))
        let source = detector.ingest(.init(entryID: "1_oj3ppr67", ks: Self.token))
        #expect(source?.entryID == "1_oj3ppr67")
    }

    @Test func fallsBackToTheReportedEntryWithoutAnEntryAddress() {
        var detector = MediaSpaceDetector()
        detector.pageChanged(to: URL(string: "https://mediaspace.illinois.edu/kmc/x"))
        let source = detector.ingest(.init(partnerID: "9", entryID: "1_abcdefgh", ks: Self.token))
        #expect(source?.entryID == "1_abcdefgh")
    }

    @Test func navigationForgetsThePreviousLecture() {
        var detector = MediaSpaceDetector()
        detector.pageChanged(to: Self.page)
        _ = detector.ingest(.init(partnerID: "1329972", ks: Self.token))
        detector.pageChanged(to: URL(string: "https://mediaspace.illinois.edu/media/t/1_ao4hilv7/1")!)
        #expect(detector.ingest(.init(entryID: "1_ao4hilv7")) == nil)   // partner and token must be re-observed
    }

    @Test func rejectsMalformedIdentifiers() {
        var detector = MediaSpaceDetector()
        detector.pageChanged(to: Self.page)
        #expect(detector.ingest(.init(partnerID: "12<script>", ks: "short")) == nil)
        #expect(detector.ingest(.init(partnerID: "1329972", ks: "has spaces in it, definitely not a token")) == nil)
    }

    @Test func recognizesMediaPages() {
        #expect(MediaSpaceDetector.isMediaPage(Self.page))
        #expect(!MediaSpaceDetector.isMediaPage(URL(string: "https://mediaspace.illinois.edu/")))
        #expect(!MediaSpaceDetector.isMediaPage(URL(string: "https://example.com/media/t/1_oj3ppr67/1")))
        #expect(!MediaSpaceDetector.isMediaPage(nil))
    }
}
