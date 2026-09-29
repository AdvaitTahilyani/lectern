import Foundation

/// Errors thrown by `LectureBrain`'s user-initiated calls. Background work (rolling takeaways,
/// quiz pings) reports failures as `BrainUpdate.error` instead.
public enum BrainError: Error, LocalizedError, Sendable, Hashable {
    /// The model's reply couldn't be used even after one repair attempt.
    case unusableReply(String)
    /// `expand(takeawayID:)` was called with an unknown takeaway.
    case unknownTakeaway
    /// There isn't enough lecture material yet to write a question about.
    case nothingToQuiz
    /// The quiz answer couldn't be matched to an option or was empty.
    case invalidAnswer

    public var errorDescription: String? {
        switch self {
        case .unusableReply(let detail): "The model's reply couldn't be read (\(detail)). Try again, or pick a different model in Settings › Models."
        case .unknownTakeaway: "That takeaway no longer exists."
        case .nothingToQuiz: "Not enough of the lecture yet to ask about."
        case .invalidAnswer: "Choose an option or type an answer first."
        }
    }
}

extension Error {
    /// Human-readable description for `BrainUpdate.error` and thrown errors.
    var brainMessage: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}
