import Foundation

public enum ManualOutcome: Equatable, Sendable {
    case sent(String)
    case refused(String)
    case failed(ApiError)
}

/// Sends climate commands and records the outcome. For milestone 1 this is the manual path (the dashboard's
/// Start, Stop and Refresh); rule evaluation from triggers joins it in milestone 2 (HANDOVER.md §4.4).
/// Calls run one at a time so they never race on the budget or the cache.
public final class PreconditionEngine: Sendable {
    private let client: VehicleAPI
    private let vehicles: VehicleRepository
    private let budget: RateBudget
    private let state: AutomationStateStore
    private let settings: SettingsSource
    private let log: EventLog
    private let notifier: Notifier
    private let time: TimeSource
    private let mutex = AsyncMutex()

    public init(
        client: VehicleAPI,
        vehicles: VehicleRepository,
        budget: RateBudget,
        state: AutomationStateStore,
        settings: SettingsSource,
        log: EventLog,
        notifier: Notifier = NoopNotifier(),
        time: TimeSource = SystemTime()
    ) {
        self.client = client
        self.vehicles = vehicles
        self.budget = budget
        self.state = state
        self.settings = settings
        self.log = log
        self.notifier = notifier
        self.time = time
    }

    /// Manual start: the SoC guard and the budget still apply; cooldowns and pause don't.
    public func manualStart(targetC: Double? = nil) async -> ManualOutcome {
        await mutex.withLock {
            let target: Double
            if let targetC { target = targetC } else { target = await settings.defaultTargetC() }
            return await manual(.startClimate(targetC: target))
        }
    }

    public func manualStop() async -> ManualOutcome {
        await mutex.withLock { await manual(.stopClimate) }
    }

    /// Dashboard refresh. A user action, so it draws on the manual budget.
    public func refreshVehicle() async -> ApiResult<VehicleSnapshot> {
        await mutex.withLock {
            let result = await vehicles.fetch(.manual)
            if case .failure(let error, _) = result {
                await log.append(LogEntry(
                    at: time.now(), kind: .manual, decision: "refresh failed", reason: error.message,
                    httpCode: error.httpCode, requestsUsed: result.madeRequest ? 1 : 0
                ))
            }
            return result
        }
    }

    /// Clears a pause after repeated failures.
    public func resumeAutomation() async {
        await state.update {
            $0.pausedAfterFailures = false
            $0.consecutiveFailures = 0
        }
        await log.append(LogEntry(at: time.now(), kind: .info, decision: "resumed", reason: "automation resumed by user"))
    }

    private func manual(_ action: RuleAction) async -> ManualOutcome {
        let now = time.now()
        let description = Describe.action(action)

        func refuse(_ reason: String) async -> ManualOutcome {
            await log.append(LogEntry(at: now, kind: .manual, decision: "refused", reason: "\(description): \(reason)"))
            return .refused(reason)
        }

        var requests = 0
        if case .startClimate = action {
            var vehicle = await vehicles.fresh()
            let needed = vehicle == nil ? 2 : 1
            if await budget.available(.manual) < needed { return await refuse("rate budget exhausted") }
            if vehicle == nil {
                let fetched = await vehicles.fetch(.manual)
                if fetched.madeRequest { requests += 1 }
                switch fetched {
                case .success(let v, _): vehicle = v
                case .failure(let error, _): return await refuse("vehicle state unavailable: \(error.message)")
                }
            }
            if let vehicle {
                let soc = Guards.soc(vehicle, minPercent: await settings.guards().minSocPercent)
                if soc.result != .pass { return await refuse(soc.detail) }
            }
        } else if await budget.available(.manual) < 1 {
            return await refuse("rate budget exhausted")
        }

        let result: ApiResult<Void>
        switch action {
        case .startClimate(let target): result = await client.startClimate(targetC: target, kind: .manual)
        case .stopClimate: result = await client.stopClimate(.manual)
        }
        if result.madeRequest { requests += 1 }

        switch result {
        case .success(_, let meta):
            let command = LastCommand(at: now, description: description, automated: false)
            await state.update { $0.lastCommand = command }
            await log.append(LogEntry(
                at: now, kind: .manual, decision: "sent", reason: "\(description) accepted",
                httpCode: meta.httpCode, requestsUsed: requests
            ))
            if case .startClimate(let target) = action {
                await notifier.commandSent(title: "Preconditioning to \(Describe.temp(target))", text: "Started manually", canStop: true)
            }
            return .sent(description)
        case .failure(let error, _):
            await log.append(LogEntry(
                at: now, kind: .manual, decision: "failed", reason: "\(description): \(error.message)",
                httpCode: error.httpCode, requestsUsed: requests
            ))
            return .failed(error)
        }
    }
}
