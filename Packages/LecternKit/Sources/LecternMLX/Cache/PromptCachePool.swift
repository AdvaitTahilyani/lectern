/// A small LRU of ``PromptCache`` slots for one model.
///
/// Lectern's roles use different stable prefixes (summaries, quizzes and Ask each have their own
/// system prompt + deck digest). With a single cache every Ask would evict the summaries prefix
/// and the next summary would pay a cold multi-thousand-token prefill again. Each request goes to
/// the slot whose tokens share the longest prefix with it; a prompt that shares too little with
/// every slot takes a free slot, or the least recently used one.
///
/// Not thread-safe; owned by ``MLXInferenceEngine`` and used only on its executor.
final class PromptCachePool {
    /// Shared prefix (in tokens) below which a slot is not considered a match.
    static let minimumSharedTokens = 128

    private let makeCache: () -> PromptCache
    /// Most recently used first.
    private var slots: [PromptCache] = []
    private(set) var capacity: Int

    init(capacity: Int, makeCache: @escaping () -> PromptCache) {
        self.capacity = max(1, capacity)
        self.makeCache = makeCache
    }

    /// Number of slots currently allocated.
    var count: Int { slots.count }

    /// The slot to use for `prompt`, marked most recently used.
    func slot(for prompt: [Int]) -> PromptCache {
        var best: (index: Int, shared: Int)?
        for (index, slot) in slots.enumerated() where !slot.isEmpty {
            let shared = PromptCache.commonPrefixLength(prompt, slot.tokens)
            if shared > (best?.shared ?? 0) { best = (index, shared) }
        }
        let chosen: PromptCache
        if let best, best.shared >= Self.minimumSharedTokens {
            chosen = slots.remove(at: best.index)
        } else if slots.count < capacity {
            chosen = makeCache()
        } else {
            chosen = slots.removeLast()
            chosen.invalidate()
        }
        slots.insert(chosen, at: 0)
        return chosen
    }

    /// Drops all but the `count` most recently used slots.
    private func keepMostRecent(_ count: Int) {
        guard slots.count > count else { return }
        slots.removeLast(slots.count - max(0, count))
    }

    /// Changes how many slots may be kept (e.g. fewer under memory pressure).
    func setCapacity(_ newCapacity: Int) {
        capacity = max(1, newCapacity)
        keepMostRecent(capacity)
    }

    /// Drops every slot.
    func removeAll() {
        slots.removeAll()
    }
}
