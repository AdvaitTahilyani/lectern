import AppKit
import Foundation
import LecternCore
import PDFKit
import Testing
@testable import LecternImport

@Suite struct PPTXNotesTests {
    @Test func mapsNotesToPresentationOrderNotFileNumbers() throws {
        let directory = try makeTemporaryDirectory("pptx")
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = try PPTXNotesParser.parse(try PPTXFixture.make(in: directory))
        #expect(contents.slideCount == 3)
        #expect(contents.hiddenSlides == [3])
        #expect(contents.notes == [
            1: "Notes for the first position.\nSecond line & more",
            2: "Position two\nafter a break",
        ])
    }

    @Test func resolvesRelationshipTargets() {
        #expect(PPTXNotesParser.resolve("../notesSlides/notesSlide2.xml", relativeTo: "ppt/slides") == "ppt/notesSlides/notesSlide2.xml")
        #expect(PPTXNotesParser.resolve("/ppt/slides/slide3.xml", relativeTo: "ppt") == "ppt/slides/slide3.xml")
        #expect(PPTXNotesParser.resolve("slides/slide1.xml", relativeTo: "ppt") == "ppt/slides/slide1.xml")
    }

    @Test func rejectsFilesThatAreNotPPTX() throws {
        let directory = try makeTemporaryDirectory("pptx")
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("bad.pptx")
        try "not a zip".write(to: text, atomically: true, encoding: .utf8)
        #expect(throws: ImportError.self) { try PPTXNotesParser.parse(text) }
    }

    @Test func hiddenSlidesAreSkippedWhenThePDFOmitsThem() {
        let contents = PPTXContents(notes: [1: "a", 3: "c", 4: "d"], slideCount: 4, hiddenSlides: [2])
        #expect(PresentationConverter.notesByPage(contents, pageCount: 3) == [1: "a", 2: "c", 3: "d"])
        #expect(PresentationConverter.notesByPage(contents, pageCount: 4) == contents.notes)
    }

    @Test func parsesKeynoteScriptNotes() {
        let output = "one\u{1E}\u{1E}three\nlines"
        #expect(PresentationConverter.notes(fromScriptOutput: output) == [1: "one", 3: "three\nlines"])
        #expect(PresentationConverter.notes(fromScriptOutput: "").isEmpty)
    }
}

/// Records scripts and plays the part of Keynote / PowerPoint by writing a PDF.
private final class FakeRunner: AppleScriptRunning, @unchecked Sendable {
    struct Call { var script: String; var arguments: [String]; var application: String }
    private let lock = NSLock()   // guards `recorded`
    private var recorded: [Call] = []
    var behavior: @Sendable (Call) throws -> String

    init(behavior: @escaping @Sendable (Call) throws -> String = { call in
        try FakeRunner.writePDF(pages: 2, to: URL(fileURLWithPath: call.arguments[1]))
        return ""
    }) { self.behavior = behavior }

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }

    func run(_ script: String, arguments: [String], application: String, timeout: TimeInterval) async throws -> String {
        let call = Call(script: script, arguments: arguments, application: application)
        lock.withLock { recorded.append(call) }
        return try behavior(call)
    }

    static func writePDF(pages: Int, to url: URL) throws {
        let document = PDFDocument()
        for index in 0..<pages { document.insert(PDFPage(image: makeImage())!, at: index) }
        guard document.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 100, height: 80))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 80).fill(); image.unlockFocus()
        return image
    }
}

@Suite struct PresentationConverterTests {
    private func converter(_ runner: FakeRunner, installed: Set<String> = [PresentationConverter.keynoteBundleID, PresentationConverter.powerPointBundleID]) -> PresentationConverter {
        PresentationConverter(runner: runner, isInstalled: { installed.contains($0) })
    }

    @Test func exportsPPTXThroughKeynoteAndReadsNotesFromThePackage() async throws {
        let directory = try makeTemporaryDirectory("pptx")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pptx = try PPTXFixture.make(in: directory, name: "Week 3 deck.pptx")
        let runner = FakeRunner()
        let result = try await converter(runner).convertToPDF(pptx)
        defer { try? FileManager.default.removeItem(at: result.pdf.deletingLastPathComponent()) }

        #expect(result.pdf.lastPathComponent == "Week 3 deck.pdf")
        #expect(PDFDocument(url: result.pdf)?.pageCount == 2)
        // 3 slides, 1 hidden, 2 pages exported → notes follow the visible slides.
        #expect(result.notes == [1: "Notes for the first position.\nSecond line & more", 2: "Position two\nafter a break"])
        let call = try #require(runner.calls.first)
        #expect(call.application == "Keynote")
        #expect(call.arguments == [pptx.path, result.pdf.path, "no"])   // paths pass through argv, not the script text
        #expect(call.script.contains("export theDoc to (POSIX file outPath) as PDF"))
        #expect(!call.script.contains(pptx.path))
    }

    @Test func keynoteFilesTakeNotesFromTheScriptOutput() async throws {
        let directory = try makeTemporaryDirectory("key")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("talk.key")
        try Data("x".utf8).write(to: key)
        let runner = FakeRunner { call in
            try FakeRunner.writePDF(pages: 2, to: URL(fileURLWithPath: call.arguments[1]))
            return "first\u{1E}second"
        }
        let result = try await converter(runner).convertToPDF(key)
        defer { try? FileManager.default.removeItem(at: result.pdf.deletingLastPathComponent()) }
        #expect(result.notes == [1: "first", 2: "second"])
        #expect(runner.calls.first?.arguments.last == "yes")
    }

    @Test func fallsBackToPowerPointWhenKeynoteFails() async throws {
        let directory = try makeTemporaryDirectory("pptx")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pptx = try PPTXFixture.make(in: directory)
        let runner = FakeRunner { call in
            if call.application == "Keynote" { throw ImportError.conversionFailed(app: "Keynote", message: "boom") }
            try FakeRunner.writePDF(pages: 3, to: URL(fileURLWithPath: call.arguments[1]))
            return ""
        }
        let result = try await converter(runner).convertToPDF(pptx)
        defer { try? FileManager.default.removeItem(at: result.pdf.deletingLastPathComponent()) }
        #expect(runner.calls.map(\.application) == ["Keynote", "Microsoft PowerPoint"])
        #expect(runner.calls[1].script.contains("save as PDF"))
        #expect(PDFDocument(url: result.pdf)?.pageCount == 3)
    }

    @Test func surfacesAutomationDeniedWithGuidance() async throws {
        let directory = try makeTemporaryDirectory("pptx")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pptx = try PPTXFixture.make(in: directory)
        let runner = FakeRunner { _ in throw ImportError.automationDenied(app: "Keynote") }
        let error = await #expect(throws: ImportError.self) {
            try await converter(runner, installed: [PresentationConverter.keynoteBundleID]).convertToPDF(pptx)
        }
        #expect(error == .automationDenied(app: "Keynote"))
        #expect(error?.errorDescription?.contains("Automation") == true)
        // The temporary output directory is cleaned up on failure.
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: runner.calls[0].arguments[1]).deletingLastPathComponent().path))
    }

    @Test func reportsMissingApplicationsAndUnsupportedTypes() async throws {
        let directory = try makeTemporaryDirectory("pptx")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pptx = try PPTXFixture.make(in: directory)
        await #expect(throws: ImportError.noPresentationApp) { try await converter(FakeRunner(), installed: []).convertToPDF(pptx) }
        let key = directory.appendingPathComponent("deck.key")
        FileManager.default.createFile(atPath: key.path, contents: Data("x".utf8))
        // PowerPoint can't open Keynote files, so having only it installed doesn't help.
        await #expect(throws: ImportError.keynoteNotInstalled) { try await converter(FakeRunner(), installed: [PresentationConverter.powerPointBundleID]).convertToPDF(key) }
        await #expect(throws: ImportError.unsupportedFileType("docx")) { try await converter(FakeRunner()).convertToPDF(directory.appendingPathComponent("a.docx")) }
    }

    @Test func mapsAutomationErrorCodes() {
        let denied = OsaScriptRunner.error(from: "execution error: Not authorized to send Apple events to Keynote. (-1743)", application: "Keynote")
        #expect(denied == .automationDenied(app: "Keynote"))
        let other = OsaScriptRunner.error(from: "execution error: Keynote got an error: Can't get document 1. (-1728)", application: "Keynote")
        #expect(other == .conversionFailed(app: "Keynote", message: "execution error: Keynote got an error: Can't get document 1. (-1728)"))
    }

    @Test func osascriptRunnerPassesArgumentsAndTimesOut() async throws {
        let runner = OsaScriptRunner()
        let echoed = try await runner.run("on run argv\n return (item 2 of argv) & \"|\" & (item 1 of argv)\nend run", arguments: ["/tmp/a b/it's", "ü \"q\""], application: "x", timeout: 20)
        #expect(echoed == "ü \"q\"|/tmp/a b/it's")
        await #expect(throws: ImportError.conversionTimedOut(app: "Sleepy")) {
            try await runner.run("on run argv\n delay 30\nend run", arguments: [], application: "Sleepy", timeout: 1)
        }
    }
}
