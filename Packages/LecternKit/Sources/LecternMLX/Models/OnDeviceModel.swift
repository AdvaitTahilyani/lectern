import Foundation
import LecternCore

/// A curated on-device model Lectern knows how to run with MLX.
public struct OnDeviceModel: Sendable, Hashable, Identifiable {
    /// Where the model sits in the picker.
    public enum Tier: String, Sendable, Hashable, CaseIterable {
        /// The default: best faithfulness and instruction following for its speed.
        case recommended
        /// Stronger reasoning, needs noticeably more memory.
        case reasoning
        /// Smaller download and footprint for tight memory.
        case light
    }

    /// Hugging Face repository id, e.g. "mlx-community/gemma-4-26B-A4B-it-qat-4bit".
    public let id: String
    public let displayName: String
    /// One-line description for Settings › Models.
    public let summary: String
    public let tier: Tier
    /// Approximate download size in bytes (used before the exact size is known).
    public let approximateDownloadBytes: Int64
    /// Approximate resident memory while loaded, including a typical lecture-length KV cache.
    public let approximateResidentBytes: Int64

    public init(
        id: String, displayName: String, summary: String, tier: Tier,
        approximateDownloadBytes: Int64, approximateResidentBytes: Int64
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.tier = tier
        self.approximateDownloadBytes = approximateDownloadBytes
        self.approximateResidentBytes = approximateResidentBytes
    }
}

extension OnDeviceModel {
    private static let gigabyte: Int64 = 1_000_000_000

    /// Gemma 4 26B-A4B (MoE, 3.8B active), QAT 4-bit. Lectern's default.
    public static let gemma4_26B_A4B = OnDeviceModel(
        id: AppSettings.defaultOnDeviceModel,
        displayName: "Gemma 4 26B-A4B",
        summary: "Recommended. Most faithful summaries; fast on Apple silicon.",
        tier: .recommended,
        approximateDownloadBytes: 15_641_239_295,
        approximateResidentBytes: 17 * gigabyte)

    /// Qwen3.6 35B-A3B (MoE, 3B active), 4-bit. Stronger reasoning, tighter on 32 GB Macs.
    public static let qwen36_35B_A3B = OnDeviceModel(
        id: "mlx-community/Qwen3.6-35B-A3B-4bit",
        displayName: "Qwen3.6 35B-A3B",
        summary: "Stronger reasoning for grading. Needs about 22 GB of free memory.",
        tier: .reasoning,
        approximateDownloadBytes: 20_429_166_969,
        approximateResidentBytes: 21 * gigabyte)

    /// Qwen3.5 9B (dense), 4-bit. Small footprint.
    public static let qwen35_9B = OnDeviceModel(
        id: "mlx-community/Qwen3.5-9B-MLX-4bit",
        displayName: "Qwen3.5 9B",
        summary: "Lighter download and memory use; a little slower to respond.",
        tier: .light,
        approximateDownloadBytes: 5_977_071_067,
        approximateResidentBytes: 7 * gigabyte)

    /// Models offered in Settings › Models, default first.
    public static let curated: [OnDeviceModel] = [gemma4_26B_A4B, qwen36_35B_A3B, qwen35_9B]

    /// The curated entry for `id`, if any.
    public static func curated(id: String) -> OnDeviceModel? {
        curated.first { $0.id == id }
    }
}
