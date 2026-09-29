import Foundation

public enum ManualOutcome: Equatable, Sendable {
    case sent(String)
    case refused(String)
    case failed(ApiError)
}

/// Every trigger ends up here (HANDOVER.md §4.4). The engine loads rules and state, runs the evaluator,
/// sends the winner's action and records the outcome: cooldowns, failure counts, log, notification.
/// It also runs the dashboard's manual Start, Stop and Refresh. Runs are one at a time, so triggers never
/// race on cooldowns or the budget.
public final class PreconditionEngine: Sendable {
    let client: VehicleAPI
    let vehicles: VehicleRepository
    let budget: RateBudget
    let state: AutomationStateStore
    let settings: SettingsSource
    let log: EventLog
    let notifier: Notifier
    let time: TimeSource
    let rulesStore: RulesStore
    let weather: WeatherSource
    let phone: PhoneLocator
    let cabin: CabinSensor
    let localClock: @Sendable () -> LocalClock
    /// Waits between two commands in a row (stop charging, then climate), so the car takes them in turn.
    let commandGap: TimeInterval
    let pause: @Sendable (TimeInterval) async -> Void
    let mutex = AsyncMutex()

    public init(
        client: VehicleAPI,
        vehicles: VehicleRepository,
        budget: RateBudget,
        state: AutomationStateStore,
        settings: SettingsSource,
        log: EventLog,
        notifier: Notifier = NoopNotifier(),
        time: TimeSource = SystemTime(),
        rules: RulesStore = InMemoryRulesStore(),
        weather: WeatherSource = NoWeather(),
        phone: PhoneLocator = NoPhoneLocator(),
        cabin: CabinSensor = NoCabinSensor(),
        localClock: @escaping @Sendable () -> LocalClock = { LocalClock() },
        commandGap: TimeInterval = 5,
        pause: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        }
    ) {
        self.client = client
        self.vehicles = vehicles
        self.budget = budget
        self.state = state
        self.settings = settings
        self.log = log
        self.notifier = notifier
        self.time = time
        self.rulesStore = rules
        self.weather = weather
        self.phone = phone
        self.cabin = cabin
        self.localClock = localClock
        self.commandGap = commandGap
        self.pause = pause
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
    /// `wake` asks the car to report in first, for up-to-the-minute state.
    public func refreshVehicle(wake: Bool = false) async -> ApiResult<VehicleSnapshot> {
        await mutex.withLock {
            let result = await vehicles.fetch(.manual, wake: wake)
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
        var vehicle: VehicleSnapshot?
        if case .startClimate = action {
            vehicle = await vehicles.fresh()
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

        let result: ApiResult<CommandReceipt>
        var note: String?
        switch action {
        case .startClimate(let target):
            let start = await sendClimateStart(targetC: target, kind: .manual, vehicle: await plugState(vehicle), trigger: nil)
            result = start.result
            requests += start.requests
            note = start.note
        case .stopClimate:
            result = await client.stopClimate(.manual)
            if result.madeRequest { requests += 1 }
            if result.value != nil { await vehicles.patch { $0.climate = .off } }
        }

        switch result {
        case .success(let receipt, let meta):
            let command = LastCommand(at: now, description: description, automated: false, messageId: receipt.messageId)
            await state.update { $0.lastCommand = command }
            await log.append(LogEntry(
                at: now, kind: .manual, decision: "sent", reason: "\(description) accepted" + (note.map { " (\($0))" } ?? ""),
                httpCode: meta.httpCode, requestsUsed: requests
            ))
            if case .startClimate(let target) = action {
                let text = note == nil ? "Sent to the car." : "Sent to the car, with the charger held."
                await notifier.commandSent(title: "Starting climate · \(Describe.temp(target))", text: text, canStop: true)
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
