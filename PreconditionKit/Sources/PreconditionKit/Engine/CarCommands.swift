import Foundation

/// A climate start as sent: the command's result, requests used and anything worth adding to the log line.
struct ClimateStart: Sendable {
    var result: ApiResult<CommandReceipt>
    var requests: Int
    /// "charger held", when the charger was stopped first.
    var note: String?
}

extension PreconditionEngine {
    /// How recent a cached plug state must be to act on it without reading the car.
    static let plugStateMaxAge: TimeInterval = 12 * 3600

    /// Plugged in but not charging: the charging finished, or it's waiting for the off-peak window.
    /// Starting climate now would wake the charger, so the charger is stopped first.
    static func shouldHoldCharger(_ vehicle: VehicleSnapshot?, _ prefs: ClimatePreferences) -> Bool {
        guard prefs.holdCharger, let vehicle, vehicle.pluggedIn == true else { return false }
        return vehicle.chargingState != .charging
    }

    /// The best plug state available without a request: `known` if there is one, else a recent cache.
    func plugState(_ known: VehicleSnapshot?) async -> VehicleSnapshot? {
        if let known { return known }
        guard let cached = await vehicles.cached(), time.now().timeIntervalSince(cached.fetchedAt) < Self.plugStateMaxAge else { return nil }
        return cached
    }

    /// Starts climate with the user's options. When the charger should be held, stops it first and waits
    /// for the car to confirm (or `commandGap` when Kia gives no id), so the car takes the commands one at a
    /// time. A failed stop never blocks the climate.
    func sendClimateStart(targetC: Double, kind: RequestKind, vehicle: VehicleSnapshot?, trigger: String?) async -> ClimateStart {
        let prefs = await settings.climatePreferences()
        var requests = 0
        var note: String?
        if Self.shouldHoldCharger(vehicle, prefs) {
            if await budget.available(kind) >= 2 {
                let stop = await client.send(.stopCharging, kind: kind)
                if stop.madeRequest { requests += 1 }
                let logKind: LogKind = kind == .manual ? .manual : .command
                switch stop {
                case .success(let receipt, let meta):
                    note = "charger held"
                    await vehicles.patch { $0.chargingState = .pluggedIn }
                    await log.append(LogEntry(
                        at: time.now(), kind: logKind, decision: "sent",
                        reason: "stop charging accepted: plugged in and idle, so climate won't wake the charger",
                        trigger: trigger, httpCode: meta.httpCode, requestsUsed: 1
                    ))
                    if let id = receipt.messageId {
                        let (status, polls) = await follow(id, kind: kind, delays: Self.chargerStopDelays)
                        requests += polls
                        if status == .failed || status == .noResponse {
                            await log.append(LogEntry(
                                at: time.now(), kind: .info, decision: "charger not held",
                                reason: status == .failed ? "the car didn't stop the charger; starting climate anyway" : "the car didn't confirm the charger stopped; starting climate anyway",
                                trigger: trigger, requestsUsed: polls
                            ))
                        }
                    } else {
                        await pause(commandGap)
                    }
                case .failure(let error, _):
                    await log.append(LogEntry(
                        at: time.now(), kind: .info, decision: "charger not held",
                        reason: "stop charging failed (\(error.message)); starting climate anyway",
                        trigger: trigger, httpCode: error.httpCode, requestsUsed: stop.madeRequest ? 1 : 0
                    ))
                }
            } else {
                await log.append(LogEntry(
                    at: time.now(), kind: .info, decision: "charger not held",
                    reason: "not enough rate budget to stop the charger first; starting climate only", trigger: trigger
                ))
            }
        }
        let result = await client.startClimate(targetC: targetC, kind: kind, options: prefs.options)
        if result.madeRequest { requests += 1 }
        if result.value != nil {
            await vehicles.patch {
                $0.climate = .running
                $0.targetTempC = targetC
            }
        }
        return ClimateStart(result: result, requests: requests, note: note)
    }

    // MARK: - Confirmation

    /// Waits between checks on a command: about 80 s in all, most commands report within 20–40 s.
    public static let confirmDelays: [TimeInterval] = [5, 5, 6, 8, 10, 12, 15, 20]
    /// Shorter for the charger stop that comes before climate.
    static let chargerStopDelays: [TimeInterval] = [3, 4, 4, 5, 6]

    /// Checks on command `id` until the car reports back or the delays run out. Waits never exceed
    /// `commandGap` in tests (where it's 0). Stops early rather than use the last of the budget.
    func follow(_ id: String, kind: RequestKind, delays: [TimeInterval]) async -> (CommandStatus, Int) {
        var polls = 0
        var status = CommandStatus.pending
        for delay in delays {
            await pause(commandGap == 0 ? 0 : delay)
            guard await budget.available(kind) >= 2 else { break }
            let result = await client.commandStatus(id, kind: kind)
            if result.madeRequest { polls += 1 }
            guard let s = result.value else { break }
            status = s
            if s.isFinal { break }
        }
        return (status, polls)
    }

    /// Follows the last command until the car confirms it (or refuses, or doesn't answer), then records,
    /// logs and notifies. Runs outside the engine's lock, so other requests aren't held up meanwhile.
    /// `sleep` throwing (the app is being suspended) ends it early.
    @discardableResult
    public func confirmLastCommand(
        kind: RequestKind = .manual,
        delays: [TimeInterval] = PreconditionEngine.confirmDelays,
        sleep: @Sendable (TimeInterval) async throws -> Void
    ) async -> CommandStatus {
        guard let command = await state.load().lastCommand, let id = command.messageId, command.status == nil else { return .unknown }
        var status = CommandStatus.pending
        var polls = 0
        for delay in delays {
            do { try await sleep(delay) } catch { break }
            // A newer command replaced this one: that one gets its own confirmation.
            guard await state.load().lastCommand?.messageId == id else { return .unknown }
            guard await budget.available(kind) >= 2 else { break }
            let result = await client.commandStatus(id, kind: kind)
            if result.madeRequest { polls += 1 }
            guard let s = result.value else { break }
            status = s
            if s.isFinal { break }
        }
        let now = time.now()
        let final = status
        await state.update { s in
            if s.lastCommand?.messageId == id { s.lastCommand?.status = final }
        }
        let description = command.description
        switch status {
        case .success:
            await log.append(LogEntry(at: now, kind: .command, decision: "confirmed", reason: "\(description): the car confirmed it", requestsUsed: polls))
            await notifier.commandSent(title: DisplayText.confirmed(description), text: "Confirmed by the car", canStop: description.hasPrefix("climatise"))
        case .failed:
            await log.append(LogEntry(at: now, kind: .error, decision: "refused by car", reason: "\(description): the car didn't carry it out", requestsUsed: polls))
            await notifier.problem(title: "The car didn't do it", text: "\(description.capitalizingFirstLetter) failed. The car may be in use, or a door or the charge port may be open.", openSettings: false)
        case .noResponse:
            await log.append(LogEntry(at: now, kind: .error, decision: "no answer", reason: "\(description): the car didn't respond (asleep or out of signal)", requestsUsed: polls))
            await notifier.problem(title: "No answer from the car", text: "\(description.capitalizingFirstLetter): the car didn't respond. It may be out of mobile signal.", openSettings: false)
        case .pending, .unknown:
            await log.append(LogEntry(at: now, kind: .info, decision: "unconfirmed", reason: "\(description): no confirmation from the car yet", requestsUsed: polls))
        }
        return status
    }

    /// Charging, locks and charge limits from the dashboard. Uses the manual budget.
    public func manualCommand(_ command: CarCommand) async -> ManualOutcome {
        await mutex.withLock {
            let now = time.now()
            let description = command.description
            if await budget.available(.manual) < 1 {
                await log.append(LogEntry(at: now, kind: .manual, decision: "refused", reason: "\(description): rate budget exhausted"))
                return .refused("rate budget exhausted")
            }
            if command == .startCharging || command == .stopCharging, await vehicles.cached()?.pluggedIn == false {
                await log.append(LogEntry(at: now, kind: .manual, decision: "refused", reason: "\(description): the car isn't plugged in"))
                return .refused("the car isn't plugged in")
            }
            let result = await client.send(command, kind: .manual)
            switch result {
            case .success(let receipt, let meta):
                await vehicles.patch { Self.apply(command, to: &$0) }
                let last = LastCommand(at: now, description: description, automated: false, messageId: receipt.messageId)
                await state.update { $0.lastCommand = last }
                await log.append(LogEntry(
                    at: now, kind: .manual, decision: "sent", reason: "\(description) accepted",
                    httpCode: meta.httpCode, requestsUsed: 1
                ))
                return .sent(description)
            case .failure(let error, _):
                await log.append(LogEntry(
                    at: now, kind: .manual, decision: "failed", reason: "\(description): \(error.message)",
                    httpCode: error.httpCode, requestsUsed: result.madeRequest ? 1 : 0
                ))
                return .failed(error)
            }
        }
    }

    /// What the command changes, as the car will report it.
    static func apply(_ command: CarCommand, to s: inout VehicleSnapshot) {
        var details = s.details ?? VehicleDetails()
        switch command {
        case .startCharging:
            s.chargingState = .charging
        case .stopCharging:
            s.chargingState = s.pluggedIn == false ? .unplugged : .pluggedIn
            s.chargePowerKw = nil
            s.minutesToFullyCharged = nil
        case .lock:
            details.locked = true
        case .unlock:
            details.locked = false
        case .setChargeLimits(let ac, let dc):
            details.chargeLimitAC = KiaClient.chargeLimit(ac)
            details.chargeLimitDC = KiaClient.chargeLimit(dc)
        case .setOffPeak(let window):
            details.offPeak = window
        }
        s.details = details
    }

    /// One day of the car's trips, for time at places.
    public func trips(on day: CalendarDay, kind: RequestKind) async -> ApiResult<[CarTrip]> {
        await mutex.withLock { await client.trips(on: day, kind: kind) }
    }

    /// Energy use for the Energy screen: two requests, one manual budget slot.
    public func drivingHistory() async -> ApiResult<DrivingHistory> {
        await mutex.withLock {
            let result = await client.drivingHistory(.manual)
            if case .failure(let error, _) = result {
                await log.append(LogEntry(
                    at: time.now(), kind: .manual, decision: "energy failed", reason: error.message,
                    httpCode: error.httpCode, requestsUsed: result.madeRequest ? 1 : 0
                ))
            }
            return result
        }
    }
}
