import Foundation
import LecternCore
import OSLog

/// Token counts and dollar cost accumulated over a set of calls.
public struct UsageTotals: Codable, Sendable, Hashable {
    public var calls = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var cachedInputTokens = 0
    public var cacheWriteTokens = 0
    public var costUSD = 0.0

    public init() {}

    mutating func add(_ usage: LLMUsage, cost: Double) {
        calls += 1
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        cachedInputTokens += usage.cachedInputTokens ?? 0
        cacheWriteTokens += usage.cacheWriteTokens ?? 0
        costUSD += cost
    }
}

/// One provider/model's usage within a month.
public struct ModelUsage: Codable, Sendable, Hashable {
    public var provider: ProviderKind
    public var model: String
    public var totals: UsageTotals
    /// Some calls were priced with an estimate (the model wasn't in the price list).
    public var isEstimate: Bool
}

/// One calendar month of usage, keyed "provider/model".
public struct MonthUsage: Codable, Sendable, Hashable {
    /// "2026-09".
    public var month: String
    public var models: [String: ModelUsage] = [:]

    public var totalUSD: Double { models.values.reduce(0) { $0 + $1.totals.costUSD } }
    /// Largest spend first.
    public var breakdown: [ModelUsage] { models.values.sorted { ($0.totals.costUSD, $0.model) > ($1.totals.costUSD, $1.model) } }
}

/// Everything the ledger persists.
struct LedgerFile: Codable {
    var version = 1
    var months: [String: MonthUsage] = [:]
    /// Keyed by session UUID string.
    var sessions: [String: SessionUsage] = [:]
    /// Months ("2026-09") in which the cap notice was already shown.
    var capNoticeMonths: Set<String> = []
}

struct SessionUsage: Codable {
    var totals = UsageTotals()
    var lastUsed: Date
}

/// The monthly cap stopped cloud calls: they now run on-device (`fellBack`) or fail.
public struct CapNotice: Sendable, Hashable {
    public var capUSD: Double
    public var fellBack: Bool
}

/// Records every metered cloud call's usage and cost: per calendar month, per provider/model,
/// with per-session totals. Persisted as JSON (Application Support/Lectern/usage.json by default).
public actor UsageLedger {
    public static let defaultURL = URL.applicationSupportDirectory.appending(path: "Lectern/usage.json")
    /// Per-session totals older than this are dropped when the ledger loads.
    static let sessionRetention: TimeInterval = 400 * 86_400

    private let fileURL: URL
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private var file: LedgerFile?
    private var changeListeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var noticeListeners: [UUID: AsyncStream<CapNotice>.Continuation] = [:]
    /// The last save failure, if the most recent save failed (usage is still kept in memory).
    public private(set) var saveError: String?
    /// Set when the file on disk couldn't be used when the ledger loaded: its history is missing
    /// from the totals (a damaged file is set aside, an unreadable one is left alone and never overwritten).
    public private(set) var loadProblem: String?
    private var isReadOnly = false
    /// Estimated cost of calls in flight, so concurrent calls can't all pass a cap check before any
    /// of them is recorded.
    private var reservations: [UUID: (usd: Double, since: Date)] = [:]
    /// A reservation whose call never reported back (a bug, not a slow call) stops counting after this.
    static let reservationLifetime: TimeInterval = 15 * 60

    private static let logger = Logger(subsystem: "app.lectern", category: "usage")

    public init(fileURL: URL = UsageLedger.defaultURL, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.calendar = calendar
        self.now = now
    }

    // MARK: Recording

    /// Adds one call; returns its cost in US dollars. `isEstimate` marks usage that was worked out
    /// locally because the provider reported none (a cancelled or failed stream).
    @discardableResult
    public func record(provider: ProviderKind, model: String, usage: LLMUsage, sessionID: UUID? = nil, isEstimate: Bool = false) -> Double {
        let pricing = ProviderCatalog.pricing(for: provider, model: model)
        let cost = pricing.cost(of: usage)
        let date = now()
        let month = Self.monthKey(for: date, calendar: calendar)
        var f = loaded()
        let key = "\(provider.rawValue)/\(model)"
        var entry = f.months[month, default: MonthUsage(month: month)].models[key]
            ?? ModelUsage(provider: provider, model: model, totals: UsageTotals(), isEstimate: false)
        entry.totals.add(usage, cost: cost)
        entry.isEstimate = entry.isEstimate || pricing.isEstimate || isEstimate
        f.months[month, default: MonthUsage(month: month)].models[key] = entry
        if let sessionID {
            var s = f.sessions[sessionID.uuidString] ?? SessionUsage(lastUsed: date)
            s.totals.add(usage, cost: cost)
            s.lastUsed = date
            f.sessions[sessionID.uuidString] = s
        }
        file = f
        save()
        for listener in changeListeners.values { listener.yield() }
        return cost
    }

    // MARK: Reading

    /// Usage in the month containing `date` (default: now). A new month starts empty.
    public func month(containing date: Date? = nil) -> MonthUsage {
        let key = Self.monthKey(for: date ?? now(), calendar: calendar)
        return loaded().months[key] ?? MonthUsage(month: key)
    }

    /// Dollars spent so far this calendar month.
    public func spentThisMonth() -> Double { month().totalUSD }

    /// Dollars attributed to one session (lecture).
    public func cost(forSession id: UUID) -> Double { loaded().sessions[id.uuidString]?.totals.costUSD ?? 0 }

    // MARK: Reservations

    /// Holds `estimatedUSD` against the monthly cap while a call is in flight. Returns nil, holding
    /// nothing, when what's already spent or held plus this call could pass `capUSD`. The check and
    /// the hold are one step, so concurrent calls from any role or lecture share the same budget.
    public func reserve(estimatedUSD: Double, withinCapUSD capUSD: Double) -> UUID? {
        let committed = month().totalUSD + reservedUSD()
        guard SpendCapDecision.decide(spentUSD: committed, capUSD: capUSD, estimateUSD: estimatedUSD, fallbackAvailable: true) == .proceed else { return nil }
        let id = UUID()
        reservations[id] = (max(0, estimatedUSD), now())
        return id
    }

    /// Ends a hold once the call has been recorded (or has ended without a cost).
    public func release(_ reservation: UUID) { reservations[reservation] = nil }

    /// Total of the holds still in flight.
    public func reservedUSD() -> Double {
        let cutoff = now().addingTimeInterval(-Self.reservationLifetime)
        reservations = reservations.filter { $0.value.since >= cutoff }
        return reservations.values.reduce(0) { $0 + $1.usd }
    }

    // MARK: Health

    /// A one-line description of anything wrong with the ledger's storage, or nil when it is healthy:
    /// the totals may be incomplete, or this session's usage isn't being saved.
    public func storageProblem() -> String? {
        _ = loaded()
        return saveError ?? loadProblem
    }

    // MARK: Cap notice

    /// Called when the cap stops a cloud call. Returns true (and tells `capNotices()` listeners)
    /// only the first time in a calendar month.
    @discardableResult
    public func claimCapNotice(capUSD: Double, fellBack: Bool) -> Bool {
        let month = Self.monthKey(for: now(), calendar: calendar)
        var f = loaded()
        guard f.capNoticeMonths.insert(month).inserted else { return false }
        file = f
        save()
        for listener in noticeListeners.values { listener.yield(CapNotice(capUSD: capUSD, fellBack: fellBack)) }
        return true
    }

    // MARK: Observation

    /// Emits once now and again after every recorded call.
    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        changeListeners[id] = continuation
        continuation.yield()
        continuation.onTermination = { [weak self] _ in Task { await self?.removeChangeListener(id) } }
        return stream
    }

    /// Emits each month's first cap notice.
    public func capNotices() -> AsyncStream<CapNotice> {
        let (stream, continuation) = AsyncStream.makeStream(of: CapNotice.self)
        let id = UUID()
        noticeListeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeNoticeListener(id) } }
        return stream
    }

    private func removeChangeListener(_ id: UUID) { changeListeners[id] = nil }
    private func removeNoticeListener(_ id: UUID) { noticeListeners[id] = nil }

    // MARK: Months

    /// "2026-09" for any date in September 2026, in `calendar`'s time zone.
    public static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    // MARK: Persistence

    private func loaded() -> LedgerFile {
        if let file { return file }
        var f = LedgerFile()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                do {
                    f = try JSONDecoder.ledger.decode(LedgerFile.self, from: data)
                } catch {
                    // Keep the unreadable file for inspection rather than overwriting it.
                    let aside = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
                    try? FileManager.default.removeItem(at: aside)
                    try? FileManager.default.moveItem(at: fileURL, to: aside)
                    loadProblem = "The usage history file was damaged and set aside, so earlier spending isn't counted."
                    Self.logger.error("usage.json was unreadable (\(error.localizedDescription, privacy: .public)); moved aside and starting fresh")
                }
            } catch {
                // Present but can't be read (permissions, I/O): don't write over it.
                isReadOnly = true
                loadProblem = "The usage history file can't be read, so earlier spending isn't counted and new usage isn't being saved."
                Self.logger.error("usage.json couldn't be read: \(error.localizedDescription, privacy: .public)")
            }
        }
        let cutoff = now().addingTimeInterval(-Self.sessionRetention)
        f.sessions = f.sessions.filter { $0.value.lastUsed >= cutoff }
        file = f
        return f
    }

    private func save() {
        guard let file, !isReadOnly else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.ledger.encode(file).write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
            Self.logger.error("Couldn't save usage.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension JSONEncoder {
    static var ledger: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

private extension JSONDecoder {
    static var ledger: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
