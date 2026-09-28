import Foundation
import XCTest
@testable import PreconditionKit

func snapshot(
    soc: Int? = 60,
    plugged: Bool? = false,
    climate: ClimateState = .off,
    outside: Double? = nil,
    position: LatLon? = office.centre,
    fetchedAt: Date = wednesdayAt(17)
) -> VehicleSnapshot {
    VehicleSnapshot(
        socPercent: soc, pluggedIn: plugged, climate: climate, climateRawState: climate == .running ? "HEATING" : "OFF",
        outsideTempC: outside, parkingPosition: position, fetchedAt: fetchedAt
    )
}

/// Inputs whose values tests set directly, counting what the evaluator asked for.
final class FakeInputs: EvaluationInputs, @unchecked Sendable {
    var vehicleState: VehicleSnapshot?
    /// Vehicle state is already cached (free) rather than costing a read.
    var cached: Bool
    var weather: Double?
    var forecastC: Double?
    var cabin: Double?
    /// Next to the car by default (the default vehicle is parked at the office).
    var phone: LatLon?

    private(set) var phoneLookups = 0
    private(set) var vehicleReads = 0
    private(set) var weatherAt: [LatLon] = []
    private(set) var forecastTimes: [Date] = []
    private var fetched = false

    init(vehicleState: VehicleSnapshot? = snapshot(), cached: Bool = false, weather: Double? = 2, forecast: Double? = 1, cabin: Double? = nil, phone: LatLon? = office.centre) {
        self.vehicleState = vehicleState
        self.cached = cached
        self.weather = weather
        self.forecastC = forecast
        self.cabin = cabin
        self.phone = phone
    }

    func vehicleIfFree() async -> VehicleSnapshot? { cached || fetched ? vehicleState : nil }

    func vehicle() async -> VehicleSnapshot? {
        if !cached && !fetched {
            vehicleReads += 1
            fetched = true
        }
        return vehicleState
    }

    func weatherNow(at: LatLon) async -> TempReading? {
        weatherAt.append(at)
        return weather.map { TempReading(celsius: $0, source: "Open-Meteo", at: .distantPast) }
    }

    func forecast(at: LatLon, time: Date) async -> TempReading? {
        weatherAt.append(at)
        forecastTimes.append(time)
        return forecastC.map { TempReading(celsius: $0, source: "Open-Meteo forecast", at: time) }
    }

    func cabinTemp() async -> TempReading? { cabin.map { TempReading(celsius: $0, source: "cabin sensor", at: .distantPast) } }

    func phoneLocation() async -> LatLon? {
        phoneLookups += 1
        return phone
    }
}

/// Port of the Android `RuleEvaluatorTest`, plus the evaluator parts of `NearCarTest`,
/// `PhoneNearCarTest` and `TempOutsideTest`.
final class RuleEvaluatorTests: XCTestCase {
    let exitOffice = TriggerEvent.geofenceExited(placeId: "office")
    let leavingWork = Templates.leavingWork(officeId: "office", id: "leave")

    func evaluate(
        _ rules: [Rule],
        _ inputs: FakeInputs = FakeInputs(),
        now: Date = wednesdayAt(17),
        event: TriggerEvent? = nil,
        guards: GuardSettings = GuardSettings(),
        cooldowns: CooldownState = CooldownState(),
        budget: Int = 16,
        requireTriggerMatch: Bool = true
    ) async -> Evaluation {
        await RuleEvaluator.evaluate(EvaluationRequest(
            event: event ?? exitOffice, now: now, clock: pragueClock, rules: rules, places: places, guards: guards,
            cooldowns: cooldowns, automationBudget: { budget }, inputs: inputs, requireTriggerMatch: requireTriggerMatch
        ))
    }

    func reason(_ e: Evaluation) -> String { e.verdicts.last?.reason ?? e.globalSkip ?? "" }

    // MARK: The spec's example rules

    func testLeavingWorkFiresOnAColdWeekdayEvening() async {
        let result = await evaluate([leavingWork], FakeInputs(weather: 3))
        XCTAssertEqual(result.winner, leavingWork)
        XCTAssertTrue(result.winnerVerdict!.reason.contains("3.0 °C"), result.winnerVerdict!.reason)
        XCTAssertEqual(result.winnerVerdict?.temperature?.celsius, 3)
    }

    func testLeavingWorkIsSkippedOutsideItsTimeWindowWithoutReadingTheCar() async {
        let inputs = FakeInputs(weather: 3)
        let result = await evaluate([leavingWork], inputs, now: wednesdayAt(15, 59))
        XCTAssertNil(result.winner)
        XCTAssertTrue(reason(result).contains("16:00–19:00"))
        XCTAssertEqual(inputs.vehicleReads, 0)
        XCTAssertTrue(inputs.weatherAt.isEmpty)
    }

    func testLeavingWorkIsSkippedAtTheWeekend() async {
        let result = await evaluate([leavingWork], FakeInputs(weather: 3), now: days(3, after: wednesdayAt(17)))
        XCTAssertNil(result.winner)
        XCTAssertTrue(reason(result).contains("today is Sat"), reason(result))
    }

    func testLeavingWorkIsSkippedWhenItIsNotCold() async {
        let result = await evaluate([leavingWork], FakeInputs(weather: 8))
        XCTAssertNil(result.winner)
        XCTAssertTrue(reason(result).contains("8.0 °C"), reason(result))
    }

    func testMorningCommuteUsesTheForecastAtDepartureTime() async {
        let morning = Templates.morningCommute(homeId: "home", id: "morning")
        let inputs = FakeInputs(vehicleState: snapshot(position: home.centre), forecast: 1.5, phone: home.centre)
        let result = await evaluate([morning], inputs, now: wednesdayAt(7, 20), event: .scheduleFired(time: TimeOfDay(7, 20)))
        XCTAssertEqual(result.winner, morning)
        XCTAssertEqual(inputs.forecastTimes, [wednesdayAt(7, 40)])
    }

    func testAForecastTimeMoreThanAnHourPastMeansTomorrow() async {
        let r = rule(trigger: .schedule(days: Weekday.weekdays, time: TimeOfDay(9, 0)), conditions: [.tempBelow(celsius: 3, source: .forecastAt(TimeOfDay(7, 40)))])
        let inputs = FakeInputs()
        _ = await evaluate([r], inputs, now: wednesdayAt(9), event: .scheduleFired(time: TimeOfDay(9, 0)))
        XCTAssertEqual(inputs.forecastTimes, [days(1, after: wednesdayAt(7, 40))])
    }

    func testMorningCommuteIsSkippedWhenTheCarIsNotAtHome() async {
        let morning = Templates.morningCommute(homeId: "home", id: "morning")
        let result = await evaluate([morning], FakeInputs(vehicleState: snapshot(position: office.centre)), now: wednesdayAt(7, 20), event: .scheduleFired(time: TimeOfDay(7, 20)))
        XCTAssertNil(result.winner)
        XCTAssertTrue(reason(result).contains("from Home"), reason(result))
    }

    func testHotDayCoolsWhenWeatherAtTheCarIsAbove24() async {
        let hot = Templates.hotDay(officeId: "office", id: "hot")
        let result = await evaluate([hot], FakeInputs(weather: 27), now: wednesdayAt(13))
        XCTAssertEqual(result.winner, hot)
    }

    // MARK: Guards

    func testLowStateOfChargeBlocksStart() async {
        let result = await evaluate([rule()], FakeInputs(vehicleState: snapshot(soc: 20)))
        XCTAssertNil(result.winner)
        XCTAssertTrue(reason(result).contains("SoC 20% below minimum 25%"))
    }

    func testLowStateOfChargeIsFineWhenPluggedIn() async {
        let result = await evaluate([rule()], FakeInputs(vehicleState: snapshot(soc: 10, plugged: true)))
        XCTAssertEqual(result.winner?.id, "r1")
    }

    func testUnknownStateOfChargeBlocksStartEvenWhenTheRuleProceedsOnUnknowns() async {
        let result = await evaluate([rule(proceedIfUnknown: true)], FakeInputs(vehicleState: snapshot(soc: nil, plugged: nil)))
        XCTAssertNil(result.winner)
        XCTAssertTrue(reason(result).contains("state of charge unknown"))
    }

    func testCustomMinimumSocIsRespected() async {
        let result = await evaluate([rule()], FakeInputs(vehicleState: snapshot(soc: 40)), guards: GuardSettings(minSocPercent: 50))
        XCTAssertNil(result.winner)
    }

    func testAlreadyRunningBlocksStart() async {
        let result = await evaluate([rule()], FakeInputs(vehicleState: snapshot(climate: .running)))
        XCTAssertNil(result.winner)
        XCTAssertTrue(reason(result).contains("already running (HEATING)"))
    }

    func testUnknownClimateStateBlocksStart() async {
        let result = await evaluate([rule()], FakeInputs(vehicleState: snapshot(climate: .unknown)))
        XCTAssertTrue(reason(result).contains("climatisation state unknown"))
    }

    func testUnavailableVehicleStateBlocksEveryAction() async {
        let result = await evaluate([rule()], FakeInputs(vehicleState: nil))
        XCTAssertNil(result.winner)
        XCTAssertEqual(reason(result), "vehicle state: unavailable")
    }

    func testStopNeedsClimateToBeRunningAndIgnoresSoc() async {
        let stop = rule(action: .stopClimate)
        let running = await evaluate([stop], FakeInputs(vehicleState: snapshot(soc: 5, climate: .running)))
        XCTAssertEqual(running.winner, stop)
        let off = await evaluate([stop], FakeInputs(vehicleState: snapshot(climate: .off)))
        XCTAssertTrue(reason(off).contains("already off"))
        let unknown = await evaluate([stop], FakeInputs(vehicleState: snapshot(climate: .unknown)))
        XCTAssertTrue(reason(unknown).contains("unknown"))
    }

    func testRuleCooldownBlocksWithoutReadingTheCar() async {
        let inputs = FakeInputs()
        let result = await evaluate([rule()], inputs, cooldowns: CooldownState(lastFiredByRule: ["r1": wednesdayAt(16, 30)]))
        XCTAssertNil(result.winner)
        XCTAssertTrue(reason(result).contains("rule cooldown: active until 17:30"), reason(result))
        XCTAssertEqual(inputs.vehicleReads, 0)
    }

    func testRuleCooldownExpires() async {
        let result = await evaluate([rule()], cooldowns: CooldownState(lastFiredByRule: ["r1": wednesdayAt(15, 59)]))
        XCTAssertEqual(result.winner?.id, "r1")
    }

    func testGlobalCooldownBlocksEveryRule() async {
        let result = await evaluate([rule("a"), rule("b")], cooldowns: CooldownState(lastAutomatedCommandAt: wednesdayAt(16, 50)))
        XCTAssertNil(result.winner)
        XCTAssertTrue(result.verdicts.allSatisfy { $0.reason.contains("global cooldown: active until 17:05") })
        XCTAssertEqual(result.verdicts.count, 2)
    }

    func testGlobalCooldownUsesTheConfiguredLength() async {
        let result = await evaluate([rule()], guards: GuardSettings(globalCooldown: 5 * 60), cooldowns: CooldownState(lastAutomatedCommandAt: wednesdayAt(16, 50)))
        XCTAssertEqual(result.winner?.id, "r1")
    }

    func testRateBudgetMustCoverTheReadAndTheCommand() async {
        let inputs = FakeInputs()
        let result = await evaluate([rule()], inputs, budget: 1)
        XCTAssertNil(result.winner)
        XCTAssertTrue(reason(result).contains("only 1 automation requests left, needs 2"))
        XCTAssertEqual(inputs.vehicleReads, 0)
    }

    func testAFreshCacheMeansOneRequestIsEnough() async {
        let inputs = FakeInputs(cached: true)
        let result = await evaluate([rule()], inputs, budget: 1)
        XCTAssertEqual(result.winner?.id, "r1")
        XCTAssertEqual(inputs.vehicleReads, 0)
    }

    func testPausedAutomationSkipsEverything() async {
        let result = await evaluate([rule()], guards: GuardSettings(automationPaused: true))
        XCTAssertEqual(result.globalSkip, "automation paused")
        XCTAssertTrue(result.verdicts.isEmpty)
    }

    func testHolidaysSkipEverything() async {
        let result = await evaluate([rule()], guards: GuardSettings(holidays: [CalendarDay(2026, 9, 23)]))
        XCTAssertEqual(result.globalSkip, "holiday 2026-09-23")
    }

    // MARK: Matching and ordering

    func testOnlyEnabledRulesForThisTriggerAreConsidered() async {
        let rules = [
            rule("disabled", enabled: false),
            rule("enter", trigger: .geofenceEnter(placeId: "office")),
            rule("home", trigger: .geofenceExit(placeId: "home")),
        ]
        let result = await evaluate(rules)
        XCTAssertEqual(result.globalSkip, "no enabled rules for this trigger")
    }

    func testHighestPriorityWinsAndLowerRulesAreNotEvaluated() async {
        let result = await evaluate([rule("low", priority: 1), rule("high", priority: 5)])
        XCTAssertEqual(result.winner?.id, "high")
        XCTAssertEqual(result.verdicts.map(\.ruleId), ["high"])
    }

    func testAFailingHigherRuleFallsThroughToTheNext() async {
        let rules = [
            rule("high", conditions: [.tempBelow(celsius: -10, source: .weatherAtCar)], priority: 5),
            rule("low", priority: 1),
        ]
        let result = await evaluate(rules)
        XCTAssertEqual(result.winner?.id, "low")
        XCTAssertEqual(result.verdicts.map(\.ruleId), ["high", "low"])
        XCTAssertFalse(result.verdicts[0].fired)
    }

    func testEqualPrioritiesAreOrderedByName() async {
        let result = await evaluate([rule("2", name: "b"), rule("1", name: "a")])
        XCTAssertEqual(result.winner?.id, "1")
    }

    func testApproachingAndEnteringTriggersMatchTheirOwnEvents() async {
        let approach = rule("approach", trigger: .approaching(placeId: "home", km: 5))
        let hit = await evaluate([approach], event: .approached(placeId: "home", km: 5))
        XCTAssertEqual(hit.winner?.id, "approach")
        let miss = await evaluate([approach], event: .approached(placeId: "home", km: 2))
        XCTAssertNil(miss.winner)
        let enter = rule("enter", trigger: .geofenceEnter(placeId: "home"))
        let entered = await evaluate([enter], event: .geofenceEntered(placeId: "home"))
        XCTAssertEqual(entered.winner?.id, "enter")
    }

    func testScheduleTriggersMatchOnlyOnTheirDays() async {
        let sched = rule(trigger: .schedule(days: [.thursday], time: TimeOfDay(17, 0)))
        let wednesday = await evaluate([sched], event: .scheduleFired(time: TimeOfDay(17, 0)))
        XCTAssertNil(wednesday.winner)
        let thursday = await evaluate([sched], now: days(1, after: wednesdayAt(17)), event: .scheduleFired(time: TimeOfDay(17, 0)))
        XCTAssertEqual(thursday.winner?.id, "r1")
    }

    func testDryRunsCanIgnoreTheTrigger() async {
        let result = await evaluate([rule(trigger: .geofenceEnter(placeId: "home"))], requireTriggerMatch: false)
        XCTAssertEqual(result.winner?.id, "r1")
    }

    // MARK: Conditions

    func testUnknownTemperatureFailsUnlessTheRuleProceedsOnUnknowns() async {
        let cond: [Condition] = [.tempBelow(celsius: 5, source: .weatherAtCar)]
        let failed = await evaluate([rule(conditions: cond)], FakeInputs(weather: nil))
        XCTAssertNil(failed.winner)
        XCTAssertTrue(reason(failed).contains("weather at car unavailable"))
        XCTAssertEqual(failed.verdicts[0].checks.last?.result, .unknown)

        let proceeded = await evaluate([rule(conditions: cond, proceedIfUnknown: true)], FakeInputs(weather: nil))
        XCTAssertEqual(proceeded.winner?.id, "r1")
        XCTAssertTrue(proceeded.winnerVerdict!.reason.contains("proceeding"))
    }

    func testWeatherIsCheckedBeforeTheCarIsReadWhenThePlaceGivesALocation() async {
        let inputs = FakeInputs(weather: 10)
        let result = await evaluate([rule(conditions: [.tempBelow(celsius: 5, source: .weatherAtCar), .socAtLeast(percent: 50)])], inputs)
        XCTAssertNil(result.winner)
        XCTAssertEqual(inputs.vehicleReads, 0)
        XCTAssertEqual(inputs.weatherAt, [office.usualParkingSpot!])
        XCTAssertTrue(reason(result).contains("usual spot at Office"), reason(result))
    }

    func testWeatherUsesTheCachedCarPositionWhenThereIsOne() async {
        let parked = LatLon(lat: 50.1, lon: 14.5)
        let inputs = FakeInputs(vehicleState: snapshot(position: parked), cached: true)
        _ = await evaluate([rule(conditions: [.tempBelow(celsius: 5, source: .weatherAtCar)])], inputs)
        XCTAssertEqual(inputs.weatherAt, [parked])
    }

    func testThePlaceCentreIsUsedWhenThePlaceHasNoUsualParkingSpot() async {
        let inputs = FakeInputs()
        let r = rule(trigger: .geofenceExit(placeId: "home"), conditions: [.tempBelow(celsius: 5, source: .weatherAtCar)])
        _ = await evaluate([r], inputs, event: .geofenceExited(placeId: "home"))
        XCTAssertEqual(inputs.weatherAt, [home.centre])
    }

    func testScheduleRulesWithoutAPlaceReadTheCarForItsPosition() async {
        let parked = LatLon(lat: 49.9, lon: 14.0)
        let inputs = FakeInputs(vehicleState: snapshot(position: parked))
        let r = rule(trigger: .schedule(days: Weekday.weekdays, time: TimeOfDay(17, 0)), conditions: [.tempBelow(celsius: 5, source: .weatherAtCar)])
        let result = await evaluate([r], inputs, event: .scheduleFired(time: TimeOfDay(17, 0)))
        XCTAssertEqual(result.winner?.id, "r1")
        XCTAssertEqual(inputs.vehicleReads, 1)
        XCTAssertEqual(inputs.weatherAt, [parked])
    }

    func testScheduleRulesWithoutAnyLocationHaveUnknownWeather() async {
        let inputs = FakeInputs(vehicleState: snapshot(position: nil))
        let r = rule(trigger: .schedule(days: Weekday.weekdays, time: TimeOfDay(17, 0)), conditions: [.tempBelow(celsius: 5, source: .weatherAtCar)])
        let result = await evaluate([r], inputs, event: .scheduleFired(time: TimeOfDay(17, 0)))
        XCTAssertNil(result.winner)
        XCTAssertTrue(inputs.weatherAt.isEmpty)
    }

    func testBestAvailablePrefersTheCarsOwnSensor() async {
        let inputs = FakeInputs(vehicleState: snapshot(outside: 1), weather: 10)
        let result = await evaluate([rule(conditions: [.tempBelow(celsius: 5, source: .bestAvailable)])], inputs)
        XCTAssertEqual(result.winner?.id, "r1")
        XCTAssertTrue(inputs.weatherAt.isEmpty)
        XCTAssertTrue(result.winnerVerdict!.reason.contains("car sensor"))
    }

    func testBestAvailableFallsBackToWeather() async {
        let result = await evaluate([rule(conditions: [.tempBelow(celsius: 5, source: .bestAvailable)])], FakeInputs(vehicleState: snapshot(outside: nil), weather: 1))
        XCTAssertEqual(result.winner?.id, "r1")
        XCTAssertTrue(result.winnerVerdict!.reason.contains("Open-Meteo"))
    }

    func testBestAvailableSkipsTheReadWhenTheCacheShowsNoCarSensor() async {
        let inputs = FakeInputs(vehicleState: snapshot(outside: nil), cached: true, weather: 9)
        _ = await evaluate([rule(conditions: [.tempBelow(celsius: 5, source: .bestAvailable)])], inputs)
        XCTAssertEqual(inputs.vehicleReads, 0)
        XCTAssertEqual(inputs.weatherAt.count, 1)
    }

    func testCarOutsideTemperatureIsUnknownWhenTheCarDoesNotReportIt() async {
        let result = await evaluate([rule(conditions: [.tempAbove(celsius: 20, source: .carOutside)])])
        XCTAssertTrue(reason(result).contains("car outside temp unavailable"))
    }

    func testTheCabinSensorIsUsedWhenInRange() async {
        let cond: [Condition] = [.tempAbove(celsius: 30, source: .cabinBle)]
        let none = await evaluate([rule(conditions: cond)], FakeInputs(cabin: nil))
        XCTAssertNil(none.winner)
        let hot = await evaluate([rule(conditions: cond)], FakeInputs(cabin: 35))
        XCTAssertEqual(hot.winner?.id, "r1")
        let mild = await evaluate([rule(conditions: cond)], FakeInputs(cabin: 25))
        XCTAssertNil(mild.winner)
    }

    func testSocAndPlugConditions() async {
        let soc = rule(conditions: [.socAtLeast(percent: 50)])
        let enough = await evaluate([soc], FakeInputs(vehicleState: snapshot(soc: 50)))
        XCTAssertEqual(enough.winner?.id, "r1")
        let low = await evaluate([soc], FakeInputs(vehicleState: snapshot(soc: 49)))
        XCTAssertTrue(reason(low).contains("49% < 50%"))
        let unknownSoc = await evaluate([soc], FakeInputs(vehicleState: snapshot(soc: nil, plugged: true)))
        XCTAssertTrue(reason(unknownSoc).contains("SoC unknown"))

        let plugged = rule(conditions: [.pluggedIn(expected: true)])
        let yes = await evaluate([plugged], FakeInputs(vehicleState: snapshot(plugged: true)))
        XCTAssertEqual(yes.winner?.id, "r1")
        let no = await evaluate([plugged], FakeInputs(vehicleState: snapshot(plugged: false)))
        XCTAssertNil(no.winner)
        let unknownPlug = await evaluate([plugged], FakeInputs(vehicleState: snapshot(plugged: nil)))
        XCTAssertTrue(reason(unknownPlug).contains("plug state unknown"))

        let unplugged = await evaluate([rule(conditions: [.pluggedIn(expected: false)])], FakeInputs(vehicleState: snapshot(plugged: false)))
        XCTAssertEqual(unplugged.winner?.id, "r1")
    }

    func testCarAtPlaceIsUnknownWithoutAParkingPositionAndFailsForADeletedPlace() async {
        let noPos = await evaluate([rule(conditions: [.carAtPlace(placeId: "home")])], FakeInputs(vehicleState: snapshot(position: nil)))
        XCTAssertTrue(reason(noPos).contains("parking position unavailable"))
        let gone = await evaluate([rule(conditions: [.carAtPlace(placeId: "gym")])])
        XCTAssertTrue(reason(gone).contains("no longer exists"))
        let atOffice = await evaluate([rule(conditions: [.carAtPlace(placeId: "office")])])
        XCTAssertEqual(atOffice.winner?.id, "r1")
    }

    func testTimeWindowsCanWrapPastMidnight() async {
        let night = rule(conditions: [.timeWindow(start: TimeOfDay(22, 0), end: TimeOfDay(6, 0))])
        let late = await evaluate([night], now: wednesdayAt(23))
        XCTAssertEqual(late.winner?.id, "r1")
        let early = await evaluate([night], now: wednesdayAt(5, 59))
        XCTAssertEqual(early.winner?.id, "r1")
        let six = await evaluate([night], now: wednesdayAt(6))
        XCTAssertNil(six.winner)
        let allDay = await evaluate([rule(conditions: [.timeWindow(start: .noon, end: .noon)])])
        XCTAssertEqual(allDay.winner?.id, "r1")
    }

    func testARuleWithNoConditionsFiresOnGuardsAlone() async {
        let result = await evaluate([rule()])
        XCTAssertEqual(result.winnerVerdict?.reason, "no conditions; guards passed")
    }

    // MARK: Near the car, phone near the car, temperature outside a range

    func testWeatherForANearCarRuleUsesTheCarsPosition() async {
        let parked = LatLon(lat: 50.10, lon: 14.50)
        let inputs = FakeInputs(vehicleState: snapshot(position: parked), cached: true, weather: 1)
        let r = rule(trigger: .nearCar(meters: 300), conditions: [.tempBelow(celsius: 5, source: .weatherAtCar)])
        let result = await evaluate([r], inputs, event: .approachedCar(meters: 300))
        XCTAssertEqual(result.winner?.id, "r1")
        XCTAssertEqual(inputs.weatherAt, [parked])
        XCTAssertEqual(inputs.vehicleReads, 0)
    }

    func testPhoneNearCar() async {
        let near = rule(conditions: [.phoneNearCar(meters: 500)])
        let close = await evaluate([near], FakeInputs(phone: LatLon(lat: office.centre.lat + 0.001, lon: office.centre.lon)))
        XCTAssertEqual(close.winner?.id, "r1")
        XCTAssertTrue(close.winnerVerdict!.reason.contains("phone 111 m from the car"), close.winnerVerdict!.reason)

        let far = await evaluate([near], FakeInputs(phone: home.centre))
        XCTAssertNil(far.winner)
        XCTAssertTrue(reason(far).contains("km from the car"), reason(far))

        let inputs = FakeInputs(phone: nil)
        let noPhone = await evaluate([near], inputs)
        XCTAssertTrue(reason(noPhone).contains("phone location unavailable"))
        XCTAssertEqual(inputs.vehicleReads, 0)
        var lenient = near
        lenient.proceedIfUnknown = true
        let proceeded = await evaluate([lenient], FakeInputs(phone: nil))
        XCTAssertEqual(proceeded.winner?.id, "r1")

        let noCar = await evaluate([near], FakeInputs(vehicleState: snapshot(position: nil)))
        XCTAssertTrue(reason(noCar).contains("car position unavailable"))
    }

    func testTempOutsideFiresWhenColdOrHotNotInBetween() async {
        let outside = rule(conditions: [.tempOutside(low: 16, high: 21, source: .weatherAtCar)])
        let cold = await evaluate([outside], FakeInputs(weather: 10))
        XCTAssertEqual(cold.winner?.id, "r1")
        XCTAssertTrue(cold.winnerVerdict!.reason.contains("< 16.0 °C"))
        let hot = await evaluate([outside], FakeInputs(weather: 27))
        XCTAssertTrue(hot.winnerVerdict!.reason.contains("> 21.0 °C"))
        let mild = await evaluate([outside], FakeInputs(weather: 18))
        XCTAssertNil(mild.winner)
        XCTAssertTrue(reason(mild).contains("within 16.0 °C–21.0 °C"), reason(mild))
        let unknown = await evaluate([outside], FakeInputs(weather: nil))
        XCTAssertTrue(reason(unknown).contains("unavailable"))
    }

    func testChecksReadLikeTheAndroidLog() async {
        let result = await evaluate([leavingWork], FakeInputs(weather: 3))
        let lines = result.winnerVerdict!.checks.map { "\($0.result.rawValue) \($0.name): \($0.detail)" }
        XCTAssertEqual(lines.first, "PASS rule cooldown: not active")
        XCTAssertTrue(lines.contains("PASS condition 16:00–19:00: now 17:00"), "\(lines)")
        XCTAssertTrue(lines.contains("PASS condition Mon–Fri: today is Wed"), "\(lines)")
        XCTAssertEqual(lines.last, "PASS not running: climatisation off")
    }
}

final class WeatherTests: XCTestCase {
    static let t0: Double = 1_790_000_000
    let time = MutableTime(Date(timeIntervalSince1970: WeatherTests.t0 + 1200))
    let server = ScriptedTransport()
    lazy var repo = WeatherRepository(transport: server, time: time)
    let here = LatLon(lat: 50.08712, lon: 14.42105)

    func respond() {
        let t0 = Int(Self.t0)
        server.respond("/v1/forecast", jsonResponse("""
        {"latitude":50.08,"longitude":14.42,
         "current":{"time":\(t0 + 900),"interval":900,"temperature_2m":3.4},
         "hourly":{"time":[\(t0),\(t0 + 3600),\(t0 + 7200)],"temperature_2m":[2.0,4.0,null]}}
        """))
    }

    func at(_ offset: Double) -> Date { Date(timeIntervalSince1970: Self.t0 + offset) }

    func testCurrentTemperatureAndRequestParameters() async throws {
        respond()
        let reading = await repo.current(at: here)
        XCTAssertEqual(reading?.celsius, 3.4)
        XCTAssertEqual(reading?.source, "Open-Meteo")
        let url = try XCTUnwrap(server.seen.first?.url.absoluteString)
        XCTAssertTrue(url.hasPrefix("https://api.open-meteo.com/v1/forecast?latitude=50.087&longitude=14.421&current=temperature_2m&hourly=temperature_2m"), url)
        XCTAssertTrue(url.contains("timeformat=unixtime"))
    }

    func testForecastInterpolatesBetweenHours() async {
        respond()
        let half = await repo.forecast(at: here, time: at(1800))
        XCTAssertEqual(half!.celsius, 3.0, accuracy: 0.001)
        let exact = await repo.forecast(at: here, time: at(0))
        XCTAssertEqual(exact!.celsius, 2.0, accuracy: 0.001)
        let justBefore = await repo.forecast(at: here, time: at(-600))
        XCTAssertEqual(justBefore!.celsius, 2.0, accuracy: 0.001)
        let longBefore = await repo.forecast(at: here, time: at(-7200))
        XCTAssertNil(longBefore)
        // The last hour has no value, so anything past the second point is out of range.
        let beyond = await repo.forecast(at: here, time: at(5000))
        XCTAssertNil(beyond)
    }

    func testCachedFor15MinutesPerLocation() async {
        respond()
        respond()
        _ = await repo.current(at: here)
        _ = await repo.current(at: LatLon(lat: 50.0872, lon: 14.4211)) // same ~100 m cell
        _ = await repo.forecast(at: here, time: at(0))
        XCTAssertEqual(server.seen.count, 1)
        time.advance(15 * 60)
        _ = await repo.current(at: here)
        XCTAssertEqual(server.seen.count, 2)
    }

    func testFailuresReturnNilAndAreRemembered() async {
        server.respond("/v1/forecast", jsonResponse("oops", status: 500))
        let failed = await repo.current(at: here)
        XCTAssertNil(failed)
        XCTAssertNotNil(repo.lastError)
        respond()
        let ok = await repo.current(at: here)
        XCTAssertNotNil(ok)
        XCTAssertNil(repo.lastError)
    }

    func testMissingValuesAreUnknown() async {
        server.respond("/v1/forecast", jsonResponse(#"{"current":{"time":\#(Int(Self.t0))},"hourly":{"time":[],"temperature_2m":[]}}"#))
        let current = await repo.current(at: here)
        XCTAssertNil(current)
        let forecast = await repo.forecast(at: here, time: at(0))
        XCTAssertNil(forecast)
    }

    func testFakeWeatherGivesAFlatForecast() async {
        let fake = FakeWeather(celsius: -2, time: time)
        let repo = WeatherRepository(transport: fake, time: time)
        let now = await repo.current(at: here)
        XCTAssertEqual(now?.celsius, -2)
        let later = await repo.forecast(at: here, time: at(20 * 3600))
        XCTAssertEqual(later?.celsius, -2)
        fake.celsius = 30
        time.advance(16 * 60)
        let changed = await repo.current(at: here)
        XCTAssertEqual(changed?.celsius, 30)
    }
}
