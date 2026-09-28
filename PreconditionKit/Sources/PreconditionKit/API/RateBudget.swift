import Foundation

/// Kia allows roughly 200 requests a day per account and sends no rate headers, so the app counts its own
/// (HANDOVER.md §4.5). One budget slot covers one client call, even when that call makes several HTTP
/// requests (a read is status plus parked position).
public struct BudgetConfig: Equatable, Sendable {
    public var limit: Int
    /// Slots per window that automation may never touch, so manual commands always work.
    public var manualReserve: Int
    public var window: TimeInterval

    public init(limit: Int = 80, manualReserve: Int = 8, window: TimeInterval = 24 * 3600) {
        self.limit = limit
        self.manualReserve = manualReserve
        self.window = window
    }

    /// The Android Kia app's defaults: 80 per rolling 24 h, 8 kept for manual use.
    public static let kia = BudgetConfig()
}

public struct SentRequest: Codable, Equatable, Sendable {
    public var id: Int64
    public var at: Date
    public var kind: RequestKind
    public var completed: Bool

    public init(id: Int64, at: Date, kind: RequestKind, completed: Bool = false) {
        self.id = id
        self.at = at
        self.kind = kind
        self.completed = completed
    }
}

/// Persisted between launches.
public struct RateBudgetState: Codable, Equatable, Sendable {
    /// Set when Kia says the daily limit is used up; nothing is sent until then.
    public var exhaustedUntil: Date?
    public var sent: [SentRequest]
    public var nextId: Int64

    public init(exhaustedUntil: Date? = nil, sent: [SentRequest] = [], nextId: Int64 = 1) {
        self.exhaustedUntil = exhaustedUntil
        self.sent = sent
        self.nextId = nextId
    }
}

public protocol RateBudgetStore: Sendable {
    func load() async -> RateBudgetState
    func save(_ state: RateBudgetState) async
}

public actor InMemoryRateBudgetStore: RateBudgetStore {
    public private(set) var state: RateBudgetState

    public init(_ state: RateBudgetState = RateBudgetState()) { self.state = state }

    public func load() -> RateBudgetState { state }
    public func save(_ state: RateBudgetState) { self.state = state }
}

/// For the dashboard bar: "80 left of 80 · 72 for automation · 8 kept for you · resets 17:10".
public struct BudgetSnapshot: Equatable, Sendable {
    public var limit: Int
    public var remaining: Int
    public var automationAvailable: Int
    public var manualAvailable: Int
    public var automationUsedInWindow: Int
    public var manualReserve: Int
    /// When the oldest request in the window drops out; nil if none were sent.
    public var resetAt: Date?
    public var exhaustedUntil: Date?
}

/// Proof that a slot was taken; hand it back to `RateBudget.complete`.
public struct BudgetTicket: Equatable, Sendable {
    public var id: Int64
    public var kind: RequestKind
}

/// Counts requests over a rolling window and keeps `manualReserve` of them for manual commands.
/// Automation is capped twice: it must leave the reserve untouched, and it may never use more than
/// `limit − reserve` in a window.
public final class RateBudget: Sendable {
    private let store: RateBudgetStore
    private let time: TimeSource
    private let config: @Sendable () async -> BudgetConfig
    private let mutex = AsyncMutex()

    /// - Parameter config: read on every call, so changes in Settings apply at once.
    public init(store: RateBudgetStore, time: TimeSource = SystemTime(), config: @escaping @Sendable () async -> BudgetConfig) {
        self.store = store
        self.time = time
        self.config = config
    }

    public convenience init(store: RateBudgetStore, time: TimeSource = SystemTime(), config: BudgetConfig = .kia) {
        self.init(store: store, time: time, config: { config })
    }

    public func snapshot() async -> BudgetSnapshot {
        await mutex.withLock {
            Self.compute(await store.load(), await config(), time.now())
        }
    }

    public func available(_ kind: RequestKind) async -> Int {
        let s = await snapshot()
        return kind == .automation ? s.automationAvailable : s.manualAvailable
    }

    /// Takes one slot, or returns nil if the budget has none left for `kind`.
    public func tryAcquire(_ kind: RequestKind) async -> BudgetTicket? {
        await mutex.withLock { () -> BudgetTicket? in
            let now = time.now()
            let cfg = await config()
            var state = await store.load()
            let snap = Self.compute(state, cfg, now)
            let available = kind == .automation ? snap.automationAvailable : snap.manualAvailable
            guard available >= 1 else { return nil }
            let id = state.nextId
            state.sent.append(SentRequest(id: id, at: now, kind: kind))
            state.nextId += 1
            await store.save(Self.prune(state, now, cfg))
            return BudgetTicket(id: id, kind: kind)
        }
    }

    /// Records how a request went.
    /// - Parameters:
    ///   - meta: nil when no response arrived (network failure); the request still counts.
    ///   - error: the mapped error, if it failed. `rateLimited` blocks everything until it expires.
    public func complete(_ ticket: BudgetTicket, meta: ResponseMeta?, error: ApiError? = nil) async {
        await mutex.withLock {
            let now = time.now()
            let cfg = await config()
            var state = await store.load()

            // Rejected logins (401/403) don't count against the limit.
            if let meta, meta.httpCode == 401 || meta.httpCode == 403 {
                state.sent.removeAll { $0.id == ticket.id }
            } else if let i = state.sent.firstIndex(where: { $0.id == ticket.id }) {
                state.sent[i].completed = true
            }

            if case .rateLimited(let retryAfter) = error {
                state.exhaustedUntil = now.addingTimeInterval(retryAfter ?? meta?.retryAfter ?? cfg.window)
            }

            await store.save(Self.prune(state, now, cfg))
        }
    }

    /// Two windows of history is plenty to count the current one.
    private static func prune(_ state: RateBudgetState, _ now: Date, _ cfg: BudgetConfig) -> RateBudgetState {
        var s = state
        let keepAfter = now.addingTimeInterval(-2 * cfg.window)
        s.sent.removeAll { $0.at < keepAfter }
        return s
    }

    /// Pure, for tests and previews.
    public static func compute(_ state: RateBudgetState, _ cfg: BudgetConfig, _ now: Date) -> BudgetSnapshot {
        let windowStart = now.addingTimeInterval(-cfg.window)
        let inWindow = state.sent.filter { $0.at >= windowStart }
        let remaining = cfg.limit - inWindow.count
        let exhaustedUntil = state.exhaustedUntil.flatMap { $0 > now ? $0 : nil }
        let automationUsed = inWindow.filter { $0.kind == .automation }.count

        let manual = exhaustedUntil != nil ? 0 : max(remaining, 0)
        let automation = exhaustedUntil != nil ? 0 : max(
            min(remaining - cfg.manualReserve, cfg.limit - cfg.manualReserve - automationUsed),
            0
        )

        return BudgetSnapshot(
            limit: cfg.limit,
            remaining: max(remaining, 0),
            automationAvailable: automation,
            manualAvailable: manual,
            automationUsedInWindow: automationUsed,
            manualReserve: cfg.manualReserve,
            resetAt: inWindow.map(\.at).min().map { $0.addingTimeInterval(cfg.window) },
            exhaustedUntil: exhaustedUntil
        )
    }
}
