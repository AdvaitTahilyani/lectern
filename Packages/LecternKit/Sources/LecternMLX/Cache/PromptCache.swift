import MLX
import MLXLMCommon

/// The live KV cache of one loaded model, plus the exact token sequence it represents.
///
/// Each call reconciles the cache with the new prompt: it keeps the longest common token
/// prefix, rewinds whatever follows it (the previous call's variable tail and generated
/// tokens), and reports how many prompt tokens are already represented so only the rest is
/// prefilled. Lectern's prompts keep a byte-stable prefix (system + deck digest) followed by a
/// transcript window and a per-call tail, so most calls prefill only a few hundred tokens.
///
/// Layers are rewound in one of two ways:
/// - full-attention caches (`KVCacheSimple`, `QuantizedKVCache`) trim exactly, any distance;
/// - every other layer (sliding-window ``ReusableSlidingWindowCache``, exact only within its
///   slack; recurrent / state-space caches, never) is covered by a **prefix snapshot**: a copy
///   taken when the cache holds exactly the stable prefix. When a prompt keeps that prefix but
///   replaces more than the slack after it (for example a new topic's transcript window), the
///   snapshot is restored and full-attention layers are trimmed to the same point.
///
/// Not thread-safe; owned by ``MLXInferenceEngine`` and used only on its executor.
final class PromptCache {
    /// Copies of the layers that full-attention trimming cannot rewind, at a known position.
    private struct Checkpoint {
        let length: Int
        let snapshots: [Int: any KVCache]
    }

    /// Result of reconciling the cache with a prompt.
    struct Reuse {
        /// Cache to prefill into (already rewound to `reusedTokens`).
        let layers: [any KVCache]
        /// Number of leading prompt tokens already represented by `layers`.
        let reusedTokens: Int
        /// When set, the caller must call ``PromptCache/captureCheckpoint(length:)`` once the
        /// cache holds exactly this many prompt tokens (the end of the stable prefix).
        let checkpointAt: Int?
    }

    private let makeLayers: () throws -> [any KVCache]
    private var layers: [any KVCache]?
    private var checkpoint: Checkpoint?

    /// Tokens the live cache represents, in order.
    private(set) var tokens: [Int] = []

    init(makeLayers: @escaping () throws -> [any KVCache]) {
        self.makeLayers = makeLayers
    }

    /// Whether any KV state is held.
    var isEmpty: Bool { layers == nil }

    /// Length of the current prefix snapshot, if any.
    var checkpointLength: Int? { checkpoint?.length }

    /// Drops all cached state (e.g. under memory pressure).
    func invalidate() {
        layers = nil
        checkpoint = nil
        tokens = []
    }

    /// Reconciles the cache with `prompt`. At least one prompt token is always left to feed,
    /// so the caller gets fresh logits for the final position.
    ///
    /// - Parameter stablePrefix: number of leading prompt tokens expected to repeat across
    ///   calls (e.g. everything before the last message). A snapshot is taken there when the
    ///   model has layers that cannot be trimmed arbitrarily far. When nil, the divergence point
    ///   with the previous prompt is used instead.
    func reuse(for prompt: [Int], stablePrefix: Int? = nil) throws -> Reuse {
        guard let layers, !tokens.isEmpty, !prompt.isEmpty else {
            return try fresh(checkpointAt: stablePrefix, promptCount: prompt.count)
        }

        let common = min(Self.commonPrefixLength(prompt, tokens), prompt.count - 1)
        let wanted = Self.checkpointPosition(
            stablePrefix ?? common, promptCount: prompt.count, layers: layers)
        guard common > 0 else { return try fresh(checkpointAt: wanted, promptCount: prompt.count) }

        // 1. Rewind every layer in place when that is exact.
        let rewind = tokens.count - common
        if layers.allSatisfy({ Self.canRewindExactly($0, by: rewind) }) {
            for layer in layers where rewind > 0 { layer.trim(rewind) }
            tokens.removeLast(rewind)
            if let checkpoint, checkpoint.length > tokens.count { self.checkpoint = nil }
            return Reuse(layers: layers, reusedTokens: common, checkpointAt: pending(wanted, from: common))
        }

        // 2. Restore the prefix snapshot and trim full-attention layers to it.
        if let checkpoint, checkpoint.length <= common {
            let back = tokens.count - checkpoint.length
            let restorable = layers.indices.allSatisfy { index in
                checkpoint.snapshots[index] != nil || Self.canRewindExactly(layers[index], by: back)
            }
            if restorable {
                var restored = layers
                for index in layers.indices {
                    if let snapshot = checkpoint.snapshots[index] {
                        restored[index] = snapshot.copy()
                    } else {
                        restored[index].trim(back)
                    }
                }
                self.layers = restored
                tokens.removeLast(back)
                return Reuse(
                    layers: restored, reusedTokens: checkpoint.length,
                    checkpointAt: pending(wanted, from: checkpoint.length))
            }
        }

        // 3. Start over.
        return try fresh(checkpointAt: wanted, promptCount: prompt.count)
    }

    /// Snapshots the layers full-attention trimming cannot rewind. Call when the cache holds
    /// exactly `length` tokens of the current prompt (see ``Reuse/checkpointAt``).
    func captureCheckpoint(length: Int) {
        guard let layers, length > 0 else { return }
        if checkpoint?.length == length { return }
        var snapshots: [Int: any KVCache] = [:]
        for index in layers.indices where Self.needsSnapshot(layers[index]) {
            snapshots[index] =
                (layers[index] as? ReusableSlidingWindowCache)?.snapshot() ?? layers[index].copy()
        }
        guard !snapshots.isEmpty else { return }
        // Materialize now so the snapshot does not keep the live buffers' graph alive.
        eval(snapshots.values.flatMap(\.state))
        checkpoint = Checkpoint(length: length, snapshots: snapshots)
    }

    /// Records that `represented` (a prefix of the prompt plus fed generated tokens) is now
    /// exactly what the cache holds. Invalidates the cache instead if a layer disagrees with
    /// the length (a defensive check; it never fires when callers feed exactly `represented`).
    func commit(_ represented: [Int]) {
        if let layers,
            let reference = layers.first(where: { $0 is KVCacheSimple || $0 is ReusableSlidingWindowCache }),
            reference.offset != represented.count
        {
            invalidate()
            return
        }
        tokens = represented
    }

    // MARK: - Private

    private func fresh(checkpointAt: Int?, promptCount: Int) throws -> Reuse {
        let new = try makeLayers()
        layers = new
        tokens = []
        checkpoint = nil
        let position = checkpointAt.flatMap {
            Self.checkpointPosition($0, promptCount: promptCount, layers: new)
        }
        return Reuse(layers: new, reusedTokens: 0, checkpointAt: pending(position, from: 0))
    }

    /// The checkpoint still to capture at `position`, given that `reused` tokens are already
    /// in the cache (a snapshot can only be taken while prefilling across that position).
    private func pending(_ position: Int?, from reused: Int) -> Int? {
        guard let position, position >= reused, checkpoint?.length != position else { return nil }
        return position
    }

    /// Where to snapshot, or nil when the model needs no snapshots or the position is unusable.
    private static func checkpointPosition(
        _ position: Int, promptCount: Int, layers: [any KVCache]
    ) -> Int? {
        guard layers.contains(where: needsSnapshot), position > 0, position < promptCount else {
            return nil
        }
        return position
    }

    private static func needsSnapshot(_ layer: any KVCache) -> Bool {
        !(layer is KVCacheSimple || layer is QuantizedKVCache)
    }

    static func canRewindExactly(_ layer: any KVCache, by n: Int) -> Bool {
        switch layer {
        case let sliding as ReusableSlidingWindowCache:
            sliding.canRewindExactly(n)
        case is KVCacheSimple, is QuantizedKVCache:
            n <= layer.offset
        case let rotating as RotatingKVCache:
            // Exact until the ring wraps.
            rotating.isTrimmable && n <= rotating.offset
        default:
            n == 0
        }
    }

    static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        var i = 0
        let n = min(a.count, b.count)
        while i < n, a[i] == b[i] { i += 1 }
        return i
    }
}
