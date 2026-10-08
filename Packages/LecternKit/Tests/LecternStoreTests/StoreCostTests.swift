import Foundation
import LecternCore
import Testing
@testable import LecternStore

/// Audit P07: what a save of a growing lecture costs, measured piece by piece.
@Suite(.serialized) struct StoreCostTests {
    static func bigSession(segments: Int) -> LectureSession {
        var s = Fixtures.session()
        s.transcript = (0..<segments).map { i in
            TranscriptSegment(text: "Compiler optimization uses registers and intermediate representations to analyze the program. Sentence \(i)", start: Double(i) * 5, end: Double(i) * 5 + 4, isFinal: true)
        }
        return s
    }

    @Test func measureSerializationAndWriteCosts() async throws {
        let root = Fixtures.temporaryRoot()
        let store = FileSessionStore(root: root)
        for count in [500, 2000, 8000] {
            let session = Self.bigSession(segments: count)
            let clock = ContinuousClock()
            let pretty = StoreCoding.makeEncoder()
            var bytes = 0
            let encode = clock.measure { bytes = (try? pretty.encode(SessionFile(session: session)))?.count ?? 0 }
            let write = try await clock.measure { try await store.save(session) }
            let secondWrite = try await clock.measure { try await store.save(session) }   // also links the backup
            print("STORE-COST segments=\(count) bytes=\(bytes) encode_ms=\(encode.components.attoseconds / 1_000_000_000_000_000) first_save_ms=\(write.components.attoseconds / 1_000_000_000_000_000) second_save_ms=\(secondWrite.components.attoseconds / 1_000_000_000_000_000)")
        }
    }
}
