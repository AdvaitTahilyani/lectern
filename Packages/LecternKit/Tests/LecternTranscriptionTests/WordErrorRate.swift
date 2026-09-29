import Foundation

/// Normalized word error rate used by the live accuracy checks.
enum WordErrorRate {
    /// Lowercases, drops apostrophes, turns everything else that is not a letter or digit into
    /// a word break.
    static func words(_ text: String) -> [String] {
        var cleaned = ""
        for character in text.lowercased() {
            if character == "'" || character == "\u{2019}" { continue }
            cleaned.append(character.isLetter || character.isNumber ? character : " ")
        }
        return cleaned.split(separator: " ").map(String.init)
    }

    struct Result {
        var errors: Int
        var referenceCount: Int
        var substitutions: Int
        var deletions: Int
        var insertions: Int
        var rate: Double { referenceCount == 0 ? 0 : Double(errors) / Double(referenceCount) }
    }

    /// Word-level Levenshtein distance with an error breakdown.
    static func compare(reference: [String], hypothesis: [String]) -> Result {
        let n = reference.count, m = hypothesis.count
        if n == 0 { return Result(errors: m, referenceCount: 0, substitutions: 0, deletions: 0, insertions: m) }
        if m == 0 { return Result(errors: n, referenceCount: n, substitutions: 0, deletions: n, insertions: 0) }

        // Full DP table of small integers: 12k x 12k words would be too big, so keep only
        // the operation counts alongside the two rolling rows.
        typealias Cell = (cost: Int, sub: Int, del: Int, ins: Int)
        var previous = (0...m).map { Cell(cost: $0, sub: 0, del: 0, ins: $0) }
        for i in 1...n {
            var current = [Cell](repeating: (i, 0, i, 0), count: m + 1)
            for j in 1...m {
                let same = reference[i - 1] == hypothesis[j - 1]
                let diagonal = previous[j - 1]
                let up = previous[j]          // deletion
                let left = current[j - 1]     // insertion
                var best = same
                    ? diagonal
                    : Cell(diagonal.cost + 1, diagonal.sub + 1, diagonal.del, diagonal.ins)
                if up.cost + 1 < best.cost { best = Cell(up.cost + 1, up.sub, up.del + 1, up.ins) }
                if left.cost + 1 < best.cost { best = Cell(left.cost + 1, left.sub, left.del, left.ins + 1) }
                current[j] = best
            }
            previous = current
        }
        let end = previous[m]
        return Result(errors: end.cost, referenceCount: n, substitutions: end.sub, deletions: end.del, insertions: end.ins)
    }
}
