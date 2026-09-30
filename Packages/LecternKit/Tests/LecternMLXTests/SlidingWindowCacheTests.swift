import MLX
import MLXLMCommon
import Testing

@testable import LecternMLX

/// The rewindable sliding-window cache must produce exactly the attention a full cache with a
/// windowed causal mask produces, across prefill chunks, single-token decode and compaction.
@Suite struct SlidingWindowCacheTests {
    private let window = 8
    private let heads = 2
    private let dim = 4

    init() { MetalLibrary.ensureConfigured() }

    private func random(_ n: Int, seed: UInt64) -> MLXArray {
        MLXRandom.normal([1, heads, n, dim], key: MLXRandom.key(seed))
    }

    /// Attention of `q` over the window ending at each query, using all keys seen so far.
    private func reference(_ q: MLXArray, _ keys: MLXArray, _ values: MLXArray, offset: Int) -> MLXArray {
        let mask = createCausalMask(n: q.dim(2), offset: offset, windowSize: window)
        return MLXFast.scaledDotProductAttention(
            queries: q, keys: keys, values: values, scale: 1, mask: .array(mask))
    }

    private func attend(_ cache: ReusableSlidingWindowCache, _ q: MLXArray, _ k: MLXArray, _ v: MLXArray) -> MLXArray {
        let mask = cache.makeMask(n: q.dim(2), windowSize: window, returnArray: false)
        let (keys, values) = cache.update(keys: k, values: v)
        return MLXFast.scaledDotProductAttention(
            queries: q, keys: keys, values: values, scale: 1, mask: mask)
    }

    @Test func matchesWindowedFullAttention() {
        let cache = ReusableSlidingWindowCache(window: window, slack: 3, step: 4)
        var allK: [MLXArray] = []
        var allV: [MLXArray] = []
        var offset = 0
        for (i, n) in [5, 1, 1, 7, 3, 1, 12, 1, 1, 9, 2].enumerated() {
            let (q, k, v) = (random(n, seed: UInt64(3 * i)), random(n, seed: UInt64(3 * i + 1)),
                             random(n, seed: UInt64(3 * i + 2)))
            let out = attend(cache, q, k, v)
            allK.append(k)
            allV.append(v)
            let expected = reference(
                q, concatenated(allK, axis: 2), concatenated(allV, axis: 2), offset: offset)
            #expect(allClose(out, expected, atol: 1e-5).item(Bool.self), "chunk \(i) (n=\(n))")
            offset += n
        }
        #expect(cache.offset == offset)
    }

    @Test func rewindWithinSlackIsExact() {
        let cache = ReusableSlidingWindowCache(window: window, slack: 6, step: 4)
        let prefix = (random(30, seed: 1), random(30, seed: 2), random(30, seed: 3))
        _ = attend(cache, prefix.0, prefix.1, prefix.2)

        let suffix = (random(5, seed: 4), random(5, seed: 5), random(5, seed: 6))
        let first = attend(cache, suffix.0, suffix.1, suffix.2)

        #expect(cache.canRewindExactly(5))
        #expect(cache.trim(5) == 5)
        let again = attend(cache, suffix.0, suffix.1, suffix.2)
        #expect(allClose(first, again, atol: 1e-6).item(Bool.self))
    }

    @Test func rewindBeyondSlackIsReportedInexact() {
        let cache = ReusableSlidingWindowCache(window: window, slack: 2, step: 4)
        for i in 0 ..< 40 {
            _ = attend(cache, random(1, seed: UInt64(i)), random(1, seed: UInt64(100 + i)),
                       random(1, seed: UInt64(200 + i)))
        }
        #expect(cache.canRewindExactly(2))
        #expect(!cache.canRewindExactly(12))
    }

    @Test func snapshotAttendsLikeTheOriginal() {
        let cache = ReusableSlidingWindowCache(window: window, slack: 20, step: 4)
        _ = attend(cache, random(30, seed: 1), random(30, seed: 2), random(30, seed: 3))
        let snapshot = cache.snapshot()
        #expect(snapshot.offset == 30)
        let next = (random(6, seed: 4), random(6, seed: 5), random(6, seed: 6))
        let fromSnapshot = attend(snapshot, next.0, next.1, next.2)
        let fromOriginal = attend(cache, next.0, next.1, next.2)
        #expect(allClose(fromSnapshot, fromOriginal, atol: 1e-6).item(Bool.self))
    }

    @Test func copyIsIndependent() {
        let cache = ReusableSlidingWindowCache(window: window, slack: 4)
        _ = attend(cache, random(6, seed: 1), random(6, seed: 2), random(6, seed: 3))
        let copy = cache.copy()
        _ = attend(cache, random(3, seed: 4), random(3, seed: 5), random(3, seed: 6))
        #expect(copy.offset == 6)
        #expect(cache.offset == 9)
    }
}

@Suite struct GrammarMaskExpanderTests {
    init() { MetalLibrary.ensureConfigured() }

    @Test func expandsPackedBitmask() {
        // 70 grammar tokens over 72 logits: allow 0, 33, 69 (bit 31 of word 0 too, as a sign bit).
        let expander = GrammarMaskExpander(logitDimension: 72, grammarVocabularySize: 70)
        let words: [Int32] = [Int32(bitPattern: 0x8000_0001), 1 << 1, 1 << 5]
        let allowed = expander.allowed(words).asArray(Bool.self)
        let ids = allowed.indices.filter { allowed[$0] }
        #expect(ids == [0, 31, 33, 69])
    }
}
