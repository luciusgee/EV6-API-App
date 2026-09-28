import Foundation

public extension ApiResult {
    /// True when the call reached (or may have reached) the network, i.e. it cost a request.
    var madeRequest: Bool {
        if meta != nil { return true }
        if case .failure(.network, _) = self { return true }
        return false
    }
}

/// The car's state with a 10-minute cache. Rules read the cache unless it's stale; nothing polls.
public final class VehicleRepository: Sendable {
    public static let defaultTTL: TimeInterval = 10 * 60

    private let client: VehicleAPI
    private let cache: VehicleCacheStore
    private let state: AutomationStateStore
    private let credentials: CredentialsProvider
    private let log: EventLog
    private let time: TimeSource
    public let ttl: TimeInterval

    public init(
        client: VehicleAPI,
        cache: VehicleCacheStore,
        state: AutomationStateStore,
        credentials: CredentialsProvider,
        log: EventLog,
        time: TimeSource = SystemTime(),
        ttl: TimeInterval = VehicleRepository.defaultTTL
    ) {
        self.client = client
        self.cache = cache
        self.state = state
        self.credentials = credentials
        self.log = log
        self.time = time
        self.ttl = ttl
    }

    /// Last known state of any age, for display.
    public func cached() async -> VehicleSnapshot? {
        await cache.load()
    }

    /// Cached state if it's younger than `ttl`.
    public func fresh() async -> VehicleSnapshot? {
        guard let s = await cache.load(), time.now().timeIntervalSince(s.fetchedAt) < ttl else { return nil }
        return s
    }

    public func clear() async {
        await cache.save(nil)
    }

    /// Records what a command just did, so the dashboard shows it before the car reports back.
    public func patch(_ change: (inout VehicleSnapshot) -> Void) async {
        guard var s = await cache.load() else { return }
        change(&s)
        await cache.save(s)
    }

    public func fetch(_ kind: RequestKind) async -> ApiResult<VehicleSnapshot> {
        switch await client.getVehicle(kind) {
        case .failure(let error, let meta):
            return .failure(error, meta)
        case .success(let fetch, let meta):
            await cache.save(fetch.snapshot)
            await dumpFirstResponse(fetch.rawJSON, httpCode: meta.httpCode)
            return .success(fetch.snapshot, meta)
        }
    }

    /// Milestone 1 wants the full response in the log once, to check the protocol, fields and time zones
    /// against a real car (HANDOVER.md §7, §8). The VIN is masked.
    private func dumpFirstResponse(_ raw: String, httpCode: Int) async {
        guard await !state.load().firstVehicleDumpDone else { return }
        let vin = await credentials.credentials()?.vin
        await log.append(LogEntry(
            at: time.now(),
            kind: .info,
            decision: "first vehicle response",
            reason: "Full vehicle response recorded for checking available fields",
            httpCode: httpCode,
            details: redactVin(raw, vin: vin)
        ))
        await state.update { $0.firstVehicleDumpDone = true }
    }
}

/// Watches every Kia response and stops all automation the moment a login is rejected, whichever code
/// path made the request. The next success resumes it.
public final class ApiMonitor: ApiMetaSink {
    /// How to fix a rejected login, shown in the notification.
    public static let authHelp = "Get a new Kia Connect refresh token (and check your PIN) and paste it in Settings."

    private let state: AutomationStateStore
    private let notifier: Notifier
    private let log: EventLog
    private let time: TimeSource

    public init(state: AutomationStateStore, notifier: Notifier, log: EventLog, time: TimeSource = SystemTime()) {
        self.state = state
        self.notifier = notifier
        self.log = log
        self.time = time
    }

    public func onResponse(_ meta: ResponseMeta, error: ApiError?) async {
        if let error, error.isAuthFailure {
            await onAuthFailure(error)
            return
        }
        guard (200...299).contains(meta.httpCode) else { return }
        let before = await state.load()
        guard before.authFailure != nil else { return }
        await state.update { $0.authFailure = nil }
        await log.append(LogEntry(at: time.now(), kind: .info, decision: "resumed", reason: "Kia Connect login accepted again; automation resumed"))
    }

    public func onAuthFailure(_ error: ApiError) async {
        let before = await state.load()
        let message = error.message
        await state.update { $0.authFailure = message }
        guard before.authFailure == nil else { return }
        await log.append(LogEntry(
            at: time.now(), kind: .error, decision: "stopped",
            reason: "\(message); all automation stopped", httpCode: error.httpCode
        ))
        await notifier.problem(title: "Automation stopped", text: "\(message.prefix(1).uppercased() + message.dropFirst()). \(Self.authHelp)", openSettings: true)
    }
}
