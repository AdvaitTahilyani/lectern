import Foundation
import LecternCore
import Synchronization
import Testing
@testable import LecternLLM

// MARK: - Fakes

/// A provider that answers with fixed usage and counts its calls.
private final class FakeProvider: LLMProvider, Sendable {
    let kind: ProviderKind
    let model: String
    let usage: LLMUsage?
    let calls = Mutex(0)

    init(kind: ProviderKind, model: String, usage: LLMUsage? = LLMUsage(inputTokens: 1_000, outputTokens: 100)) {
        self.kind = kind
        self.model = model
        self.usage = usage
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        calls.withLock { $0 += 1 }
        return LLMResponse(text: "\(model) says hi", usage: usage)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        calls.withLock { $0 += 1 }
        let usage = usage
        return AsyncThrowingStream { c in
            c.yield(.delta("hi"))
            c.yield(.done(usage))
            c.finish()
        }
    }

    func healthCheck() async throws {}
}

/// A settable clock for the ledger.
private final class Clock: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    var now: Date { value.withLock { $0 } }
    func set(_ date: Date) { value.withLock { $0 = date } }
}

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func date(_ iso: String) -> Date { try! Date(iso, strategy: .iso8601) }

private func temporaryLedgerURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "usage-\(UUID().uuidString)/usage.json")
}

private func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

// MARK: - Pricing

@Suite struct PricingTests {
    @Test func plainUsageIsInputPlusOutput() {
        let haiku = ProviderCatalog.pricing(for: .anthropic, model: "claude-haiku-4-5")   // $1 / $5
        #expect(!haiku.isEstimate)
        #expect(approx(haiku.cost(of: LLMUsage(inputTokens: 1_000_000, outputTokens: 0)), 1.00))
        #expect(approx(haiku.cost(of: LLMUsage(inputTokens: 2_000, outputTokens: 500)), 0.002 + 0.0025))
    }

    @Test func anthropicCacheReadsAreATenthAndWritesAQuarterMore() {
        let haiku = ProviderCatalog.pricing(for: .anthropic, model: "claude-haiku-4-5")
        // 10,000-token prompt: 8,000 read from cache, 1,500 written, 500 fresh; 200 out.
        let usage = LLMUsage(inputTokens: 10_000, outputTokens: 200, cachedInputTokens: 8_000, cacheWriteTokens: 1_500)
        let expected = (500 * 1.0 + 8_000 * 0.1 + 1_500 * 1.25) / 1_000_000 + 200 * 5.0 / 1_000_000
        #expect(approx(haiku.cost(of: usage), expected))
        #expect(haiku.cost(of: usage) < haiku.cost(of: LLMUsage(inputTokens: 10_000, outputTokens: 200)))
    }

    @Test func openAICachedInputIsDiscountedWithoutAWriteCharge() {
        let nano = ProviderCatalog.pricing(for: .openAI, model: "gpt-5.4-nano")   // $0.20 / $1.25
        #expect(nano.cachedInputMultiplier == 0.1 && nano.cacheWriteMultiplier == 1)
        let usage = LLMUsage(inputTokens: 10_000, outputTokens: 1_000, cachedInputTokens: 6_000)
        #expect(approx(nano.cost(of: usage), (4_000 * 0.20 + 6_000 * 0.02 + 1_000 * 1.25) / 1_000_000))
        // GPT-4.1 models discount cached input to a quarter, not a tenth.
        #expect(ProviderCatalog.pricing(for: .openAI, model: "gpt-4.1-mini").cachedInputMultiplier == 0.25)
    }

    @Test func onDeviceAndLocalServersAreFree() {
        let usage = LLMUsage(inputTokens: 50_000, outputTokens: 5_000)
        #expect(ProviderCatalog.pricing(for: .onDevice, model: AppSettings.defaultOnDeviceModel).cost(of: usage) == 0)
        #expect(ProviderCatalog.pricing(for: .localServer, model: "gemma4:12b").cost(of: usage) == 0)
    }

    @Test func snapshotsPriceAsTheirModelAndUnknownModelsAsTheDearest() {
        let snapshot = ProviderCatalog.pricing(for: .anthropic, model: "claude-haiku-4-5-20251001")
        #expect(snapshot == ProviderCatalog.pricing(for: .anthropic, model: "claude-haiku-4-5"))
        let unknown = ProviderCatalog.pricing(for: .openAI, model: "gpt-9-experimental")
        #expect(unknown.isEstimate)
        #expect(unknown.inputPerMTok == 2.00 && unknown.outputPerMTok == 10.00)   // GPT-6 Sol, the dearest listed
    }

    @Test func missingOrInconsistentCacheCountsNeverGoNegative() {
        let p = ModelPricing(inputPerMTok: 1, outputPerMTok: 1, cachedInputMultiplier: 0.1, cacheWriteMultiplier: 1.25)
        let odd = LLMUsage(inputTokens: 100, outputTokens: 0, cachedInputTokens: 150)
        #expect(p.cost(of: odd) >= 0)
    }
}

// MARK: - Ledger

@Suite struct UsageLedgerTests {
    @Test func recordsPerMonthPerModelAndPerSession() async throws {
        let clock = Clock(date("2026-09-15T12:00:00Z"))
        let ledger = UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc, now: { clock.now })
        let lecture = UUID()
        let usage = LLMUsage(inputTokens: 1_000_000, outputTokens: 0)
        #expect(approx(await ledger.record(provider: .anthropic, model: "claude-haiku-4-5", usage: usage, sessionID: lecture), 1))
        await ledger.record(provider: .anthropic, model: "claude-haiku-4-5", usage: usage, sessionID: lecture)
        await ledger.record(provider: .openAI, model: "gpt-5.4-nano", usage: usage)
        let month = await ledger.month()
        #expect(month.month == "2026-09")
        #expect(approx(month.totalUSD, 2.20))
        #expect(month.breakdown.map(\.model) == ["claude-haiku-4-5", "gpt-5.4-nano"])
        #expect(month.models["anthropic/claude-haiku-4-5"]?.totals.calls == 2)
        #expect(approx(await ledger.cost(forSession: lecture), 2))
        #expect(await ledger.cost(forSession: UUID()) == 0)
    }

    @Test func rollsOverAtTheMonthBoundaryAndKeepsHistory() async throws {
        let url = temporaryLedgerURL()
        let clock = Clock(date("2026-09-30T23:59:00Z"))
        let ledger = UsageLedger(fileURL: url, calendar: utc, now: { clock.now })
        let lecture = UUID()
        let usage = LLMUsage(inputTokens: 1_000_000, outputTokens: 0)
        await ledger.record(provider: .anthropic, model: "claude-haiku-4-5", usage: usage, sessionID: lecture)
        #expect(approx(await ledger.spentThisMonth(), 1))

        clock.set(date("2026-10-01T00:01:00Z"))
        #expect(await ledger.spentThisMonth() == 0)   // a new month starts empty
        await ledger.record(provider: .anthropic, model: "claude-haiku-4-5", usage: usage, sessionID: lecture)
        #expect(approx(await ledger.spentThisMonth(), 1))
        #expect(approx(await ledger.month(containing: date("2026-09-10T00:00:00Z")).totalUSD, 1))
        // A lecture that spans midnight keeps one total.
        #expect(approx(await ledger.cost(forSession: lecture), 2))

        // Persisted: a fresh ledger on the same file sees the same numbers.
        let reopened = UsageLedger(fileURL: url, calendar: utc, now: { clock.now })
        #expect(approx(await reopened.spentThisMonth(), 1))
        #expect(approx(await reopened.cost(forSession: lecture), 2))
        #expect(await reopened.month(containing: date("2026-09-10T00:00:00Z")).month == "2026-09")
    }

    @Test func monthKeysFollowTheCalendarTimeZone() {
        let instant = date("2026-10-01T03:00:00Z")   // still September 30 in Chicago
        var chicago = Calendar(identifier: .gregorian)
        chicago.timeZone = TimeZone(identifier: "America/Chicago")!
        #expect(UsageLedger.monthKey(for: instant, calendar: utc) == "2026-10")
        #expect(UsageLedger.monthKey(for: instant, calendar: chicago) == "2026-09")
    }

    @Test func capNoticeIsClaimedOncePerMonth() async {
        let clock = Clock(date("2026-09-15T12:00:00Z"))
        let url = temporaryLedgerURL()
        let ledger = UsageLedger(fileURL: url, calendar: utc, now: { clock.now })
        #expect(await ledger.claimCapNotice(capUSD: 5, fellBack: true))
        #expect(await !ledger.claimCapNotice(capUSD: 5, fellBack: true))
        #expect(await !UsageLedger(fileURL: url, calendar: utc, now: { clock.now }).claimCapNotice(capUSD: 5, fellBack: false))
        clock.set(date("2026-10-02T12:00:00Z"))
        #expect(await ledger.claimCapNotice(capUSD: 5, fellBack: true))
    }

    @Test func anUnreadableFileIsSetAsideNotFatal() async throws {
        let url = temporaryLedgerURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let ledger = UsageLedger(fileURL: url, calendar: utc)
        #expect(await ledger.spentThisMonth() == 0)
        await ledger.record(provider: .anthropic, model: "claude-haiku-4-5", usage: LLMUsage(inputTokens: 10, outputTokens: 1))
        #expect(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("unreadable.json").path))
        #expect(await ledger.saveError == nil)
    }
}

// MARK: - Metering and the cap

@Suite struct MeteredProviderTests {
    @Test func recordsCompleteAndStreamUsage() async throws {
        let ledger = UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc)
        let lecture = UUID()
        let base = FakeProvider(kind: .anthropic, model: "claude-haiku-4-5", usage: LLMUsage(inputTokens: 1_000_000, outputTokens: 0))
        let metered = MeteredProvider(base, ledger: ledger, sessionID: lecture)
        #expect(metered.kind == .anthropic && metered.model == "claude-haiku-4-5")
        _ = try await metered.complete(simpleRequest)
        let streamed = try await collect(metered.stream(simpleRequest))
        #expect(streamed.text == "hi")
        #expect(approx(await ledger.cost(forSession: lecture), 2))
        #expect(await ledger.month().models["anthropic/claude-haiku-4-5"]?.totals.calls == 2)
    }

    @Test func callsWithoutUsageAreBookedAsAnEstimateNotForFree() async throws {
        let ledger = UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc)
        let metered = MeteredProvider(FakeProvider(kind: .openAI, model: "gpt-5.4-nano", usage: nil), ledger: ledger)
        _ = try await metered.complete(simpleRequest)
        _ = try await collect(metered.stream(simpleRequest))
        let entry = try #require(await ledger.month().models["openAI/gpt-5.4-nano"])
        #expect(entry.totals.calls == 2)
        #expect(entry.isEstimate)
        #expect(entry.totals.inputTokens > 0 && entry.totals.costUSD > 0)
    }

    @Test(arguments: [
        (0.0, nil as Double?, true, SpendCapDecision.proceed),
        (9.99, 10.0, false, .proceed),
        (10.0, 10.0, true, .fallBack),
        (12.0, 10.0, false, .block),
        (50.0, 0.0, false, .proceed),   // a zero cap means no cap
    ])
    func capDecision(spent: Double, cap: Double?, fallback: Bool, expected: SpendCapDecision) {
        #expect(SpendCapDecision.decide(spentUSD: spent, capUSD: cap, fallbackAvailable: fallback) == expected)
    }

    @Test func overTheCapCloudCallsFallBackOnDevice() async throws {
        let ledger = UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc)
        let cloud = FakeProvider(kind: .anthropic, model: "claude-haiku-4-5", usage: LLMUsage(inputTokens: 1_000_000, outputTokens: 0))
        let onDevice = FakeProvider(kind: .onDevice, model: AppSettings.defaultOnDeviceModel, usage: nil)
        let notices = await ledger.capNotices()
        let provider = CappedProvider(MeteredProvider(cloud, ledger: ledger), ledger: ledger, cap: { 1.5 }, fallback: { onDevice })

        #expect(try await provider.complete(simpleRequest).text == "claude-haiku-4-5 says hi")   // $1 spent
        #expect(try await provider.complete(simpleRequest).text == "claude-haiku-4-5 says hi")   // $2: over the cap now
        #expect(try await provider.complete(simpleRequest).text.hasPrefix(AppSettings.defaultOnDeviceModel))
        _ = try await collect(provider.stream(simpleRequest))
        #expect(cloud.calls.withLock { $0 } == 2)
        #expect(onDevice.calls.withLock { $0 } == 2)
        #expect(approx(await ledger.spentThisMonth(), 2))   // on-device calls cost nothing

        var iterator = notices.makeAsyncIterator()
        #expect(await iterator.next() == CapNotice(capUSD: 1.5, fellBack: true))   // posted once
        #expect(await !ledger.claimCapNotice(capUSD: 1.5, fellBack: true))
    }

    @Test func overTheCapWithoutAnOnDeviceModelFailsClearly() async throws {
        let ledger = UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc)
        await ledger.record(provider: .openAI, model: "gpt-5.4-mini", usage: LLMUsage(inputTokens: 10_000_000, outputTokens: 0))   // $7.50
        let cloud = FakeProvider(kind: .openAI, model: "gpt-5.4-mini")
        let provider = CappedProvider(MeteredProvider(cloud, ledger: ledger), ledger: ledger, cap: { 5 }, fallback: { nil })
        await #expect(throws: MonthlyCapReached(capUSD: 5)) { try await provider.complete(simpleRequest) }
        await #expect(throws: MonthlyCapReached.self) { _ = try await collect(provider.stream(simpleRequest)) }
        #expect(cloud.calls.withLock { $0 } == 0)
        #expect(MonthlyCapReached(capUSD: 5).localizedDescription.contains("Settings › Models"))

        // Raising the cap (read on every call) lets calls through again.
        let raised = CappedProvider(MeteredProvider(cloud, ledger: ledger), ledger: ledger, cap: { 20 }, fallback: { nil })
        _ = try await raised.complete(simpleRequest)
        #expect(cloud.calls.withLock { $0 } == 1)
    }
}

// MARK: - Wire usage

@Suite struct CacheUsageWireTests {
    @Test func anthropicReportsCacheWrites() async throws {
        let server = StubServer()
        server.enqueue(.json(#"{"content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":40,"cache_creation_input_tokens":3000,"cache_read_input_tokens":0,"output_tokens":9}}"#))
        let response = try await AnthropicProvider(apiKey: "sk-ant-test", baseURL: server.baseURL, session: server.session, retryDelay: 0.01).complete(simpleRequest)
        #expect(response.usage == LLMUsage(inputTokens: 3040, outputTokens: 9, cachedInputTokens: 0, cacheWriteTokens: 3000))
    }

    @Test func openAIReportsCachedPromptTokens() async throws {
        let server = StubServer()
        server.enqueue(.json(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2048,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":1920}}}"#))
        let provider = OpenAICompatibleProvider.openAI(apiKey: "sk-test", model: "gpt-5.4-nano", baseURL: server.baseURL, session: server.session)
        let response = try await provider.complete(simpleRequest)
        #expect(response.usage == LLMUsage(inputTokens: 2048, outputTokens: 5, cachedInputTokens: 1920))
    }

    @Test func openAIStreamUsageCarriesCachedTokens() async throws {
        let server = StubServer()
        server.enqueue(.sse([
            sseData(#"{"choices":[{"delta":{"content":"ok"}}]}"#),
            sseData(#"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":64}}}"#),
            sseData("[DONE]"),
        ]))
        let provider = OpenAICompatibleProvider.openAI(apiKey: "sk-test", model: "gpt-5.4-nano", baseURL: server.baseURL, session: server.session)
        let result = try await collect(provider.stream(simpleRequest))
        #expect(result.usage == LLMUsage(inputTokens: 100, outputTokens: 2, cachedInputTokens: 64))
    }
}

// MARK: - Reservations, incomplete streams, ledger health

/// Holds callers until opened.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// A cloud provider whose calls take as long as the test lets them.
private final class SlowProvider: LLMProvider, Sendable {
    let kind: ProviderKind = .anthropic
    let model = "claude-haiku-4-5"
    let gate = Gate()
    let entered = Mutex(0)

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        entered.withLock { $0 += 1 }
        await gate.wait()
        return LLMResponse(text: "slow", usage: LLMUsage(inputTokens: 20, outputTokens: 10))
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                entered.withLock { $0 += 1 }
                await gate.wait()
                c.yield(.delta("slow"))
                c.yield(.done(LLMUsage(inputTokens: 20, outputTokens: 10)))
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
    func healthCheck() async throws {}
}

/// Streams some text, then fails or hangs.
private final class BrokenStream: LLMProvider, Sendable {
    enum Ending: Sendable { case fail(LLMError), hang }
    let kind: ProviderKind = .anthropic
    let model = "claude-haiku-4-5"
    let deltas: [String]
    let ending: Ending
    init(deltas: [String], ending: Ending) { self.deltas = deltas; self.ending = ending }

    func complete(_ request: LLMRequest) async throws -> LLMResponse { throw LLMError.network("unused") }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let (deltas, ending) = (deltas, ending)
        return AsyncThrowingStream { c in
            let task = Task {
                for d in deltas { c.yield(.delta(d)) }
                switch ending {
                case .fail(let error): c.finish(throwing: error)
                case .hang:
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    c.finish()
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
    func healthCheck() async throws {}
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<500 where !(await condition()) { try? await Task.sleep(for: .milliseconds(10)) }
}

@Suite struct CapReservationTests {
    // A 100-token Haiku call is estimated at about $0.0005 at most.
    private func capped(_ cloud: any LLMProvider, ledger: UsageLedger, cap: Double, onDevice: (any LLMProvider)?) -> CappedProvider {
        CappedProvider(MeteredProvider(cloud, ledger: ledger), ledger: ledger, cap: { cap }, fallback: { onDevice })
    }

    @Test func concurrentCallsShareTheBudgetInsteadOfAllPassingTheSameCheck() async throws {
        let ledger = UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc)
        let cloud = SlowProvider()
        let onDevice = FakeProvider(kind: .onDevice, model: AppSettings.defaultOnDeviceModel, usage: nil)
        let provider = capped(cloud, ledger: ledger, cap: 0.001, onDevice: onDevice)   // room for one call

        let calls = (0..<3).map { _ in Task { try await provider.complete(simpleRequest).text } }
        await waitUntil { onDevice.calls.withLock { $0 } == 2 }
        #expect(cloud.entered.withLock { $0 } == 1, "only one call fits under the cap")
        #expect(onDevice.calls.withLock { $0 } == 2)
        #expect(await ledger.reservedUSD() > 0)

        await cloud.gate.open()
        var texts: [String] = []
        for call in calls { texts.append(try await call.value) }
        #expect(texts.filter { $0 == "slow" }.count == 1)
        #expect(await ledger.reservedUSD() == 0, "holds end with the calls")
        #expect(await ledger.spentThisMonth() < 0.001)
    }

    @Test func aSingleCallThatCouldCrossTheCapIsNotLetThrough() async throws {
        let ledger = UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc)
        let cloud = FakeProvider(kind: .anthropic, model: "claude-haiku-4-5")
        let onDevice = FakeProvider(kind: .onDevice, model: AppSettings.defaultOnDeviceModel, usage: nil)
        let big = LLMRequest(messages: [.user("Hi")], maxTokens: 100_000)   // up to $0.50 of output
        _ = try await capped(cloud, ledger: ledger, cap: 0.10, onDevice: onDevice).complete(big)
        #expect(cloud.calls.withLock { $0 } == 0)
        #expect(onDevice.calls.withLock { $0 } == 1)
        await #expect(throws: MonthlyCapReached.self) { _ = try await capped(cloud, ledger: ledger, cap: 0.10, onDevice: nil).complete(big) }
        #expect(await ledger.reservedUSD() == 0)
    }

    @Test func holdsAreReleasedWhenACallFailsOrIsCancelled() async throws {
        let ledger = UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc)
        let failing = capped(BrokenStream(deltas: [], ending: .fail(.http(status: 500, message: "boom"))), ledger: ledger, cap: 1, onDevice: nil)
        await #expect(throws: LLMError.self) { _ = try await collect(failing.stream(simpleRequest)) }
        #expect(await ledger.reservedUSD() == 0)

        let slow = SlowProvider()
        let hanging = capped(slow, ledger: ledger, cap: 1, onDevice: nil)
        let call = Task { try await hanging.complete(simpleRequest) }
        await waitUntil { slow.entered.withLock { $0 } == 1 }
        #expect(await ledger.reservedUSD() > 0)
        await slow.gate.open()
        _ = try await call.value
        #expect(await ledger.reservedUSD() == 0)
    }

    @Test func staleHoldsStopCounting() async throws {
        let clock = Clock(date("2026-09-15T12:00:00Z"))
        let ledger = UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc, now: { clock.now })
        _ = try #require(await ledger.reserve(estimatedUSD: 0.5, withinCapUSD: 1))
        #expect(await ledger.reserve(estimatedUSD: 0.6, withinCapUSD: 1) == nil)
        clock.set(date("2026-09-15T12:20:00Z"))
        #expect(await ledger.reservedUSD() == 0)
        #expect(await ledger.reserve(estimatedUSD: 0.6, withinCapUSD: 1) != nil)
    }
}

@Suite struct IncompleteUsageTests {
    private func entry(_ ledger: UsageLedger) async -> ModelUsage? { await ledger.month().models["anthropic/claude-haiku-4-5"] }

    @Test func aStreamCancelledAfterSomeTextIsBookedAsAnEstimate() async throws {
        let ledger = UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc)
        let metered = MeteredProvider(BrokenStream(deltas: ["partial answer"], ending: .hang), ledger: ledger)
        let reader = Task {
            for try await event in metered.stream(simpleRequest) {
                if case .delta = event { return }
            }
        }
        _ = try await reader.value   // got the first text; now walk away
        await waitUntil { await entry(ledger) != nil }
        let booked = try #require(await entry(ledger))
        #expect(booked.totals.calls == 1)
        #expect(booked.isEstimate)
        #expect(booked.totals.inputTokens > 0 && booked.totals.outputTokens > 0 && booked.totals.costUSD > 0)
    }

    @Test func aStreamThatBreaksAfterTextIsBookedButARejectedRequestIsNot() async throws {
        let ledger = UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc)
        let broken = MeteredProvider(BrokenStream(deltas: ["some ", "text"], ending: .fail(.network("connection lost"))), ledger: ledger)
        await #expect(throws: LLMError.self) { for try await _ in broken.stream(simpleRequest) {} }
        let booked = try #require(await entry(ledger))
        #expect(booked.totals.calls == 1 && booked.isEstimate)

        let rejected = MeteredProvider(BrokenStream(deltas: [], ending: .fail(.http(status: 401, message: "bad key"))), ledger: UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc))
        await #expect(throws: LLMError.self) { for try await _ in rejected.stream(simpleRequest) {} }
        #expect(await rejected.ledger.month().models.isEmpty, "a request the server refused cost nothing")
    }

    @Test func actualUsageIsNeverMarkedAsEstimated() async throws {
        let ledger = UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc)
        _ = try await MeteredProvider(FakeProvider(kind: .anthropic, model: "claude-haiku-4-5"), ledger: ledger).complete(simpleRequest)
        #expect(await entry(ledger)?.isEstimate == false)
    }
}

@Suite struct LedgerHealthTests {
    @Test func aDamagedFileIsReportedNotSilentlyForgotten() async throws {
        let url = temporaryLedgerURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: url)
        let ledger = UsageLedger(fileURL: url, calendar: utc)
        #expect(await ledger.storageProblem()?.contains("damaged") == true)
        #expect(await UsageLedger(fileURL: temporaryLedgerURL(), calendar: utc).storageProblem() == nil)
    }

    @Test func anUnreadableFileIsNeverOverwritten() async throws {
        let url = temporaryLedgerURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try JSONEncoder().encode(["version": 1])
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

        let ledger = UsageLedger(fileURL: url, calendar: utc)
        await ledger.record(provider: .anthropic, model: "claude-haiku-4-5", usage: LLMUsage(inputTokens: 10, outputTokens: 1))
        #expect(await ledger.storageProblem() != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func aFailedSaveIsReported() async throws {
        let blocker = FileManager.default.temporaryDirectory.appending(path: "usage-blocker-\(UUID().uuidString)")
        try Data().write(to: blocker)   // a file where the ledger's folder should be
        let ledger = UsageLedger(fileURL: blocker.appending(path: "usage.json"), calendar: utc)
        await ledger.record(provider: .anthropic, model: "claude-haiku-4-5", usage: LLMUsage(inputTokens: 10, outputTokens: 1))
        #expect(await ledger.storageProblem() != nil)
        #expect(await ledger.spentThisMonth() > 0, "usage is still counted in memory")
    }
}
