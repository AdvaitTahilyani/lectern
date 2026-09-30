import MLX
import MLXLMCommon
import Testing

@testable import LecternMLX

/// Prefix reuse bookkeeping, driven with real (tiny) caches.
@Suite struct PromptCacheTests {
    init() { MetalLibrary.ensureConfigured() }

    /// Appends `n` positions to every layer, as a forward pass would.
    private func feed(_ layers: [any KVCache], _ n: Int) {
        let kv = MLXArray.zeros([1, 1, n, 2])
        for layer in layers { _ = layer.update(keys: kv, values: kv) }
    }

    private func makeCache() -> PromptCache {
        PromptCache {
            [KVCacheSimple(), ReusableSlidingWindowCache(window: 4, slack: 8, step: 4)]
        }
    }

    @Test func freshPromptReusesNothing() throws {
        let cache = makeCache()
        let reuse = try cache.reuse(for: [1, 2, 3])
        #expect(reuse.reusedTokens == 0)
        #expect(reuse.checkpointAt == nil)
    }

    @Test func rewindsPreviousInstructionAndOutput() throws {
        let cache = makeCache()
        let first = try cache.reuse(for: [1, 2, 3, 4, 5])
        feed(first.layers, 6)  // 5 prompt tokens + 1 generated
        cache.commit([1, 2, 3, 4, 5, 9])

        let second = try cache.reuse(for: [1, 2, 3, 4, 6, 7])
        #expect(second.reusedTokens == 4)
        #expect(second.layers.allSatisfy { $0.offset == 4 })
        #expect(cache.tokens == [1, 2, 3, 4])
    }

    @Test func identicalPromptStillFeedsLastToken() throws {
        let cache = makeCache()
        let first = try cache.reuse(for: [1, 2, 3])
        feed(first.layers, 3)
        cache.commit([1, 2, 3])

        let second = try cache.reuse(for: [1, 2, 3])
        #expect(second.reusedTokens == 2)
        #expect(second.layers.allSatisfy { $0.offset == 2 })
    }

    @Test func mismatchedLengthInvalidates() throws {
        let cache = makeCache()
        let first = try cache.reuse(for: [1, 2, 3])
        feed(first.layers, 2)
        cache.commit([1, 2, 3])  // claims 3, layers hold 2
        #expect(cache.isEmpty)
    }

    @Test func nonRewindableLayersUseCheckpoint() throws {
        let cache = PromptCache { [KVCacheSimple(), MambaCache()] }
        // Call 1: nothing known yet.
        var reuse = try cache.reuse(for: [1, 2, 3, 4, 5])
        feed([reuse.layers[0]], 5)
        cache.commit([1, 2, 3, 4, 5])

        // Call 2 diverges at 3 and cannot rewind the recurrent layer: rebuild, checkpoint at 3.
        reuse = try cache.reuse(for: [1, 2, 3, 7, 8])
        #expect(reuse.reusedTokens == 0)
        #expect(reuse.checkpointAt == 3)
        feed([reuse.layers[0]], 3)
        cache.commit([1, 2, 3])
        cache.captureCheckpoint(length: 3)
        feed([reuse.layers[0]], 2)
        cache.commit([1, 2, 3, 7, 8])

        // Call 3 shares the checkpointed prefix: restored there.
        reuse = try cache.reuse(for: [1, 2, 3, 7, 9, 10])
        #expect(reuse.reusedTokens == 3)
        #expect(reuse.layers[0].offset == 3)
    }

    @Test func stablePrefixSnapshotCoversRewindsBeyondSlack() throws {
        let cache = PromptCache {
            [KVCacheSimple(), ReusableSlidingWindowCache(window: 4, slack: 2, step: 4)]
        }
        let prefix = Array(1 ... 5)
        var reuse = try cache.reuse(for: prefix + Array(100 ..< 115), stablePrefix: 5)
        #expect(reuse.checkpointAt == 5)
        feed(reuse.layers, 5)
        cache.commit(prefix)
        cache.captureCheckpoint(length: 5)
        feed(reuse.layers, 15)
        cache.commit(prefix + Array(100 ..< 115))

        // The tail is replaced by 10 new tokens: rewinding 15 exceeds the slack of 2.
        reuse = try cache.reuse(for: prefix + Array(200 ..< 210), stablePrefix: 5)
        #expect(reuse.reusedTokens == 5)
        #expect(reuse.checkpointAt == nil)
        #expect(reuse.layers.allSatisfy { $0.offset == 5 })
        #expect(cache.checkpointLength == 5)
    }
}


@Suite struct PromptCachePoolTests {
    init() { MetalLibrary.ensureConfigured() }

    private func filled(_ cache: PromptCache, _ tokens: [Int]) throws {
        let reuse = try cache.reuse(for: tokens)
        let kv = MLXArray.zeros([1, 1, tokens.count - reuse.reusedTokens, 2])
        for layer in reuse.layers { _ = layer.update(keys: kv, values: kv) }
        cache.commit(tokens)
    }

    @Test func rolesWithDifferentPrefixesKeepSeparateSlots() throws {
        let pool = PromptCachePool(capacity: 2) { PromptCache { [KVCacheSimple()] } }
        let summaries = Array(0 ..< 300)
        let ask = Array(1000 ..< 1300)
        try filled(pool.slot(for: summaries + [1]), summaries + [1])
        try filled(pool.slot(for: ask + [2]), ask + [2])
        #expect(pool.count == 2)

        // Each role finds its own warm slot again.
        #expect(pool.slot(for: summaries + [3]).tokens.starts(with: summaries))
        #expect(pool.slot(for: ask + [4]).tokens.starts(with: ask))

        // A third prefix evicts the least recently used slot (summaries).
        let quiz = Array(5000 ..< 5300)
        let evicted = pool.slot(for: quiz)
        #expect(evicted.isEmpty)
        #expect(pool.count == 2)
        #expect(pool.slot(for: ask + [5]).tokens.starts(with: ask))
    }

    @Test func shrinkingKeepsMostRecent() throws {
        let pool = PromptCachePool(capacity: 3) { PromptCache { [KVCacheSimple()] } }
        try filled(pool.slot(for: Array(0 ..< 200)), Array(0 ..< 200))
        try filled(pool.slot(for: Array(500 ..< 700)), Array(500 ..< 700))
        pool.setCapacity(1)
        #expect(pool.count == 1)
        #expect(pool.slot(for: Array(500 ..< 700) + [1]).tokens.starts(with: Array(500 ..< 700)))
    }
}
