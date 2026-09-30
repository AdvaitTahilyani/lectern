import Foundation
import LecternCore

/// Wraps a provider and records each call's usage (and so its cost) in a `UsageLedger`,
/// attributed to a session when one is given. Health checks aren't metered.
public struct MeteredProvider: LLMProvider {
    public let base: any LLMProvider
    public let ledger: UsageLedger
    public let sessionID: UUID?

    public init(_ base: any LLMProvider, ledger: UsageLedger, sessionID: UUID? = nil) {
        self.base = base
        self.ledger = ledger
        self.sessionID = sessionID
    }

    public var kind: ProviderKind { base.kind }
    public var model: String { base.model }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let response = try await base.complete(request)
        if let usage = response.usage { await ledger.record(provider: kind, model: model, usage: usage, sessionID: sessionID) }
        return response
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let (base, ledger, sessionID) = (base, ledger, sessionID)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in base.stream(request) {
                        if case .done(let usage?) = event {
                            await ledger.record(provider: base.kind, model: base.model, usage: usage, sessionID: sessionID)
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func healthCheck() async throws { try await base.healthCheck() }
}

// MARK: - Monthly cap

/// What to do with a cloud call given this month's spend and the user's cap.
public enum SpendCapDecision: Sendable, Hashable {
    /// Under the cap (or no cap): call the cloud provider.
    case proceed
    /// At or over the cap: use the on-device model instead.
    case fallBack
    /// At or over the cap and no on-device model is downloaded: fail with `MonthlyCapReached`.
    case block

    /// A missing, zero or negative cap means no cap.
    public static func decide(spentUSD: Double, capUSD: Double?, fallbackAvailable: Bool) -> SpendCapDecision {
        guard let capUSD, capUSD > 0, spentUSD >= capUSD else { return .proceed }
        return fallbackAvailable ? .fallBack : .block
    }
}

/// Thrown for cloud calls once the monthly cap is reached and there's no on-device model to use.
public struct MonthlyCapReached: LocalizedError, Sendable, Hashable {
    public var capUSD: Double
    public init(capUSD: Double) { self.capUSD = capUSD }

    public var errorDescription: String? {
        "This month's cloud spending cap (\(capUSD.formatted(.currency(code: "USD")))) is reached. Raise it in Settings › Models, or download the on-device model to keep going."
    }
}

/// Guards a (metered) cloud provider with the monthly cap: once this month's spend reaches it,
/// calls go to the on-device fallback, or fail with `MonthlyCapReached` when there is none.
/// The first capped call of a month asks the ledger to post the one-time notice.
public struct CappedProvider: LLMProvider {
    public let base: any LLMProvider
    public let ledger: UsageLedger
    /// Current cap in US dollars, read on every call so a Settings change applies immediately.
    public let cap: @Sendable () -> Double?
    /// The on-device provider to use over the cap, or nil when none is downloaded.
    public let fallback: @Sendable () -> (any LLMProvider)?

    public init(_ base: any LLMProvider, ledger: UsageLedger, cap: @escaping @Sendable () -> Double?, fallback: @escaping @Sendable () -> (any LLMProvider)?) {
        self.base = base
        self.ledger = ledger
        self.cap = cap
        self.fallback = fallback
    }

    public var kind: ProviderKind { base.kind }
    public var model: String { base.model }

    /// The provider this call should use.
    func route() async throws -> any LLMProvider {
        guard let capUSD = cap(), capUSD > 0 else { return base }
        let spent = await ledger.spentThisMonth()
        guard spent >= capUSD else { return base }
        let onDevice = fallback()
        switch SpendCapDecision.decide(spentUSD: spent, capUSD: capUSD, fallbackAvailable: onDevice != nil) {
        case .proceed:
            return base
        case .fallBack:
            await ledger.claimCapNotice(capUSD: capUSD, fellBack: true)
            return onDevice ?? base
        case .block:
            await ledger.claimCapNotice(capUSD: capUSD, fellBack: false)
            throw MonthlyCapReached(capUSD: capUSD)
        }
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try await route().complete(request)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let guarded = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in try await guarded.route().stream(request) { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func healthCheck() async throws { try await base.healthCheck() }
}
