import Foundation
import LecternCore
@testable import LecternSlides

/// The fixture PDF written once per test run and ingested once (OCR included), shared by suites.
enum FixtureDeck {
    struct Loaded: Sendable {
        var url: URL
        var deck: SlideDeck
        var progress: [Double]
    }

    static let shared = Task<Loaded, any Error> {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-fixture-\(UUID().uuidString).pdf")
        try CompilerDeckFixture.write(to: url)
        let recorder = ProgressRecorder()
        let deck = try await PDFSlideIngestor().ingest(pdfAt: url) { recorder.record($0) }
        return Loaded(url: url, deck: deck, progress: recorder.values)
    }

    static func load() async throws -> Loaded { try await shared.value }

    /// A fresh temporary file URL with the given extension.
    static func temporaryURL(_ ext: String = "pdf") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lectern-\(UUID().uuidString).\(ext)")
    }
}

/// Collects progress callbacks (delivered from arbitrary threads).
final class ProgressRecorder: @unchecked Sendable {
    // Guarded by `lock`.
    private var storage: [Double] = []
    private let lock = NSLock()

    func record(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
