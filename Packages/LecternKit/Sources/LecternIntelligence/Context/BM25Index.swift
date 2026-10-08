import Foundation

/// Okapi BM25 over pre-tokenized documents (see `TranscriptRetriever.terms`).
struct BM25Index: Sendable {
    struct Hit: Sendable, Equatable {
        var index: Int
        var score: Double
    }

    private let termFrequencies: [[String: Int]]
    private let lengths: [Int]
    private let documentFrequency: [String: Int]
    private let averageLength: Double

    private static let k1 = 1.2
    private static let b = 0.75

    init(documents: [[String]]) {
        termFrequencies = documents.map { $0.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
        lengths = documents.map(\.count)
        documentFrequency = termFrequencies.reduce(into: [:]) { df, tf in
            for term in tf.keys { df[term, default: 0] += 1 }
        }
        averageLength = lengths.isEmpty ? 1 : max(1, Double(lengths.reduce(0, +)) / Double(lengths.count))
    }


    /// Documents containing at least one query term, best first.
    func search(_ queryTerms: [String]) -> [Hit] {
        let terms = Set(queryTerms)
        guard !terms.isEmpty, !lengths.isEmpty else { return [] }
        let n = Double(lengths.count)
        var hits: [Hit] = []
        for (i, tf) in termFrequencies.enumerated() {
            var score = 0.0
            for term in terms {
                guard let f = tf[term] else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let freq = Double(f)
                score += idf * freq * (Self.k1 + 1) / (freq + Self.k1 * (1 - Self.b + Self.b * Double(lengths[i]) / averageLength))
            }
            if score > 0 { hits.append(Hit(index: i, score: score)) }
        }
        return hits.sorted { $0.score > $1.score }
    }
}
