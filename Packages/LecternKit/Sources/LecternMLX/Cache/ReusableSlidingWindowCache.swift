import MLX
import MLXLMCommon

/// A sliding-window attention cache that can be rewound exactly.
///
/// Models such as Gemma 4 use a ring buffer (`RotatingKVCache`) for their sliding-window
/// layers. A ring overwrites the oldest rows, so once it wraps it can no longer be rewound:
/// dropping the last `n` positions would need rows that are already gone. That breaks
/// prompt-prefix reuse, because every call ends with a changing instruction (and generated
/// tokens) that must be removed before the next call's suffix is appended.
///
/// This cache keeps rows in temporal order and retains `slack` rows beyond the attention
/// window, so a rewind of up to `slack` positions is exact. `update` only hands attention the
/// last `window - 1` retained rows plus the new ones, and `makeMask` builds the matching
/// sliding-window mask, so attention results are identical to the ring buffer.
///
/// Memory: `(window - 1 + slack)` rows per layer instead of `window`.
///
/// Masks come from ``makeMask(n:windowSize:returnArray:)``, so it suits models that build
/// sliding-window masks through `createAttentionMask(h:cache:windowSize:)` (Gemma 3/4 and
/// most current ports). Not thread-safe; used only on the owning engine's executor.
final class ReusableSlidingWindowCache: KVCache, CustomDebugStringConvertible {
    /// Attention window of the layer (a query attends to the previous `window - 1` positions).
    let window: Int
    /// Rows retained beyond the window; bounds how far the cache can be rewound exactly.
    let slack: Int

    private var keys: MLXArray?
    private var values: MLXArray?
    /// Number of live rows at the front of the buffers. They hold positions
    /// `offset - rows ..< offset` in temporal order.
    private var rows = 0
    /// Buffer growth granularity, in rows.
    private let step: Int

    private var retainedCapacity: Int { window - 1 + slack }

    /// Logical position: number of tokens this cache has seen.
    private(set) var offset = 0

    /// No fixed capacity is exposed; windowing is handled by ``makeMask(n:windowSize:returnArray:)``.
    var maxSize: Int? { nil }

    init(window: Int, slack: Int, step: Int = 256) {
        precondition(window > 1, "window must be > 1")
        precondition(slack >= 0, "slack must be >= 0")
        precondition(step > 0, "step must be > 0")
        self.window = window
        self.slack = slack
        self.step = step
    }

    func innerState() -> [MLXArray] {
        [keys, values].compactMap { $0 }
    }

    /// Rows that precede newly appended positions in the attention span.
    private var contextRows: Int { min(rows, window - 1) }

    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let n = newKeys.dim(2)
        let context = contextRows
        reserve(additional: n, like: newKeys, newValues)

        keys![.ellipsis, rows ..< rows + n, 0...] = newKeys
        values![.ellipsis, rows ..< rows + n, 0...] = newValues
        rows += n
        offset += n

        let start = rows - n - context
        return (
            keys![.ellipsis, start ..< rows, 0...],
            values![.ellipsis, start ..< rows, 0...]
        )
    }

    /// Ensures room for `additional` rows, compacting to the retained capacity when needed.
    private func reserve(additional n: Int, like k: MLXArray, _ v: MLXArray) {
        if let keys, rows + n <= keys.dim(2) { return }

        let keep = min(rows, retainedCapacity)
        // At least `step` spare rows: an exact fit would make a saturated cache (window + slack a
        // multiple of `step`) reallocate and copy every layer's rows on every decoded token.
        let size = ((keep + n + step - 1) / step + 1) * step
        let (b, heads, kDim, vDim) = (k.dim(0), k.dim(1), k.dim(3), v.dim(3))
        let freshK = MLXArray.zeros([b, heads, size - keep, kDim], dtype: k.dtype)
        let freshV = MLXArray.zeros([b, heads, size - keep, vDim], dtype: v.dtype)

        if let keys, let values, keep > 0 {
            self.keys = concatenated([keys[.ellipsis, (rows - keep) ..< rows, 0...], freshK], axis: 2)
            self.values = concatenated(
                [values[.ellipsis, (rows - keep) ..< rows, 0...], freshV], axis: 2)
        } else {
            self.keys = freshK
            self.values = freshV
        }
        rows = keep
    }

    func makeMask(
        n: Int, windowSize: Int?, returnArray: Bool
    ) -> MLXFast.ScaledDotProductAttentionMaskMode {
        let windowSize = windowSize ?? window
        let context = contextRows
        if n == 1 && !returnArray {
            // At most `window - 1` context rows are returned, so every key is visible.
            return .none
        }
        if returnArray || context + n > windowSize {
            return .array(createCausalMask(n: n, offset: context, windowSize: windowSize))
        }
        return .causal
    }

    /// Whether rewinding `n` positions restores exactly the state the cache had then.
    func canRewindExactly(_ n: Int) -> Bool {
        guard n >= 0, n <= offset else { return false }
        return rows - n >= min(offset - n, window - 1)
    }

    /// Trims are always consistent; use ``canRewindExactly(_:)`` to check exactness.
    var isTrimmable: Bool { true }

    /// Rewinds the newest `n` positions (bounded by the retained rows). Exact when
    /// ``canRewindExactly(_:)`` holds; otherwise the window is short until it refills.
    @discardableResult
    func trim(_ n: Int) -> Int {
        let trimmed = min(max(n, 0), rows)
        rows -= trimmed
        offset -= trimmed
        return trimmed
    }

    var state: [MLXArray] {
        get {
            guard let keys, let values else { return [] }
            return [keys[.ellipsis, ..<rows, 0...], values[.ellipsis, ..<rows, 0...]]
        }
        set {
            precondition(newValue.count == 2, "ReusableSlidingWindowCache state is [keys, values]")
            keys = newValue[0]
            values = newValue[1]
            rows = newValue[0].dim(2)
        }
    }

    var metaState: [String] {
        get { [String(window), String(slack), String(offset), String(rows)] }
        set {
            precondition(newValue.count == 4, "ReusableSlidingWindowCache metaState has 4 values")
            guard let restoredOffset = Int(newValue[2]), let restoredRows = Int(newValue[3]) else {
                preconditionFailure("Malformed ReusableSlidingWindowCache metaState")
            }
            offset = restoredOffset
            rows = restoredRows
        }
    }

    func copy() -> any KVCache {
        let new = ReusableSlidingWindowCache(window: window, slack: slack, step: step)
        let s = state
        if !s.isEmpty {
            new.state = s.map { $0[.ellipsis] }
        }
        new.offset = offset
        return new
    }

    /// A compact copy holding only the rows attention still needs (the last `window - 1`), for
    /// prefix snapshots: ~window rows instead of the whole retained slack.
    func snapshot() -> ReusableSlidingWindowCache {
        let new = ReusableSlidingWindowCache(window: window, slack: slack, step: step)
        if let keys, let values, rows > 0 {
            let keep = contextRows
            // `contiguous` materializes the rows so the snapshot does not pin the big buffer.
            new.keys = contiguous(keys[.ellipsis, (rows - keep) ..< rows, 0...])
            new.values = contiguous(values[.ellipsis, (rows - keep) ..< rows, 0...])
            new.rows = keep
        }
        new.offset = offset
        return new
    }

    var debugDescription: String {
        "ReusableSlidingWindowCache window: \(window) slack: \(slack) offset: \(offset) rows: \(rows)"
    }
}
