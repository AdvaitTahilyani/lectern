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
        let response: LLMResponse
        do {
            response = try await base.complete(request)
        } catch {
            // A call cancelled mid-flight was probably billed for its prompt; one that failed was not.
            if Self.isCancellation(error) { await recordEstimate(for: request, outputBytes: 0) }
            throw error
        }
        if let usage = response.usage {
            await ledger.record(provider: kind, model: model, usage: usage, sessionID: sessionID)
        } else {
            // The provider reported nothing: count an estimate rather than a free call.
            await recordEstimate(for: request, outputBytes: response.text.utf8.count)
        }
        return response
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let metered = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                var outputBytes = 0
                var recorded = false
                do {
                    for try await event in metered.base.stream(request) {
                        switch event {
                        case .delta(let text):
                            outputBytes += text.utf8.count
                        case .done(let usage):
                            if let usage {
                                await metered.ledger.record(provider: metered.kind, model: metered.model, usage: usage, sessionID: metered.sessionID)
                            } else {
                                await metered.recordEstimate(for: request, outputBytes: outputBytes)
                            }
                            recorded = true
                        }
                        continuation.yield(event)
                    }
                    // Ended without `.done` (the consumer cancelled and the stream wound down quietly).
                    if !recorded, outputBytes > 0 || Task.isCancelled {
                        await metered.recordEstimate(for: request, outputBytes: outputBytes)
                    }
                    continuation.finish()
                } catch {
                    // Cancelled, or failed after text arrived: the provider ran and billed for it.
                    // A failure before any text (bad key, rate limit, no network) is not billed.
                    if !recorded, outputBytes > 0 || Self.isCancellation(error) || Task.isCancelled {
                        await metered.recordEstimate(for: request, outputBytes: outputBytes)
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func recordEstimate(for request: LLMRequest, outputBytes: Int) async {
        let usage = ProviderCatalog.pricing(for: kind, model: model).estimatedUsage(of: request, outputBytes: outputBytes)
        await ledger.record(provider: kind, model: model, usage: usage, sessionID: sessionID, isEstimate: true)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let llm = error as? LLMError, llm == .cancelled { return true }
        return (error as? URLError)?.code == .cancelled
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
    ///
    /// `spentUSD` is what is already spent or held by calls in flight. With `estimateUSD`, a call that
    /// could take the total past the cap is stopped too, so the cap is a maximum, not a threshold.
    public static func decide(spentUSD: Double, capUSD: Double?, estimateUSD: Double = 0, fallbackAvailable: Bool) -> SpendCapDecision {
        guard let capUSD, capUSD > 0, spentUSD >= capUSD || spentUSD + max(0, estimateUSD) > capUSD else { return .proceed }
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

    /// The provider this call should use, and the hold on the cap it must release when it ends.
    /// Spending, other calls' holds and this call's worst-case cost must all fit under the cap.
    func route(for request: LLMRequest) async throws -> (provider: any LLMProvider, reservation: UUID?) {
        guard let capUSD = cap(), capUSD > 0 else { return (base, nil) }
        let estimate = ProviderCatalog.pricing(for: base.kind, model: base.model).estimatedMaximumCost(of: request)
        if let reservation = await ledger.reserve(estimatedUSD: estimate, withinCapUSD: capUSD) {
            return (base, reservation)
        }
        let onDevice = fallback()
        if let onDevice {
            await ledger.claimCapNotice(capUSD: capUSD, fellBack: true)
            return (onDevice, nil)
        }
        await ledger.claimCapNotice(capUSD: capUSD, fellBack: false)
        throw MonthlyCapReached(capUSD: capUSD)
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let (provider, reservation) = try await route(for: request)
        do {
            let response = try await provider.complete(request)
            await release(reservation)
            return response
        } catch {
            await release(reservation)
            throw error
        }
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let guarded = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                var reservation: UUID?
                do {
                    let routed = try await guarded.route(for: request)
                    reservation = routed.reservation
                    for try await event in routed.provider.stream(request) { continuation.yield(event) }
                    await guarded.release(reservation)
                    continuation.finish()
                } catch {
                    await guarded.release(reservation)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Ends the hold. The metered provider has already booked the call by now, so spending and
    /// holds never both miss it.
    private func release(_ reservation: UUID?) async {
        if let reservation { await ledger.release(reservation) }
    }

    public func healthCheck() async throws { try await base.healthCheck() }
}
