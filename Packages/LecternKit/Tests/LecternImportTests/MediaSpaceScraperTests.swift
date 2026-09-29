import Foundation
import LecternCore
import Testing
@testable import LecternImport

@Suite struct MediaSpaceScraperTests {
    @Test(.enabled(if: TestData.exists(TestData.savedPage)))
    func realSavedPageYieldsThePagesOwnEntry() throws {
        let html = try String(contentsOf: TestData.savedPage, encoding: .utf8)
        let source = try MediaSpaceScraper.scrape(html: html)
        #expect(source.partnerID == "1329972")
        // The page also embeds a related-media entry (1_ao4hilv7); it must not be picked.
        #expect(source.entryID == "1_oj3ppr67")
        #expect(source.title == "Compiler Construction (CS 426 NG) (CS 426 NU) Fall 2026")
        // The playback session, not the in-app-messaging one.
        #expect(source.ks.hasPrefix("djJ8MTMyOTk3MnzQEUhC3w1VE1rITKH_"))
        #expect(!source.ks.isEmpty)
    }

    @Test(.enabled(if: TestData.exists(TestData.savedPage)))
    func realSavedPageWithPageURLHint() throws {
        let html = try String(contentsOf: TestData.savedPage, encoding: .utf8)
        let url = URL(string: "https://mediaspace.illinois.edu/media/t/1_oj3ppr67/414259392")!
        let source = try MediaSpaceScraper.scrape(html: html, pageURL: url)
        #expect(source.entryID == "1_oj3ppr67")
        #expect(source.pageURL == url)
    }

    @Test func prefersTheEntryPageTypeOverMoreFrequentRelatedEntries() throws {
        let html = """
        <html><head><title>Lecture 4 - Parsing - Illinois Media Space</title></head><body>
        <script>var c = {"partnerId":"123","related":[{"entryId":"1_aaaaaaaa"},{"entryId":"1_aaaaaaaa"},{"entryId":"1_aaaaaaaa"}],
        "pageType":"Entry View - VOD","entryId":"1_bbbbbbbb"}</script>
        <script>{"provider":{"partnerId":"123","uiConfId":"9","env":{"a":{"b":1}},"ks":"djJ8AAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}</script>
        </body></html>
        """
        let source = try MediaSpaceScraper.scrape(html: html)
        #expect(source.entryID == "1_bbbbbbbb")
        #expect(source.partnerID == "123")
        #expect(source.title == "Lecture 4 - Parsing")
        #expect(source.ks == "djJ8AAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    }

    @Test func playManifestTokenForTheEntryWinsAndEscapedSlashesAreUnderstood() throws {
        let html = #"""
        <title>Demo - Illinois Media Space</title>
        {"partnerId":"55","entryId":"1_zzzzzzzz","provider":{"partnerId":"55","ks":"djJ8PROVIDERPROVIDERPROVIDER"}}
        https:\/\/www.kaltura.com\/p\/55\/sp\/5500\/playManifest\/entryId\/1_yyyyyyyy\/protocol\/https\/format\/applehttp\/ks\/djJ8OTHERENTRYOTHERENTRY\/a.m3u8
        https:\/\/www.kaltura.com\/p\/55\/sp\/5500\/playManifest\/entryId\/1_zzzzzzzz\/protocol\/https\/format\/applehttp\/flavorIds\/1_a,1_b\/ks\/djJ8MANIFESTMANIFESTMANIFEST\/a.m3u8?x=1
        """#
        let source = try MediaSpaceScraper.scrape(html: html)
        #expect(source.entryID == "1_zzzzzzzz")
        #expect(source.ks == "djJ8MANIFESTMANIFESTMANIFEST")
    }

    @Test func entryIDFromPageURLBeatsPageContents() throws {
        let html = #"<title>T</title>{"partnerId":"7","entryId":"1_11111111"}"#
        let url = URL(string: "https://mediaspace.illinois.edu/media/Some+Title/1_22222222")!
        #expect(try MediaSpaceScraper.scrape(html: html, pageURL: url).entryID == "1_22222222")
    }

    @Test func pagesWithoutKalturaDataAreRejected() {
        #expect(throws: ImportError.notAMediaSpacePage) { try MediaSpaceScraper.scrape(html: "<html><title>Sign in</title></html>") }
    }

    @Test func titleCleaning() {
        #expect(MediaSpaceScraper.cleanTitle("CS 421 &amp; friends - Illinois Media Space") == "CS 421 & friends")
        #expect(MediaSpaceScraper.cleanTitle("Plain title") == "Plain title")
        #expect(MediaSpaceScraper.cleanTitle(" - Illinois Media Space") == nil)
    }

    @Test func entryIDInURLs() {
        #expect(MediaSpaceScraper.entryID(in: URL(string: "https://mediaspace.illinois.edu/media/t/1_oj3ppr67/414259392")!) == "1_oj3ppr67")
        #expect(MediaSpaceScraper.entryID(in: URL(string: "https://mediaspace.illinois.edu/media/x?entry_id=1_abcdefgh")!) == "1_abcdefgh")
        #expect(MediaSpaceScraper.entryID(in: URL(string: "https://mediaspace.illinois.edu/channel/CS+426/123")!) == nil)
    }
}
