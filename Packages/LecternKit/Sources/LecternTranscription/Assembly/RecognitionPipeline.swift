import Foundation
import LecternCore

/// One incremental result from a `StreamingRecognizer`.
struct RecognizerUpdate: Sendable {
    /// The full cumulative transcript so far.
    var text: String
    /// Tokens decoded since the previous update.
    var tokens: [RecognizedToken]
    /// Stream time up to which decoding is complete (see `SegmentAssembler.update`).
    var decodedThrough: TimeInterval
}

/// A streaming speech recognizer fed with 16 kHz mono Float32 samples. Implementations own their
/// own isolation; calls arrive from a single task, one at a time.
protocol StreamingRecognizer: Sendable {
    /// Feeds audio. Returns an update if anything new can be reported.
    func append(_ samples: [Float]) async throws -> RecognizerUpdate?
    /// Ends the stream, flushing all audio still buffered.
    func finish() async throws -> RecognizerUpdate
    /// Abandons the stream without flushing.
    func cancel() async
}

/// Glue between a recognizer and the `SegmentAssembler`: audio in, transcript events out.
/// Used by both live capture and file transcription.
actor RecognitionPipeline: SessionRecognizer {
    private let recognizer: any StreamingRecognizer
    private var assembler: SegmentAssembler
    private let sink: EventSink

    init(recognizer: any StreamingRecognizer, assembler: SegmentAssembler, sink: EventSink) {
        self.recognizer = recognizer
        self.assembler = assembler
        self.sink = sink
    }

    func feed(_ samples: [Float]) async throws {
        guard let update = try await recognizer.append(samples) else { return }
        let speakers = sink.speakerActivity(since: assembler.pendingStart)
        for event in assembler.update(text: update.text, tokens: update.tokens, decodedThrough: update.decodedThrough, speakers: speakers) {
            sink.send(event)
        }
    }

    func finish() async throws {
        let update = try await recognizer.finish()
        let speakers = sink.speakerActivity(since: assembler.pendingStart)
        for event in assembler.finish(text: update.text, tokens: update.tokens, speakers: speakers) {
            sink.send(event)
        }
    }

    func cancel() async {
        await recognizer.cancel()
    }
}
