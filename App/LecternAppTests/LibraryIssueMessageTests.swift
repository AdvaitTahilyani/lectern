import Foundation
import Testing
@testable import Lectern

/// The Library banner after a damaged-file load must say what happened to each file (QA Q3-4).
@Suite struct LibraryIssueMessageTests {
    private func issue(_ name: String, _ kind: LibraryIssue.Kind) -> LibraryIssue {
        LibraryIssue(file: URL(fileURLWithPath: "/tmp/\(name)/session.json"), kind: kind)
    }

    @Test func noIssuesNoMessage() {
        #expect(LibraryView.issueMessage([]) == nil)
    }

    @Test func restoredIsDistinctFromSkipped() {
        let restored = LibraryView.issueMessage([issue("a", .restored)])
        #expect(restored == "1 lecture was restored from the last good copy; the latest changes may be missing.")
        let skipped = LibraryView.issueMessage([issue("b", .skipped), issue("c", .skipped)])
        #expect(skipped == "2 lecture files couldn't be read and are left out; the files are untouched.")
    }

    @Test func mixedKindsAreEachReported() throws {
        let message = try #require(LibraryView.issueMessage([issue("a", .restored), issue("b", .partiallyRecovered), issue("c", .skipped)]))
        #expect(message.contains("restored"))
        #expect(message.contains("damaged parts"))
        #expect(message.contains("couldn't be read"))
    }
}
