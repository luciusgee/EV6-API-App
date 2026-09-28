import Foundation

/// A climate start as sent: the command's result, requests used and anything worth adding to the log line.
struct ClimateStart: Sendable {
    var result: ApiResult<Void>
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
    /// `commandGap` so the car takes the commands one at a time. A failed stop never blocks the climate.
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
                case .success(_, let meta):
                    note = "charger held"
                    await vehicles.patch { $0.chargingState = .pluggedIn }
                    await log.append(LogEntry(
                        at: time.now(), kind: logKind, decision: "sent",
                        reason: "stop charging accepted: plugged in and idle, so climate won't wake the charger",
                        trigger: trigger, httpCode: meta.httpCode, requestsUsed: 1
                    ))
                    await pause(commandGap)
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
            case .success(_, let meta):
                await vehicles.patch { Self.apply(command, to: &$0) }
                let last = LastCommand(at: now, description: description, automated: false)
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
        }
        s.details = details
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
