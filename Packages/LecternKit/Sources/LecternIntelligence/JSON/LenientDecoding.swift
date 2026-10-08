import Foundation

/// Type-coercing reads for model-produced JSON: a missing or oddly typed field yields a sensible
/// value instead of failing the whole decode. Semantic checks happen later, in each reply's
/// `validated()`.
extension KeyedDecodingContainer where Key == NormalizedKey {
    func string(_ key: String) -> String {
        let k = NormalizedKey(stringValue: key)
        if let s = try? decode(String.self, forKey: k) { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = try? decode(Double.self, forKey: k) { return lenientNumberText(n) }
        if let b = try? decode(Bool.self, forKey: k) { return String(b) }
        if let parts = try? decode([String].self, forKey: k) { return parts.joined(separator: " ") }
        return ""
    }

    func strings(_ key: String) -> [String] {
        let k = NormalizedKey(stringValue: key)
        if let list = try? decode([LenientString].self, forKey: k) {
            return list.map(\.value).filter { !$0.isEmpty }
        }
        let single = string(key)
        guard !single.isEmpty else { return [] }
        // A single string with one item per line (often bulleted).
        return single.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•*· ").union(.whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// Integers from `[4, 5]`, `["S4", "5"]`, `"4, 5"`, `"4-6"`, `4.0`, or `4`.
    func ints(_ key: String) -> [Int] {
        let k = NormalizedKey(stringValue: key)
        if let list = try? decode([LenientString].self, forKey: k) {
            return list.flatMap { LenientInts.parse($0.value) }
        }
        return LenientInts.parse(string(key))
    }

    func bool(_ key: String) -> Bool? {
        let k = NormalizedKey(stringValue: key)
        if let b = try? decode(Bool.self, forKey: k) { return b }
        if let n = try? decode(Int.self, forKey: k) { return n != 0 }
        switch string(key).lowercased() {
        case "true", "yes", "correct", "right", "1": return true
        case "false", "no", "incorrect", "wrong", "0": return false
        default: return nil
        }
    }
}

/// Decodes a JSON string, number or bool into text; objects collapse to their first string value
/// (models sometimes write `[{"text": "…"}]`).
struct LenientString: Decodable {
    var value: String

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let s = try? single.decode(String.self) {
            value = s.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let n = try? single.decode(Double.self) {
            value = lenientNumberText(n)
        } else if let b = try? single.decode(Bool.self) {
            value = String(b)
        } else if let object = try? single.decode([String: LenientString].self) {
            value = object.sorted { $0.key < $1.key }.first { !$0.value.value.isEmpty }?.value.value ?? ""
        } else {
            value = ""
        }
    }
}

enum LenientInts {
    /// All integers mentioned in `text`; `a-b` / `a–b` ranges (up to 30 wide) are expanded.
    static func parse(_ text: String) -> [Int] {
        var result: [Int] = []
        let range = /(\d+)\s*[-–]\s*(\d+)/
        for match in text.matches(of: range) {
            if let a = Int(match.1), let b = Int(match.2), a <= b, b - a <= 30 {
                result.append(contentsOf: a...b)
            }
        }
        for match in text.replacing(range, with: " ").matches(of: /\d+/) {
            if let n = Int(match.0) { result.append(n) }
        }
        return result
    }
}

/// `n` as text: whole numbers without a decimal point. A value too large for `Int` (a model can
/// write any number of digits) keeps its floating-point form instead of trapping.
func lenientNumberText(_ n: Double) -> String {
    n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
}
