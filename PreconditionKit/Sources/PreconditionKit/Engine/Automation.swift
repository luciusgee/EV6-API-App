import Foundation

/// Where a trigger is in its retry sequence.
public struct Attempt: Equatable, Sendable {
    public var number: Int
    /// No further retries will follow a network failure.
    public var isLast: Bool
    /// This run is the single retry after the car said it was busy.
    public var vehicleBusyRetry: Bool

    public init(number: Int = 0, isLast: Bool = true, vehicleBusyRetry: Bool = false) {
        self.number = number
        self.isLast = isLast
        self.vehicleBusyRetry = vehicleBusyRetry
    }

    public var isRetry: Bool { number > 0 || vehicleBusyRetry }
}

public enum Retry: Equatable, Sendable {
    case none
    /// A network failure with attempts left.
    case backoff
    /// Kia said the car is busy: try once more in about 2 minutes.
    case vehicleBusy
}

public enum EngineOutcome: Equatable, Sendable {
    case skipped(String)
    case fired(Rule, RuleAction)
    case failed(ApiError, Retry)
}

/// The engine's inputs for one run: the vehicle read at most once, one phone fix, weather through the cache.
final class EngineInputs: EvaluationInputs, @unchecked Sendable {
    private let vehicles: VehicleRepository
    private let weather: WeatherSource
    private let cabin: CabinSensor
    private let phone: PhoneLocator
    private let kind: RequestKind
    private var snapshot: VehicleSnapshot?
    private var attempted = false
    private var phoneLocated = false
    private var phoneFix: LatLon?
    private(set) var requestsMade = 0
    private(set) var vehicleError: ApiError?

    private init(vehicles: VehicleRepository, weather: WeatherSource, cabin: CabinSensor, phone: PhoneLocator, kind: RequestKind, snapshot: VehicleSnapshot?) {
        self.vehicles = vehicles
        self.weather = weather
        self.cabin = cabin
        self.phone = phone
        self.kind = kind
        self.snapshot = snapshot
    }

    static func create(vehicles: VehicleRepository, weather: WeatherSource, cabin: CabinSensor, phone: PhoneLocator, kind: RequestKind) async -> EngineInputs {
        EngineInputs(vehicles: vehicles, weather: weather, cabin: cabin, phone: phone, kind: kind, snapshot: await vehicles.fresh())
    }

    func vehicleIfFree() async -> VehicleSnapshot? { snapshot }

    func vehicle() async -> VehicleSnapshot? {
        if let snapshot { return snapshot }
        if attempted { return nil }
        attempted = true
        let result = await vehicles.fetch(kind)
        if result.madeRequest { requestsMade += 1 }
        switch result {
        case .success(let v, _):
            snapshot = v
            return v
        case .failure(let e, _):
            vehicleError = e
            return nil
        }
    }

    func weatherNow(at: LatLon) async -> TempReading? { await weather.current(at: at) }
    func forecast(at: LatLon, time: Date) async -> TempReading? { await weather.forecast(at: at, time: time) }
    func cabinTemp() async -> TempReading? { await cabin.read() }

    func phoneLocation() async -> LatLon? {
        if !phoneLocated {
            phoneLocated = true
            phoneFix = await phone.locate()
        }
        return phoneFix
    }
}

extension PreconditionEngine {
    public static let staleAfter: TimeInterval = 30 * 60
    public static let dedupWindow: TimeInterval = 5 * 60
    public static let maxConsecutiveFailures = 3
    public static let positionMaxAge: TimeInterval = 3 * 3600
    /// Leave room for a full precondition cycle (read + command) after a position refresh.
    public static let positionRefreshMinBudget = 3

    /// A trigger fired (geofence, schedule, notification). Evaluates the rules and sends the winner's
    /// action (HANDOVER.md §4.4). The outcome says whether and how the caller should retry.
    public func onTrigger(_ event: TriggerEvent, triggeredAt: Date, attempt: Attempt = Attempt()) async -> EngineOutcome {
        await mutex.withLock { await handle(event, triggeredAt: triggeredAt, attempt: attempt) }
    }

    /// Runs a trigger with the retry policy inside this process: network failures back off and retry,
    /// a busy car gets one more try after `busyDelay`. On iOS a background wake has little time, so the
    /// caller picks the delays (and passes a `sleep` that gives up when time runs out).
    public func onTriggerWithRetries(
        _ event: TriggerEvent,
        triggeredAt: Date,
        backoff: [TimeInterval] = [15, 45],
        busyDelay: TimeInterval = 120,
        sleep: @Sendable (TimeInterval) async throws -> Void
    ) async -> EngineOutcome {
        var attempt = Attempt(number: 0, isLast: backoff.isEmpty)
        while true {
            let outcome = await onTrigger(event, triggeredAt: triggeredAt, attempt: attempt)
            guard case .failed(_, let retry) = outcome, retry != .none else { return outcome }
            let delay: TimeInterval
            if retry == .vehicleBusy {
                delay = busyDelay
                attempt = Attempt(number: attempt.number, isLast: attempt.isLast, vehicleBusyRetry: true)
            } else {
                delay = backoff[min(attempt.number, backoff.count - 1)]
                attempt = Attempt(number: attempt.number + 1, isLast: attempt.number + 1 >= backoff.count, vehicleBusyRetry: attempt.vehicleBusyRetry)
            }
            do { try await sleep(delay) } catch { return outcome }
        }
    }

    private func handle(_ event: TriggerEvent, triggeredAt: Date, attempt: Attempt) async -> EngineOutcome {
        let now = time.now()
        let placeList = await rulesStore.places()
        let placeMap = Dictionary(placeList.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let label = Describe.event(event) { placeMap[$0]?.name ?? $0 }

        func skip(_ reason: String, kind: LogKind = .skipped) async -> EngineOutcome {
            await log.append(LogEntry(at: now, kind: kind, decision: "skipped", reason: reason, trigger: label))
            return .skipped(reason)
        }

        let age = now.timeIntervalSince(triggeredAt)
        if age > Self.staleAfter { return await skip("trigger is \(Int(age / 60)) min old; abandoned") }

        let st = await state.load()
        if let blocked = st.automationBlockedReason { return await skip(blocked) }

        if let key = event.dedupKey, !attempt.isRetry {
            if let last = st.lastTriggerAt[key], now.timeIntervalSince(last) < Self.dedupWindow {
                return await skip("duplicate event within \(Int(Self.dedupWindow / 60)) min; ignored", kind: .info)
            }
            await state.update { $0.lastTriggerAt[key] = now }
        }

        let inputs = await EngineInputs.create(vehicles: vehicles, weather: weather, cabin: cabin, phone: phone, kind: .automation)
        let budget = self.budget
        let evaluation = await RuleEvaluator.evaluate(EvaluationRequest(
            event: event,
            now: now,
            clock: localClock(),
            rules: await rulesStore.rules(),
            places: placeMap,
            guards: await settings.guards(),
            cooldowns: st.cooldowns,
            automationBudget: { await budget.available(.automation) },
            inputs: inputs
        ))
        await logEvaluation(evaluation, label: label, requests: inputs.requestsMade, dryRun: false)

        // A rejected login during the read has already stopped automation, through ApiMonitor.
        if let e = inputs.vehicleError, e.isAuthFailure { return .failed(e, .none) }

        guard let winner = evaluation.winner else {
            // The read itself failed: retry or count it like a failed command.
            if let e = inputs.vehicleError { return await failure(e, rule: nil, attempt: attempt, label: label) }
            return .skipped(evaluation.globalSkip ?? evaluation.verdicts.last?.reason ?? "no rule passed")
        }
        if winner.askFirst {
            return await ask(winner, label: label, temperature: evaluation.winnerVerdict?.temperature)
        }
        let vehicle = await plugState(await inputs.vehicleIfFree())
        return await execute(winner, label: label, temperature: evaluation.winnerVerdict?.temperature, attempt: attempt, vehicle: vehicle)
    }

    /// Asks instead of acting. The rule's cooldown starts now, so it asks once, not at every trigger.
    private func ask(_ rule: Rule, label: String, temperature: TempReading?) async -> EngineOutcome {
        let now = time.now()
        let ruleId = rule.id
        await state.update { $0.lastFiredByRule[ruleId] = now }
        await log.append(LogEntry(
            at: now, kind: .info, decision: "asked", reason: "asked before \(Describe.action(rule.action))", trigger: label,
            ruleId: rule.id, ruleName: rule.name
        ))
        await notifier.ask(ruleId: rule.id, title: AskPlanner.title(rule), text: AskPlanner.text(rule, outsideC: temperature?.celsius))
        return .skipped("asked first")
    }

    private func execute(_ rule: Rule, label: String, temperature: TempReading?, attempt: Attempt, vehicle: VehicleSnapshot?) async -> EngineOutcome {
        let action = rule.action
        let result: ApiResult<CommandReceipt>
        var note: String?
        switch action {
        case .startClimate(let target):
            let start = await sendClimateStart(targetC: target, kind: .automation, vehicle: vehicle, trigger: label, options: rule.climateOptions)
            result = start.result
            note = start.note
        case .stopClimate:
            result = await client.stopClimate(.automation)
            if result.value != nil { await vehicles.patch { $0.climate = .off } }
        }
        let now = time.now()
        let description = Describe.action(action)

        switch result {
        case .success(let receipt, let meta):
            let command = LastCommand(at: now, description: description, automated: true, messageId: receipt.messageId)
            let ruleId = rule.id
            await state.update {
                $0.lastAutomatedCommandAt = now
                $0.lastFiredByRule[ruleId] = now
                $0.consecutiveFailures = 0
                $0.lastCommand = command
            }
            await log.append(LogEntry(
                at: now, kind: .command, decision: "sent", reason: "\(description) accepted" + (note.map { " (\($0))" } ?? ""), trigger: label,
                ruleId: rule.id, ruleName: rule.name, httpCode: meta.httpCode, requestsUsed: result.madeRequest ? 1 : 0
            ))
            let context = ([label] + [temperature.map { Describe.temp($0.celsius) }, note].compactMap { $0 }).joined(separator: ", ")
            let headline: String
            if case .startClimate(let target) = action {
                headline = "starting climate · \(Describe.temp(target))"
            } else {
                headline = "stopping climate"
            }
            var canStop = false
            if case .startClimate = action { canStop = true }
            await notifier.commandSent(title: "\(rule.name): \(headline)", text: context.capitalizingFirstLetter + ".", canStop: canStop)
            return .fired(rule, action)
        case .failure(let error, _):
            await log.append(LogEntry(
                at: now, kind: .error, decision: "failed", reason: "\(description): \(error.message)", trigger: label,
                ruleId: rule.id, ruleName: rule.name, httpCode: error.httpCode, requestsUsed: result.madeRequest ? 1 : 0
            ))
            return await failure(error, rule: rule, attempt: attempt, label: label)
        }
    }

    /// The failure policy (HANDOVER.md §4.4).
    private func failure(_ error: ApiError, rule: Rule?, attempt: Attempt, label: String) async -> EngineOutcome {
        let now = time.now()
        switch error {
        case _ where error.isAuthFailure:
            return .failed(error, .none)
        case .operationNotSupported:
            if let rule {
                await rulesStore.disableRule(id: rule.id, reason: error.message)
                await log.append(LogEntry(
                    at: now, kind: .error, decision: "rule disabled", reason: "\(rule.name) disabled: \(error.message)",
                    trigger: label, ruleId: rule.id, ruleName: rule.name, httpCode: error.httpCode
                ))
                await notifier.problem(title: "Rule disabled", text: "“\(rule.name)” was disabled: \(error.message).", openSettings: false)
            }
            return .failed(error, .none)
        case .vehicleNotAcceptingRequests where !attempt.vehicleBusyRetry:
            await log.append(LogEntry(
                at: now, kind: .info, decision: "retrying", reason: "vehicle not accepting requests; retrying once in 2 min",
                trigger: label, ruleId: rule?.id, ruleName: rule?.name, httpCode: error.httpCode
            ))
            return .failed(error, .vehicleBusy)
        case .network where !attempt.isLast:
            await log.append(LogEntry(
                at: now, kind: .info, decision: "retrying", reason: "\(error.message); will retry with backoff",
                trigger: label, ruleId: rule?.id, ruleName: rule?.name
            ))
            return .failed(error, .backoff)
        case .budgetExhausted, .notConfigured:
            return .failed(error, .none)
        default:
            break
        }

        // A final failure: count it, and pause automation after three in a row.
        let max = Self.maxConsecutiveFailures
        let s = await state.update {
            $0.consecutiveFailures += 1
            if $0.consecutiveFailures >= max { $0.pausedAfterFailures = true }
        }
        let what = rule.map { "“\($0.name)”" } ?? "Reading the car"
        await notifier.problem(title: "Rule failed", text: "\(what) failed: \(error.message).", openSettings: false)
        if s.pausedAfterFailures && s.consecutiveFailures == max {
            await log.append(LogEntry(at: now, kind: .error, decision: "paused", reason: "automation paused after \(max) consecutive failures", trigger: label))
            await notifier.problem(title: "Automation paused", text: "\(max) rule attempts failed in a row. Resume automation from the dashboard.", openSettings: false)
        }
        return .failed(error, .none)
    }

    /// "Test now": evaluates one saved rule whatever its trigger, never sends. Nil if there's no such rule.
    public func dryRun(ruleId: String) async -> Evaluation? {
        guard let rule = await rulesStore.rules().first(where: { $0.id == ruleId }) else { return nil }
        return await dryRun(rule)
    }

    /// "Test now" for a rule that may not be saved yet (the editor's draft).
    public func dryRun(_ rule: Rule) async -> Evaluation {
        await mutex.withLock {
            let now = time.now()
            let placeList = await rulesStore.places()
            let placeMap = Dictionary(placeList.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let st = await state.load()
            // Reading the car for a test is the user's own request, so it uses the manual budget.
            let inputs = await EngineInputs.create(vehicles: vehicles, weather: weather, cabin: cabin, phone: phone, kind: .manual)
            var enabled = rule
            enabled.enabled = true
            let budget = self.budget
            let evaluation = await RuleEvaluator.evaluate(EvaluationRequest(
                event: rule.trigger.syntheticEvent,
                now: now,
                clock: localClock(),
                rules: [enabled],
                places: placeMap,
                guards: await settings.guards(),
                cooldowns: st.cooldowns,
                automationBudget: { await budget.available(.automation) },
                inputs: inputs,
                requireTriggerMatch: false
            ))
            await logEvaluation(evaluation, label: "test now", requests: inputs.requestsMade, dryRun: true)
            return evaluation
        }
    }

    /// Keeps the parked position fresh for near-car rules: reads the car (automation budget) when such a
    /// rule is enabled and the cached state is older than `maxAge`. Returns whether it read the car.
    @discardableResult
    public func refreshCarPositionIfDue(maxAge: TimeInterval = PreconditionEngine.positionMaxAge) async -> Bool {
        await mutex.withLock {
            guard Geofences.needsCarPosition(await rulesStore.rules()) else { return false }
            guard await state.load().automationBlockedReason == nil else { return false }
            if let cached = await vehicles.cached(), time.now().timeIntervalSince(cached.fetchedAt) < maxAge { return false }
            guard await budget.available(.automation) >= Self.positionRefreshMinBudget else { return false }
            let result = await vehicles.fetch(.automation)
            let decision: String
            let reason: String
            switch result {
            case .success(let v, _):
                decision = "position"
                if v.parkingPosition == nil {
                    reason = "car position unavailable; near-car rules can't fire"
                } else if v.parked == false {
                    reason = "car is moving; near-car fence paused"
                } else {
                    reason = "car position refreshed for near-car rules"
                }
            case .failure(let e, _):
                decision = "position failed"
                reason = "car position refresh failed: \(e.message)"
            }
            await log.append(LogEntry(
                at: time.now(), kind: .info, decision: decision, reason: reason,
                httpCode: result.meta?.httpCode, requestsUsed: result.madeRequest ? 1 : 0
            ))
            return result.value != nil
        }
    }

    /// One log entry per rule evaluated, with each check, and the reason it stopped (HANDOVER.md §4.3.8).
    private func logEvaluation(_ evaluation: Evaluation, label: String, requests: Int, dryRun: Bool) async {
        if let skip = evaluation.globalSkip {
            await log.append(LogEntry(at: evaluation.at, kind: dryRun ? .dryRun : .skipped, decision: "skipped", reason: skip, trigger: label, requestsUsed: requests))
            return
        }
        for (i, v) in evaluation.verdicts.enumerated() {
            let kind: LogKind = dryRun ? .dryRun : (v.fired ? .fired : .skipped)
            let decision = dryRun ? (v.fired ? "would fire" : "would skip") : (v.fired ? "fired" : "skipped")
            await log.append(LogEntry(
                at: evaluation.at, kind: kind, decision: decision, reason: v.reason, trigger: label,
                ruleId: v.ruleId, ruleName: v.ruleName,
                // Requests are attributed to the last rule evaluated, where the run stopped.
                requestsUsed: i == evaluation.verdicts.count - 1 ? requests : 0,
                details: v.checks.map { "\($0.result.rawValue) \($0.name): \($0.detail)" }.joined(separator: "\n")
            ))
        }
    }
}
