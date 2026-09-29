import Foundation
import LecternCore
import Testing
import WebKit
@testable import LecternImport

@MainActor @Suite(.serialized) struct BrowserTests {
    static let token = "djJ8MTMyOTk3MnzQEUhC3w1VE1rITKH_9lJ3BiNZGW25"

    private func load(html: String, at address: String, timeout: Duration = .seconds(10)) async throws -> (MediaSpaceBrowserState, [MediaSpaceSource]) {
        let state = MediaSpaceBrowserState()
        let found = Box<[MediaSpaceSource]>([])
        let coordinator = MediaSpaceBrowserView.Coordinator(state: state, onFound: { found.value.append($0) })
        let webView = MediaSpaceBrowserView.makeWebView(coordinator: coordinator)
        webView.loadHTMLString(html, baseURL: URL(string: address))
        let deadline = ContinuousClock.now + timeout
        while state.found?.title == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        withExtendedLifetime(webView) {}
        return (state, found.value)
    }

    @Test func findsTheLectureFromThePlayerConfiguration() async throws {
        let html = """
        <html><head><title>Compiler Construction - Illinois Media Space</title></head><body><script>
        window.KalturaPlayer = { getPlayers: function () { return { p1: { config: { provider: { partnerId: 1329972, ks: '\(Self.token)' }, sources: { id: '1_oj3ppr67' } } } }; } };
        </script></body></html>
        """
        let (state, found) = try await load(html: html, at: "https://mediaspace.illinois.edu/media/t/1_oj3ppr67/414259392")
        let source = try #require(state.found)
        #expect(source.partnerID == "1329972" && source.entryID == "1_oj3ppr67" && source.ks == Self.token)
        #expect(source.title == "Compiler Construction")
        #expect(state.isOnMediaPage)
        #expect(found.last == source && found.count <= 2)   // a second callback delivers the title
    }

    @Test func findsTheLectureFromAPlayManifestRequest() async throws {
        let html = """
        <html><head><title>Lecture - Illinois Media Space</title></head><body><script>
        setTimeout(function () {
          var x = new XMLHttpRequest();
          x.open('GET', 'https://www.kaltura.com/p/1329972/sp/132997200/playManifest/entryId/1_oj3ppr67/protocol/https/format/applehttp/ks/\(Self.token)/a.m3u8');
          x.send();
        }, 100);
        </script></body></html>
        """
        let (state, _) = try await load(html: html, at: "https://mediaspace.illinois.edu/media/t/1_oj3ppr67/1")
        let source = try #require(state.found)
        #expect(source.partnerID == "1329972" && source.entryID == "1_oj3ppr67" && source.ks == Self.token)
    }

    @Test func findsTheLectureInInlineScriptConfig() async throws {
        let html = """
        <html><head><title>Inline - Illinois Media Space</title></head><body>
        <script>var c = {"provider":{"partnerId":"1329972","uiConfId":"55779922","env":{"serviceUrl":"https:\\/\\/www.kaltura.com\\/api_v3"},"ks":"\(Self.token)"}, "padding": "\(String(repeating: "x", count: 200))"};</script>
        </body></html>
        """
        let (state, _) = try await load(html: html, at: "https://mediaspace.illinois.edu/media/t/1_oj3ppr67/1")
        #expect(state.found?.ks == Self.token && state.found?.partnerID == "1329972")
    }

    @Test func ignoresMessagesFromUntrustedOrigins() async throws {
        let html = """
        <html><body><script>
        window.KalturaPlayer = { getPlayers: function () { return { p1: { config: { provider: { partnerId: 1, ks: '\(Self.token)' }, sources: { id: '1_oj3ppr67' } } } }; } };
        </script></body></html>
        """
        let (state, _) = try await load(html: html, at: "https://evil.example.com/media/t/1_oj3ppr67/1", timeout: .seconds(3))
        #expect(state.found == nil)
        #expect(!state.isOnMediaPage)
    }
}
