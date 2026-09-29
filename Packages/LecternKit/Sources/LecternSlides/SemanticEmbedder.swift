import Foundation
import NaturalLanguage
import Synchronization

/// Sentence-level semantic vectors from the on-device `NLEmbedding` English model.
///
/// Creation fails (returns nil) when the model is unavailable, in which case retrieval falls back
/// to lexical scoring only. Long text is embedded in short chunks whose vectors are averaged,
/// because the sentence model is tuned for sentence-sized input.
final class SemanticEmbedder: Sendable {
    /// `NLEmbedding` makes no thread-safety promises, so every call goes through this lock.
    private let embedding: Mutex<NLEmbedding>
    private static let chunkLength = 220

    init?() {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        self.embedding = Mutex(embedding)
    }

    /// Unit-length vector for `text`, or nil when the text has nothing embeddable.
    func vector(for text: String) -> [Double]? {
        let chunks = Self.chunks(of: text)
        guard !chunks.isEmpty else { return nil }
        var sum: [Double] = []
        embedding.withLock { model in
            for chunk in chunks {
                guard let v = model.vector(for: chunk) else { continue }
                if sum.isEmpty { sum = v } else { for k in sum.indices { sum[k] += v[k] } }
            }
        }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return sum.map { $0 / norm }
    }

    /// Cosine similarity of two unit vectors (their dot product).
    static func similarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 0 }
        var dot = 0.0
        for k in a.indices { dot += a[k] * b[k] }
        return dot
    }

    /// Greedily packs lines/sentences into chunks of about `chunkLength` characters.
    private static func chunks(of text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        let pieces = text.components(separatedBy: .newlines).flatMap { SentenceSplitter.sentences(in: $0) }
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(where: \.isLetter) else { continue }
            if !current.isEmpty, current.count + trimmed.count + 2 > chunkLength {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : ". ") + trimmed
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
