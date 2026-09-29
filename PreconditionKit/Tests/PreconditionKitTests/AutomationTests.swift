import Foundation
import XCTest
@testable import PreconditionKit

actor TextNotifier: Notifier {
    private(set) var sent: [String] = []
    private(set) var problems: [String] = []
    private(set) var asks: [String] = []
    func commandSent(title: String, text: String, canStop: Bool) { sent.append(text) }
    func ask(ruleId: String, title: String, text: String) { asks.append("\(ruleId): \(title) \(text)") }
    func problem(title: String, text: String, openSettings: Bool) { problems.append("\(title): \(text)") }
}

final class FixedWeather: WeatherSource, @unchecked Sendable {
    var celsius: Double?
    init(_ celsius: Double? = 3) { self.celsius = celsius }
    func current(at: LatLon) async -> TempReading? { celsius.map { TempReading(celsius: $0, source: "Open-Meteo", at: .distantPast) } }
    func forecast(at: LatLon, time: Date) async -> TempReading? { await current(at: at) }
}

final class MutableSettings: SettingsSource, @unchecked Sendable {
    var guardSettings = GuardSettings()
    func guards() async -> GuardSettings { guardSettings }
    func defaultTargetC() async -> Double { 21 }
    var prefs = ClimatePreferences()
    func climatePreferences() async -> ClimatePreferences { prefs }
}

final class MutablePhone: PhoneLocator, @unchecked Sendable {
    var at: LatLon?
    init(_ at: LatLon?) { self.at = at }
    func locate() async -> LatLon? { at }
}

/// Throws like a dead network while `down` is set.
final class Switchable: HTTPTransport, @unchecked Sendable {
    let inner: HTTPTransport
    var down = false
    init(_ inner: HTTPTransport) { self.inner = inner }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if down { throw URLError(.notConnectedToInternet) }
        return try await inner.send(request)
    }
}

/// Port of the Android `PreconditionEngineTest` (the automation half; the manual half is in EngineTests):
/// the real Kia client, budget, error mapping and evaluator against the fake car, following the spec's
/// acceptance criteria.
final class AutomationTests: XCTestCase {
    let time = MutableTime(wednesdayAt(17, 10))
    lazy var fake = FakeKia(state: FakeCarState(latitude: office.centre.lat, longitude: office.centre.lon), time: time)
    lazy var network = Switchable(fake)
    let budgetStore = InMemoryRateBudgetStore()
    lazy var budget = RateBudget(store: budgetStore, time: time, config: BudgetConfig(limit: 20, manualReserve: 4, window: 3600))
    let state = InMemoryAutomationStateStore()
    let log = InMemoryEventLog()
    let notifier = TextNotifier()
    lazy var monitor = ApiMonitor(state: state, notifier: notifier, log: log, time: time)
    let creds = TestCredentials(Credentials(refreshToken: KiaClientTests.refresh))
    lazy var client = KiaClient(transport: network, budget: budget, credentials: creds, sessions: InMemoryKiaSessionStore(), metaSink: monitor, time: time)
    let cache = InMemoryVehicleCache()
    lazy var vehicles = VehicleRepository(client: client, cache: cache, state: state, credentials: creds, log: log, time: time)
    let rules = InMemoryRulesStore(rules: [Templates.leavingWork(officeId: "office", id: "leave")], places: [office, home])
    let settings = MutableSettings()
    let weather = FixedWeather()
    /// Next to the fake car by default.
    let phone = MutablePhone(office.centre)
    lazy var engine = PreconditionEngine(
        client: client, vehicles: vehicles, budget: budget, state: state, settings: settings, log: log,
        notifier: notifier, time: time, rules: rules, weather: weather, phone: phone, localClock: { pragueClock },
        commandGap: 0
    )

    let exitOffice = TriggerEvent.geofenceExited(placeId: "office")

    func trigger(_ event: TriggerEvent? = nil, attempt: Attempt = Attempt()) async -> EngineOutcome {
        await engine.onTrigger(event ?? exitOffice, triggeredAt: time.now(), attempt: attempt)
    }

    func entries() async -> [LogEntry] { await log.entries() }
    func automationState() async -> AutomationState { await state.load() }
    func sent() async -> [SentRequest] { await budgetStore.state.sent }

    func isFired(_ o: EngineOutcome) -> Bool { if case .fired = o { return true }; return false }
    func isSkipped(_ o: EngineOutcome) -> Bool { if case .skipped = o { return true }; return false }
    func skipReason(_ o: EngineOutcome) -> String { if case .skipped(let r) = o { return r }; return "" }
    func retry(_ o: EngineOutcome) -> Retry? { if case .failed(_, let r) = o { return r }; return nil }

    // MARK: Acceptance: leaving the office below 5 °C starts heating

    func testLeavingTheOfficeOnAColdWeekdayEveningStartsHeating() async {
        let outcome = await trigger()
        XCTAssertTrue(isFired(outcome), "\(outcome)")
        XCTAssertTrue(fake.state.climateOn)
        XCTAssertEqual(fake.state.targetTempC, 21)
        let texts = await notifier.sent
        XCTAssertEqual(texts, ["Preconditioning to 21.0 °C — left Office, 3.0 °C (Leaving work)"])
        let log = await entries()
        XCTAssertEqual(log.reduce(0) { $0 + $1.requestsUsed }, 2)
        XCTAssertTrue(log.contains { $0.kind == .fired && $0.ruleId == "leave" })
        XCTAssertTrue(log.contains { $0.kind == .command && $0.httpCode == 200 })
        let fired = log.first { $0.kind == .fired }
        XCTAssertTrue(fired?.details?.contains("PASS condition Mon–Fri: today is Wed") == true, fired?.details ?? "")
        let s = await automationState()
        XCTAssertEqual(s.lastFiredByRule["leave"], time.now())
        XCTAssertEqual(s.lastAutomatedCommandAt, time.now())
        XCTAssertEqual(s.lastCommand?.automated, true)
    }

    func testAnAskFirstRuleAsksInsteadOfStartingAndOnlyOnce() async {
        var rule = Templates.leavingWork(officeId: "office", id: "leave")
        rule.askFirst = true
        await rules.set(rules: [rule])
        let outcome = await trigger()
        XCTAssertEqual(skipReason(outcome), "asked first")
        XCTAssertFalse(fake.state.climateOn, "nothing sent")
        let asks = await notifier.asks
        XCTAssertEqual(asks, ["leave: Leaving work: start climate to 21.0 °C? It's about 3.0 °C out. Hold for Start, In 15 min or Not today."])
        let sentTexts = await notifier.sent
        XCTAssertTrue(sentTexts.isEmpty)
        // Its cooldown has started: leaving again straight away doesn't ask twice.
        time.advance(20 * 60)
        _ = await trigger()
        let again = await notifier.asks
        XCTAssertEqual(again.count, 1)
    }

    func testAutomationHoldsTheChargerWhenPluggedInAndIdle() async {
        settings.prefs = ClimatePreferences(options: ClimateOptions(defrost: true), holdCharger: true)
        fake.state.pluggedIn = true
        fake.state.socPercent = 70
        let outcome = await trigger()
        XCTAssertTrue(isFired(outcome), "\(outcome)")
        XCTAssertTrue(fake.state.climateOn)
        XCTAssertFalse(fake.state.charging)
        let texts = await notifier.sent
        XCTAssertEqual(texts, ["Preconditioning to 21.0 °C — left Office, 3.0 °C, charger held (Leaving work)"])
        let log = await entries()
        XCTAssertEqual(log.reduce(0) { $0 + $1.requestsUsed }, 3)
        XCTAssertTrue(log.contains { $0.kind == .command && $0.reason.hasPrefix("stop charging accepted") && $0.trigger == "left Office" })
    }

    // MARK: Acceptance: guards are never bypassed and each case is logged

    func testNoCommandWhenSocIsBelowTheMinimum() async {
        fake.state.socPercent = 20
        let outcome = await trigger()
        XCTAssertTrue(isSkipped(outcome))
        XCTAssertFalse(fake.state.climateOn)
        let log = await entries()
        XCTAssertTrue(log.contains { $0.kind == .skipped && $0.reason.contains("SoC 20% below minimum 25%") })
        let texts = await notifier.sent
        XCTAssertTrue(texts.isEmpty)
    }

    func testNoCommandWhenClimateIsAlreadyOn() async {
        fake.state.climateOn = true
        let outcome = await trigger()
        XCTAssertTrue(isSkipped(outcome))
        let log = await entries()
        XCTAssertTrue(log.contains { $0.reason.contains("already running") })
    }

    func testNoCommandWhileACooldownIsActive() async {
        let first = await trigger()
        XCTAssertTrue(isFired(first))
        fake.state.climateOn = false
        time.advance(6 * 60) // past the dedup window, inside the global cooldown
        let second = await trigger()
        XCTAssertTrue(isSkipped(second))
        var last = await entries().last
        XCTAssertTrue(last!.reason.contains("cooldown"))
        time.advance(20 * 60) // past global, inside the rule's 60 min
        let third = await trigger()
        XCTAssertTrue(isSkipped(third))
        last = await entries().last
        XCTAssertTrue(last!.reason.contains("rule cooldown"))
    }

    // MARK: Acceptance: automation never uses more than limit − reserve

    func testAutomationNeverUsesMoreThanLimitMinusTheReserve() async {
        // A rule that always passes and never cools down, triggered far more often than the budget allows.
        await rules.set(rules: [rule("spam", cooldownMinutes: 0)])
        settings.guardSettings = GuardSettings(globalCooldown: 0)
        for _ in 0..<40 {
            fake.state.climateOn = false
            await cache.save(nil) // force a read every time
            time.advance(60)
            _ = await engine.onTrigger(exitOffice, triggeredAt: time.now(), attempt: Attempt(vehicleBusyRetry: true))
        }
        let automation = await sent().filter { $0.kind == .automation }
        XCTAssertEqual(automation.count, 16)
        let log = await entries()
        XCTAssertEqual(log.reduce(0) { $0 + $1.requestsUsed }, 16)
        XCTAssertTrue(log.contains { $0.reason.contains("rate budget") })
        // The manual reserve is intact.
        let manual = await budget.available(.manual)
        XCTAssertEqual(manual, 4)
        let stop = await engine.manualStop()
        XCTAssertEqual(stop, .sent("stop climatisation"))
    }

    // MARK: Acceptance: a rejected login stops automation within one attempt

    func testARejectedRefreshTokenStopsAutomationAndNotifies() async {
        fake.state.scenario = .refreshTokenRejected
        let outcome = await trigger()
        XCTAssertEqual(outcome, .failed(.loginFailed(reason: "Kia rejected the refresh token"), .none))
        var s = await automationState()
        XCTAssertEqual(s.authFailure, "Kia rejected the refresh token")
        var problems = await notifier.problems
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].hasPrefix("Automation stopped"))

        // Later triggers don't even try.
        fake.state.scenario = .none
        time.advance(600)
        let next = await trigger(.geofenceExited(placeId: "home"))
        XCTAssertTrue(skipReason(next).hasPrefix("automation stopped"), "\(next)")
        problems = await notifier.problems
        XCTAssertEqual(problems.count, 1)

        // A successful manual request proves the login works again and resumes automation.
        let refresh = await engine.refreshVehicle()
        XCTAssertNotNil(refresh.value)
        s = await automationState()
        XCTAssertNil(s.authFailure)
    }

    func testALoginRejectedOnTheCommandAlsoStopsAutomation() async {
        _ = await vehicles.fetch(.manual)
        fake.state.scenario = .accessTokenRejected
        let outcome = await trigger()
        XCTAssertNotNil(retry(outcome))
        let s = await automationState()
        XCTAssertNotNil(s.authFailure)
    }

    // MARK: Error handling

    func testAnUnsupportedOperationDisablesTheRule() async {
        fake.state.scenario = .notSupported
        let outcome = await trigger()
        XCTAssertEqual(retry(outcome), Retry.none)
        let disabled = await rules.disabled
        XCTAssertNotNil(disabled["leave"])
        let r = await rules.rules()
        XCTAssertFalse(r[0].enabled)
        let problems = await notifier.problems
        XCTAssertTrue(problems.first?.hasPrefix("Rule disabled") == true)
    }

    func testABusyCarRetriesOnceThenGivesUp() async {
        _ = await vehicles.fetch(.manual)
        fake.state.scenario = .vehicleBusy
        let first = await trigger()
        XCTAssertEqual(retry(first), .vehicleBusy)
        var s = await automationState()
        XCTAssertEqual(s.consecutiveFailures, 0)

        time.advance(120)
        let second = await trigger(attempt: Attempt(vehicleBusyRetry: true))
        XCTAssertEqual(retry(second), Retry.none)
        s = await automationState()
        XCTAssertEqual(s.consecutiveFailures, 1)
    }

    func testANetworkFailureAsksForABackoffRetryUntilTheLastAttempt() async {
        network.down = true
        let first = await trigger(attempt: Attempt(number: 0, isLast: false))
        XCTAssertEqual(retry(first), .backoff)
        network.down = false
        time.advance(30)
        let second = await trigger(attempt: Attempt(number: 1, isLast: false))
        XCTAssertTrue(isFired(second), "\(second)")
    }

    func testANetworkFailureOnTheLastAttemptIsFinal() async {
        network.down = true
        let outcome = await trigger(attempt: Attempt(number: 2, isLast: true))
        XCTAssertEqual(retry(outcome), Retry.none)
        let s = await automationState()
        XCTAssertEqual(s.consecutiveFailures, 1)
        let problems = await notifier.problems
        XCTAssertTrue(problems.first?.contains("Reading the car failed") == true, "\(problems)")
    }

    func testThreeConsecutiveFailuresPauseAutomation() async {
        _ = await vehicles.fetch(.manual)
        await rules.set(rules: [rule("r", cooldownMinutes: 0)])
        settings.guardSettings = GuardSettings(globalCooldown: 0)
        fake.state.scenario = .serverError
        for _ in 0..<3 {
            time.advance(360)
            _ = await trigger()
        }
        var s = await automationState()
        XCTAssertTrue(s.pausedAfterFailures)
        let problems = await notifier.problems
        XCTAssertTrue(problems.last?.hasPrefix("Automation paused") == true, "\(problems)")

        fake.state.scenario = .none
        time.advance(360)
        let paused = await trigger()
        XCTAssertTrue(skipReason(paused).contains("paused after 3"), "\(paused)")

        await engine.resumeAutomation()
        time.advance(360)
        let resumed = await trigger()
        XCTAssertTrue(isFired(resumed), "\(resumed)")
        s = await automationState()
        XCTAssertEqual(s.consecutiveFailures, 0)
    }

    func testTheRetryLoopRetriesInProcess() async {
        network.down = true
        let net = network
        let slept = Locked<[TimeInterval]>([])
        let outcome = await engine.onTriggerWithRetries(exitOffice, triggeredAt: time.now(), backoff: [15, 45]) { delay in
            slept.withLock { $0.append(delay) }
            if slept.current.count == 2 { net.down = false }
        }
        XCTAssertTrue(isFired(outcome), "\(outcome)")
        XCTAssertEqual(slept.current, [15, 45])
    }

    func testTheRetryLoopGivesABusyCarOneMoreTry() async {
        _ = await vehicles.fetch(.manual)
        fake.state.scenario = .vehicleBusy
        let slept = Locked<[TimeInterval]>([])
        let outcome = await engine.onTriggerWithRetries(exitOffice, triggeredAt: time.now()) { delay in
            slept.withLock { $0.append(delay) }
        }
        XCTAssertEqual(retry(outcome), Retry.none)
        XCTAssertEqual(slept.current, [120])
    }

    // MARK: Trigger handling

    func testRepeatedGeofenceEventsWithinFiveMinutesAreIgnored() async {
        await rules.set(rules: [rule("r", conditions: [.tempBelow(celsius: -20, source: .weatherAtCar)])])
        _ = await trigger()
        time.advance(120)
        let second = await trigger()
        XCTAssertTrue(skipReason(second).contains("duplicate"))
        time.advance(200)
        let third = await trigger()
        XCTAssertFalse(skipReason(third).contains("duplicate"))
    }

    func testScheduleEventsAreNeverDeduplicated() async {
        await rules.set(rules: [rule("s", trigger: .schedule(days: Weekday.everyDay, time: TimeOfDay(17, 10)), conditions: [.tempBelow(celsius: -20, source: .weatherAtCar)])])
        _ = await trigger(.scheduleFired(time: TimeOfDay(17, 10)))
        let again = await trigger(.scheduleFired(time: TimeOfDay(17, 10)))
        XCTAssertFalse(skipReason(again).contains("duplicate"))
    }

    func testStaleTriggersAreAbandoned() async {
        let outcome = await engine.onTrigger(exitOffice, triggeredAt: time.now().addingTimeInterval(-31 * 60))
        XCTAssertTrue(skipReason(outcome).contains("abandoned"))
        let s = await sent()
        XCTAssertTrue(s.isEmpty)
    }

    func testSkippedRulesCostNoRequestsWhenCheapChecksFail() async {
        let noon = MutableTime(wednesdayAt(12))
        let engineAtNoon = PreconditionEngine(
            client: client, vehicles: vehicles, budget: budget, state: state, settings: settings, log: log,
            notifier: notifier, time: noon, rules: rules, weather: weather, phone: phone, localClock: { pragueClock }
        )
        let outcome = await engineAtNoon.onTrigger(exitOffice, triggeredAt: noon.now())
        XCTAssertTrue(isSkipped(outcome))
        let s = await sent()
        XCTAssertTrue(s.isEmpty)
    }

    func testAFreshCacheSavesTheStateRead() async {
        _ = await vehicles.fetch(.manual)
        time.advance(300)
        _ = await trigger()
        let automation = await sent().filter { $0.kind == .automation }
        XCTAssertEqual(automation.count, 1)
    }

    // MARK: Dry run

    func testTestNowEvaluatesWithoutSending() async {
        time.advance(20 * 60)
        let evaluation = await engine.dryRun(ruleId: "leave")
        XCTAssertEqual(evaluation?.winner?.id, "leave")
        XCTAssertFalse(fake.state.climateOn)
        let log = await entries()
        XCTAssertTrue(log.contains { $0.kind == .dryRun && $0.decision == "would fire" })
        let s = await sent()
        XCTAssertTrue(s.allSatisfy { $0.kind == .manual })
        let missing = await engine.dryRun(ruleId: "missing")
        XCTAssertNil(missing)
    }

    func testTestNowWorksOnAnUnsavedDraftWhateverItsTrigger() async {
        let draft = rule("draft", trigger: .geofenceEnter(placeId: "home"), conditions: [.socAtLeast(percent: 90)], enabled: false)
        let evaluation = await engine.dryRun(draft)
        XCTAssertNil(evaluation.winner)
        XCTAssertTrue(evaluation.verdicts[0].reason.contains("SoC 62% < 90%"), evaluation.verdicts[0].reason)
        let log = await entries()
        XCTAssertTrue(log.contains { $0.decision == "would skip" && $0.trigger == "test now" })
    }

    // MARK: Stop rules and the phone

    func testStopRulesStopClimate() async {
        await rules.set(rules: [rule("stop", trigger: .geofenceEnter(placeId: "home"), action: .stopClimate)])
        fake.state.climateOn = true
        let outcome = await trigger(.geofenceEntered(placeId: "home"))
        XCTAssertTrue(isFired(outcome))
        XCTAssertFalse(fake.state.climateOn)
        let texts = await notifier.sent
        XCTAssertEqual(texts, ["Climatisation stopped — arrived at Home (stop)"])
    }

    func testLeavingWorkIsSkippedWhenThePhoneIsNotWithTheCar() async {
        phone.at = LatLon(lat: 48.2, lon: 16.4) // Vienna; the car is at the office in Prague
        let outcome = await trigger()
        XCTAssertTrue(isSkipped(outcome))
        XCTAssertFalse(fake.state.climateOn)
        let log = await entries()
        XCTAssertTrue(log.contains { $0.reason.contains("phone within 1.5 km of the car") && $0.reason.contains("km from the car") })
    }

    func testMorningCommuteIsSkippedOnHolidayWithTheCarAtHome() async {
        fake.state.latitude = home.centre.lat
        fake.state.longitude = home.centre.lon
        await rules.set(rules: [Templates.morningCommute(homeId: "home", id: "morning")])
        let morning = MutableTime(wednesdayAt(7, 20))
        let engine = PreconditionEngine(
            client: KiaClient(transport: fake, budget: budget, credentials: creds, sessions: InMemoryKiaSessionStore(), metaSink: monitor, time: morning),
            vehicles: vehicles, budget: budget, state: state, settings: settings, log: log,
            notifier: notifier, time: morning, rules: rules, weather: weather, phone: phone, localClock: { pragueClock }
        )
        weather.celsius = -2
        let event = TriggerEvent.scheduleFired(time: TimeOfDay(7, 20))

        phone.at = LatLon(lat: 28.1, lon: -15.4) // Gran Canaria
        let away = await engine.onTrigger(event, triggeredAt: morning.now())
        XCTAssertTrue(isSkipped(away), "\(away)")

        phone.at = home.centre
        morning.advance(60)
        let there = await engine.onTrigger(event, triggeredAt: morning.now())
        XCTAssertTrue(isFired(there), "\(there)")
    }

    // MARK: Near-car position refresh

    func testTheCarPositionIsRefreshedOnlyWhenANearCarRuleNeedsIt() async {
        var read = await engine.refreshCarPositionIfDue()
        XCTAssertFalse(read)
        var s = await sent()
        XCTAssertTrue(s.isEmpty)

        await rules.set(rules: [rule("near", trigger: .nearCar(meters: 300))])
        read = await engine.refreshCarPositionIfDue()
        XCTAssertTrue(read)
        s = await sent()
        XCTAssertEqual(s.map(\.kind), [.automation])
        let cached = await cache.load()
        XCTAssertEqual(cached?.parked, true)
        var log = await entries()
        XCTAssertTrue(log.contains { $0.reason == "car position refreshed for near-car rules" && $0.requestsUsed == 1 })

        // Fresh enough: no second read.
        time.advance(3600)
        read = await engine.refreshCarPositionIfDue()
        XCTAssertFalse(read)
        time.advance(2 * 3600 + 1)
        read = await engine.refreshCarPositionIfDue()
        XCTAssertTrue(read)
        log = await entries()
        XCTAssertEqual(log.filter { $0.decision == "position" && $0.requestsUsed == 1 }.count, 2)
    }

    func testThePositionRefreshLeavesRoomForACycleAndRespectsAStop() async {
        await rules.set(rules: [rule("near", trigger: .nearCar(meters: 300))])
        // 14 of automation's 16 already used: only 2 left.
        await budgetStore.save(RateBudgetState(sent: (1...14).map { SentRequest(id: Int64($0), at: time.now(), kind: .automation, completed: true) }, nextId: 15))
        var read = await engine.refreshCarPositionIfDue()
        XCTAssertFalse(read)
        await budgetStore.save(RateBudgetState())
        await state.update { $0.authFailure = "Kia rejected the refresh token" }
        read = await engine.refreshCarPositionIfDue()
        XCTAssertFalse(read)
        let s = await sent()
        XCTAssertTrue(s.isEmpty)
    }

    func testAFailedPositionRefreshIsLogged() async {
        await rules.set(rules: [rule("near", trigger: .nearCar(meters: 300))])
        fake.state.scenario = .serverError
        let read = await engine.refreshCarPositionIfDue()
        XCTAssertFalse(read)
        let last = await entries().last
        XCTAssertTrue(last?.reason.hasPrefix("car position refresh failed") == true, last?.reason ?? "")
    }

    func testApproachingTheCarFiresItsRule() async {
        await rules.set(rules: [rule("near", trigger: .nearCar(meters: 300))])
        let outcome = await trigger(.approachedCar(meters: 300))
        XCTAssertTrue(isFired(outcome))
        XCTAssertTrue(fake.state.climateOn)
    }
}

final class RulesStoreTests: XCTestCase {
    func testFileRulesStoreSavesDeletesMergesAndProtectsUsedPlaces() async throws {
        let dir = temporaryDirectory()
        let store = FileRulesStore(url: dir.appendingPathComponent("rules.json"))
        await store.save(office)
        await store.save(home)
        await store.save(Templates.hotDay(officeId: "office", id: "hot"))
        var r = Templates.hotDay(officeId: "office", id: "hot")
        r.name = "Very hot day"
        await store.save(r)
        var rules = await store.rules()
        XCTAssertEqual(rules.map(\.name), ["Very hot day"])

        let users = await store.deletePlace(id: "office")
        XCTAssertEqual(users, ["Very hot day"])
        var placeList = await store.places()
        XCTAssertEqual(placeList.count, 2)
        let none = await store.deletePlace(id: "home")
        XCTAssertEqual(none, [])
        placeList = await store.places()
        XCTAssertEqual(placeList.map(\.id), ["office"])

        await store.disableRule(id: "hot", reason: "unsupported")
        rules = await store.rules()
        XCTAssertFalse(rules[0].enabled)

        let imported = RuleJSON.import(RuleJSON.export(places: [home], rules: [Templates.leavingWork(officeId: "office", id: "leave")]), existingPlaceIds: ["office"])
        await store.merge(imported)
        rules = await store.rules()
        XCTAssertEqual(rules.map(\.id), ["hot", "leave"])

        // Survives a restart, in the backup format.
        let again = FileRulesStore(url: dir.appendingPathComponent("rules.json"))
        let bundle = await again.bundle()
        XCTAssertEqual(bundle.rules.count, 2)
        XCTAssertEqual(bundle.places.count, 2)
        let text = try String(contentsOf: dir.appendingPathComponent("rules.json"), encoding: .utf8)
        XCTAssertTrue(RuleJSON.import(text).ok)
        await store.deleteRule(id: "hot")
        rules = await store.rules()
        XCTAssertEqual(rules.map(\.id), ["leave"])
        try? FileManager.default.removeItem(at: dir)
    }
}
