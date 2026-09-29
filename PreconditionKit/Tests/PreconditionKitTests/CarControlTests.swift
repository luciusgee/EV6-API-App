import Foundation
import XCTest
@testable import PreconditionKit

/// Charging, locks, charge limits, climate extras and driving history: payloads, mapping and the fake car.
final class CarControlClientTests: XCTestCase {
    let time = MutableTime()
    let server = ScriptedTransport()
    let creds = TestCredentials(Credentials(refreshToken: KiaClientTests.refresh, pin: "1234"))
    lazy var client = KiaClient(
        transport: server,
        budget: RateBudget(store: InMemoryRateBudgetStore(), time: time),
        credentials: creds,
        sessions: InMemoryKiaSessionStore(),
        time: time
    )
    let ok = jsonResponse(#"{"retCode":"S","resCode":"0000","resMsg":{},"msgId":"m1"}"#)

    override func setUp() {
        super.setUp()
        server.setDefault("/oauth2/token", jsonResponse(KiaClientTests.tokenOK))
        server.setDefault("/notifications/register", okResponse(#"{"deviceId":"dev-1"}"#))
        server.setDefault("/spa/vehicles", okResponse(KiaClientTests.vehiclesLegacy))
        server.setDefault("/user/pin", jsonResponse(#"{"controlToken":"ctl-1","expiresTime":600}"#))
        for path in ["/control/temperature", "/control/charge", "/control/door", "/charge/target"] {
            server.setDefault(path, ok)
        }
    }

    func testChargeAndDoorCommandsOnAnOlderCar() async throws {
        await expectSuccess(await client.send(.stopCharging, kind: .manual))
        XCTAssertEqual(body(server.last("/control/charge")), ["action": "stop", "deviceId": "dev-1"])
        await expectSuccess(await client.send(.startCharging, kind: .manual))
        XCTAssertEqual(body(server.last("/control/charge"))?["action"], "start")
        await expectSuccess(await client.send(.lock, kind: .manual))
        XCTAssertEqual(body(server.last("/control/door")), ["action": "close", "deviceId": "dev-1"])
        await expectSuccess(await client.send(.unlock, kind: .manual))
        XCTAssertEqual(body(server.last("/control/door"))?["action"], "open")
        XCTAssertEqual(server.last("/control/door")?.header("Authorization"), "Bearer acc-1")
    }

    func testCCS2CommandsUseTheControlToken() async throws {
        server.setDefault("/spa/vehicles", okResponse(KiaClientTests.vehiclesCcs2))
        await expectSuccess(await client.send(.stopCharging, kind: .manual))
        let charge = try XCTUnwrap(server.last("/ccs2/control/charge"))
        XCTAssertTrue(charge.url.path.contains("/api/v2/spa/"))
        XCTAssertEqual(charge.header("Authorization"), "Bearer ctl-1")
        XCTAssertEqual(body(charge), ["command": "stop"])
        await expectSuccess(await client.send(.lock, kind: .manual))
        XCTAssertEqual(body(server.last("/ccs2/control/door")), ["command": "close"])
    }

    func testChargeLimitsAreClampedToTensAndSentPerPlugType() async throws {
        await expectSuccess(await client.send(.setChargeLimits(ac: 84, dc: 40), kind: .manual))
        let list = body(server.last("/charge/target"))?["targetSOClist"]?.array ?? []
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first { $0["plugType"] == 1 }?["targetSOClevel"], 80)
        XCTAssertEqual(list.first { $0["plugType"] == 0 }?["targetSOClevel"], 50)
        XCTAssertEqual(KiaClient.chargeLimit(105), 100)
        XCTAssertEqual(KiaClient.chargeLimit(95), 100)
        XCTAssertEqual(KiaClient.chargeLimit(64), 60)
    }

    func testClimateExtrasOnBothProtocols() async throws {
        await expectSuccess(await client.startClimate(targetC: 21, kind: .manual, options: ClimateOptions(defrost: true, heatedExtras: true)))
        let legacy = try XCTUnwrap(body(server.last("/control/temperature")))
        XCTAssertEqual(legacy.path("options.defrost"), true)
        XCTAssertEqual(legacy.path("options.heating1"), 1)

        await expectSuccess(await client.startClimate(targetC: 21, kind: .manual))
        XCTAssertEqual(body(server.last("/control/temperature"))?.path("options.heating1"), 0)

        server.setDefault("/spa/vehicles", okResponse(KiaClientTests.vehiclesCcs2))
        let fresh = KiaClient(
            transport: server, budget: RateBudget(store: InMemoryRateBudgetStore(), time: time),
            credentials: creds, sessions: InMemoryKiaSessionStore(), time: time
        )
        await expectSuccess(await fresh.startClimate(targetC: 21, kind: .manual, options: ClimateOptions(defrost: true, heatedExtras: true)))
        let ccs2 = try XCTUnwrap(body(server.last("/ccs2/control/temperature")))
        XCTAssertEqual(ccs2["windshieldFrontDefogState"], true)
        XCTAssertEqual(ccs2["strgWhlHeating"], 1)
    }

    func testDrivingHistoryParsesDaysAndTotals() async throws {
        server.respond(
            "/drvhistory",
            okResponse(#"{"drivingInfo":[{"drivingPeriod":1,"totalPwrCsp":3120000,"regenPwr":610000}]}"#),
            okResponse("""
            {"drivingInfo":[{"drivingPeriod":0,"totalPwrCsp":20000,"calculativeOdo":100}],
             "drivingInfoDetail":[
               {"drivingDate":"20260927","totalPwrCsp":12000,"motorPwrCsp":9000,"climatePwrCsp":2000,"eDPwrCsp":800,"batteryMgPwrCsp":200,"regenPwr":1500,"calculativeOdo":60},
               {"drivingDate":"20260926","totalPwrCsp":8000,"motorPwrCsp":6000,"climatePwrCsp":1000,"eDPwrCsp":800,"batteryMgPwrCsp":200,"regenPwr":900,"calculativeOdo":40}
             ]}
            """)
        )
        let fetched = await expectSuccess(await client.drivingHistory(.manual))
        let history = try XCTUnwrap(fetched)
        XCTAssertEqual(server.seen.filter { $0.url.path.hasSuffix("/drvhistory") }.map { body($0)?["periodTarget"] }, [1, 0])
        XCTAssertEqual(history.lifetimeConsumedWh, 3_120_000)
        XCTAssertEqual(history.lifetimeRegenWh, 610_000)
        XCTAssertEqual(history.days.map(\.day), [CalendarDay(2026, 9, 26), CalendarDay(2026, 9, 27)])
        XCTAssertEqual(history.totalDistanceKm, 100)
        XCTAssertEqual(history.kWhPer100km ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(history.climateShare ?? 0, 0.15, accuracy: 0.001)
        XCTAssertEqual(history.average30dWhPerKm, 200)
        XCTAssertEqual(history.days.last?.kWhPer100km ?? 0, 20, accuracy: 0.001)
    }

    func testLegacyDetailsMap() throws {
        let status = try XCTUnwrap(JSONValue.parse(Data("""
        {"resMsg":{"vehicleStatusInfo":{
          "vehicleStatus":{
            "doorLock":false,
            "doorOpen":{"frontLeft":1,"frontRight":0,"backLeft":0,"backRight":0},
            "windowOpen":{"frontLeft":0,"frontRight":0,"backLeft":0,"backRight":1},
            "trunkOpen":true,"hoodOpen":false,
            "battery":{"batSoc":55},
            "tirePressureLamp":{"tirePressureLampAll":1,"tirePressureLampFL":0,"tirePressureLampFR":1,"tirePressureLampRL":0,"tirePressureLampRR":0},
            "steerWheelHeat":1,"defrost":true,
            "evStatus":{
              "batterySoh":96.5,"chargePortDoorOpenStatus":1,
              "reservChargeInfos":{"targetSOClist":[{"plugType":0,"targetSOClevel":90},{"plugType":1,"targetSOClevel":70},{"plugType":1,"targetSOClevel":80}]}
            }
          },
          "odometer":{"value":1000,"unit":3}
        }}}
        """.utf8)))
        let d = try XCTUnwrap(KiaMapper.toSnapshot(status: status, park: nil, ccs2: false, fetchedAt: t0).details)
        XCTAssertEqual(d.locked, false)
        XCTAssertEqual(d.openDoors, ["front left"])
        XCTAssertEqual(d.openWindows, ["rear right"])
        XCTAssertEqual(d.trunkOpen, true)
        XCTAssertEqual(d.hoodOpen, false)
        XCTAssertEqual(d.auxBatteryPercent, 55)
        XCTAssertEqual(d.tyreWarning, true)
        XCTAssertEqual(d.tyreWarnings, ["front right"])
        XCTAssertEqual(d.chargeLimitAC, 80) // the last entry for a plug type wins
        XCTAssertEqual(d.chargeLimitDC, 90)
        XCTAssertEqual(d.chargePortOpen, true)
        XCTAssertEqual(d.batteryHealthPercent, 96.5)
        XCTAssertEqual(d.steeringWheelHeatOn, true)
        XCTAssertEqual(d.defrostOn, true)
        XCTAssertEqual(d.odometerKm ?? 0, 1609.344, accuracy: 0.001)
        XCTAssertEqual(d.alerts, [
            "Door open: front left", "Boot open", "Window open: rear right",
            "Low tyre pressure: front right", "12 V battery at 55%",
        ])
    }

    func testCcs2DetailsMap() throws {
        let status = try XCTUnwrap(JSONValue.parse(Data("""
        {"resMsg":{"state":{"Vehicle":{
          "Drivetrain":{"Odometer":20500.2},
          "Electronics":{"Battery":{"Level":91}},
          "Cabin":{
            "Door":{"Row1":{"Driver":{"Open":0,"Lock":0},"Passenger":{"Open":0,"Lock":0}},"Row2":{"Left":{"Open":0,"Lock":0},"Right":{"Open":0,"Lock":0}}},
            "SteeringWheel":{"Heat":{"State":0}}
          },
          "Body":{"Trunk":{"Open":0},"Hood":{"Open":0},"Windshield":{"Front":{"Defog":{"State":1}}}},
          "Chassis":{"Axle":{"Row2":{"Left":{"Tire":{"PressureLow":1}}}}},
          "Green":{
            "ChargingDoor":{"State":2},
            "ChargingInformation":{"TargetSoC":{"Standard":80,"Quick":90}},
            "BatteryManagement":{"SoH":{"Ratio":98}}
          }
        }}}}
        """.utf8)))
        let d = try XCTUnwrap(KiaMapper.toSnapshot(status: status, park: nil, ccs2: true, fetchedAt: t0).details)
        XCTAssertEqual(d.locked, true)
        XCTAssertEqual(d.odometerKm, 20500.2)
        XCTAssertEqual(d.auxBatteryPercent, 91)
        XCTAssertEqual(d.tyreWarnings, ["rear left"])
        XCTAssertEqual(d.chargeLimitAC, 80)
        XCTAssertEqual(d.chargeLimitDC, 90)
        XCTAssertEqual(d.chargePortOpen, false)
        XCTAssertEqual(d.batteryHealthPercent, 98)
        XCTAssertEqual(d.defrostOn, true)
        XCTAssertEqual(d.steeringWheelHeatOn, false)
        XCTAssertTrue(d.openDoors.isEmpty)
    }

    func testOldCachedSnapshotsStillDecode() throws {
        let json = #"{"climate":"OFF","fetchedAt":"2026-09-23T15:58:00Z","socPercent":50}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let s = try d.decode(VehicleSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(s.socPercent, 50)
        XCTAssertNil(s.details)
        let details = try d.decode(VehicleDetails.self, from: Data(#"{"locked":true}"#.utf8))
        XCTAssertEqual(details.locked, true)
        XCTAssertEqual(details.openDoors, [])
    }
}

/// The dashboard's commands and the "keep the charger off" climate start, against the fake car.
final class CarControlEngineTests: XCTestCase {
    let time = MutableTime()
    let live = ScriptedTransport()
    let notifier = RecordingNotifier()
    lazy var container = AppContainer(
        directory: temporaryDirectory(),
        credentials: InMemoryCredentialsStore(Credentials(refreshToken: KiaClientTests.refresh)),
        sessions: InMemoryKiaSessionStore(),
        fakeSessions: InMemoryKiaSessionStore(),
        notifier: notifier,
        live: live,
        time: time,
        commandGap: 0
    )
    var engine: PreconditionEngine { container.engine }
    var fake: FakeKia { container.fakeCar }

    override func setUp() async throws {
        try await super.setUp()
        await container.stores.settings.save(AppSettings(fakeMode: true))
        await container.start()
    }

    override func tearDown() {
        XCTAssertTrue(live.seen.isEmpty, "fake-car mode must never reach Kia")
        super.tearDown()
    }

    func entries() async -> [LogEntry] { await container.stores.log.entries() }

    /// The morning problem: the car is plugged in, charging finished or waiting for off-peak.
    func pluggedInAndIdle() {
        fake.state.pluggedIn = true
        fake.state.charging = false
        fake.state.socPercent = 70
    }

    func testTheFakeCarWakesTheChargerWhenClimateStartsLikeTheRealOne() async {
        pluggedInAndIdle()
        await container.stores.settings.save(AppSettings(fakeMode: true, holdChargerOnClimate: false))
        let outcome = await engine.manualStart(targetC: 21)
        XCTAssertEqual(outcome, .sent("climatise to 21.0 °C"))
        XCTAssertTrue(fake.state.climateOn)
        XCTAssertTrue(fake.state.charging, "without the hold, climate starts a charge")
    }

    func testStopsTheChargerFirstWhenPluggedInAndIdle() async {
        pluggedInAndIdle()
        let outcome = await engine.manualStart(targetC: 21)
        XCTAssertEqual(outcome, .sent("climatise to 21.0 °C"))
        XCTAssertTrue(fake.state.climateOn)
        XCTAssertFalse(fake.state.charging, "the charger stays off")
        let manual = await entries().filter { $0.kind == .manual }
        XCTAssertEqual(manual.map(\.reason), [
            "stop charging accepted: plugged in and idle, so climate won't wake the charger",
            "climatise to 21.0 °C accepted (charger held)",
        ])
        XCTAssertEqual(manual.last?.requestsUsed, 4) // read, stop charging, its confirmation, climate
        let cached = await container.vehicles.cached()
        XCTAssertEqual(cached?.climate, .running)
        XCTAssertEqual(cached?.chargingState, .pluggedIn)
    }

    func testLeavesAnActiveChargeAlone() async {
        pluggedInAndIdle()
        fake.state.charging = true
        _ = await engine.manualStart(targetC: 21)
        XCTAssertTrue(fake.state.charging)
        let reasons = await entries().map(\.reason)
        XCTAssertFalse(reasons.contains { $0.hasPrefix("stop charging") })
    }

    func testDoesNothingExtraWhenUnplugged() async {
        _ = await engine.manualStart(targetC: 21)
        let reasons = await entries().filter { $0.kind == .manual }.map(\.reason)
        XCTAssertEqual(reasons, ["climatise to 21.0 °C accepted"])
    }

    func testAFailedStopStillStartsClimate() async {
        pluggedInAndIdle()
        await engine.refreshVehicle()
        // The car reports plugged in, then is unplugged before the command: the stop fails.
        fake.state.pluggedIn = false
        let outcome = await engine.manualStart(targetC: 21)
        XCTAssertEqual(outcome, .sent("climatise to 21.0 °C"))
        let log = await entries()
        XCTAssertTrue(log.contains { $0.decision == "charger not held" && $0.reason.hasPrefix("stop charging failed") })
        XCTAssertTrue(fake.state.climateOn)
    }

    func testExtrasGoWithEveryStart() async {
        await container.stores.settings.save(AppSettings(fakeMode: true, climateDefrost: true, climateHeatedExtras: true))
        let prefs = await container.stores.settings.climatePreferences()
        XCTAssertEqual(prefs.options, ClimateOptions(defrost: true, heatedExtras: true))
        XCTAssertTrue(prefs.holdCharger)
    }

    func testOldSettingsFilesGetTheNewDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"minSocPercent":30}"#.utf8))
        XCTAssertEqual(s.minSocPercent, 30)
        XCTAssertTrue(s.holdChargerOnClimate)
        XCTAssertFalse(s.climateDefrost)
        XCTAssertFalse(s.climateHeatedExtras)
    }

    func testLockUnlockAndLimitsUpdateTheCarAndTheCache() async {
        await engine.refreshVehicle()
        let unlock = await engine.manualCommand(.unlock)
        XCTAssertEqual(unlock, .sent("unlock the car"))
        XCTAssertFalse(fake.state.locked)
        var cachedDetails = await container.vehicles.cached()?.details
        XCTAssertEqual(cachedDetails?.locked, false)

        _ = await engine.manualCommand(.lock)
        XCTAssertTrue(fake.state.locked)

        _ = await engine.manualCommand(.setChargeLimits(ac: 90, dc: 76))
        XCTAssertEqual(fake.state.chargeLimitAC, 90)
        XCTAssertEqual(fake.state.chargeLimitDC, 80)
        cachedDetails = await container.vehicles.cached()?.details
        XCTAssertEqual(cachedDetails?.chargeLimitAC, 90)
        XCTAssertEqual(cachedDetails?.chargeLimitDC, 80)

        await engine.refreshVehicle()
        let fresh = await container.vehicles.cached()?.details
        XCTAssertEqual(fresh?.locked, true)
        XCTAssertEqual(fresh?.chargeLimitAC, 90)
        XCTAssertEqual(fresh?.odometerKm, 18234.5)
        XCTAssertEqual(fresh?.batteryHealthPercent, 97.5)
    }

    func testChargingCommandsNeedThePlug() async {
        await engine.refreshVehicle()
        let refused = await engine.manualCommand(.startCharging)
        XCTAssertEqual(refused, .refused("the car isn't plugged in"))

        fake.state.pluggedIn = true
        await engine.refreshVehicle()
        let started = await engine.manualCommand(.startCharging)
        XCTAssertEqual(started, .sent("start charging"))
        XCTAssertTrue(fake.state.charging)
        let cachedState = await container.vehicles.cached()?.chargingState
        XCTAssertEqual(cachedState, .charging)
        _ = await engine.manualCommand(.stopCharging)
        XCTAssertFalse(fake.state.charging)
    }

    func testDrivingHistoryFromTheFakeCar() async throws {
        let fetched = await engine.drivingHistory().value
        let history = try XCTUnwrap(fetched)
        XCTAssertEqual(history.days.count, 30)
        XCTAssertGreaterThan(history.totalDistanceKm, 500)
        let perKm = try XCTUnwrap(history.kWhPer100km)
        XCTAssertTrue((15...30).contains(perKm), "\(perKm)")
        XCTAssertEqual(history.lifetimeConsumedWh, 3_120_000)
    }

    // MARK: Confirmation from the car

    func testConfirmsAClimateStartWithTheCar() async throws {
        let outcome = await engine.manualStart(targetC: 21)
        XCTAssertEqual(outcome, .sent("climatise to 21.0 °C"))
        let sent = await container.stores.automationState.load().lastCommand
        XCTAssertNotNil(sent?.messageId)
        XCTAssertNil(sent?.status)

        let status = await engine.confirmLastCommand { _ in }
        XCTAssertEqual(status, .success)
        let confirmed = await container.stores.automationState.load().lastCommand
        XCTAssertEqual(confirmed?.status, .success)
        let titles = await notifier.sent
        XCTAssertEqual(titles.last, "Climate on · 21.0 °C")
        let last = await entries().last
        XCTAssertEqual(last?.decision, "confirmed")
        XCTAssertEqual(last?.requestsUsed, 1)
    }

    func testWaitsWhileTheCarHasntReportedThenGivesUp() async throws {
        fake.state.confirmAfter = 3600
        _ = await engine.manualCommand(.lock)
        let slept = Locked<[TimeInterval]>([])
        let status = await engine.confirmLastCommand(delays: [5, 5, 10]) { d in slept.withLock { $0.append(d) } }
        XCTAssertEqual(status, .pending)
        XCTAssertEqual(slept.current, [5, 5, 10])
        let last = await entries().last
        XCTAssertEqual(last?.decision, "unconfirmed")
        XCTAssertEqual(last?.requestsUsed, 3)
    }

    func testACommandKiaNeverListsIsntWaitedOnForLong() async throws {
        _ = await engine.manualCommand(.lock)
        // As with charge limits: Kia accepted it, but it never appears in the command history.
        await container.stores.automationState.update { $0.lastCommand?.messageId = "never-listed" }
        let slept = Locked<[TimeInterval]>([])
        let status = await engine.confirmLastCommand(delays: [1, 1, 1, 1, 1, 1, 1, 1]) { d in slept.withLock { $0.append(d) } }
        XCTAssertEqual(status, .unknown)
        XCTAssertEqual(slept.current.count, 3)
        XCTAssertFalse(CarCommand.setChargeLimits(ac: 80, dc: 80).confirmedByCar)
        XCTAssertFalse(CarCommand.setOffPeak(OffPeakWindow(start: ClockTime(hour: 23), end: ClockTime(hour: 6))).confirmedByCar)
        XCTAssertTrue(CarCommand.lock.confirmedByCar)
        XCTAssertEqual(DisplayText.confirmed(CarCommand.setOffPeak(OffPeakWindow(start: ClockTime(hour: 23), end: ClockTime(hour: 6))).description),
                       "Off-peak charging set to 23:00–06:00")
        XCTAssertEqual(DisplayText.confirmed(CarCommand.sendToCar([NavPoint(name: "Manchester", position: LatLon(lat: 53.5, lon: -2.2))]).description),
                       "Sent Manchester to the car's nav")
    }

    func testARefusalAndNoAnswerAreReported() async throws {
        fake.state.commandOutcome = .fail
        _ = await engine.manualCommand(.unlock)
        let refused = await engine.confirmLastCommand { _ in }
        XCTAssertEqual(refused, .failed)
        var problems = await notifier.problems
        XCTAssertTrue(problems.last?.hasPrefix("The car didn't do it") == true, "\(problems)")

        fake.state.commandOutcome = .noResponse
        _ = await engine.manualCommand(.lock)
        let silent = await engine.confirmLastCommand { _ in }
        XCTAssertEqual(silent, .noResponse)
        problems = await notifier.problems
        XCTAssertTrue(problems.last?.hasPrefix("No answer from the car") == true)
    }

    func testANewerCommandTakesOverAndSuspensionStopsEarly() async throws {
        fake.state.confirmAfter = 3600
        _ = await engine.manualCommand(.lock)
        let engine = self.engine
        let status = await engine.confirmLastCommand(delays: [1, 1]) { _ in
            // Another command goes out while this one is being followed.
            _ = await engine.manualCommand(.unlock)
        }
        XCTAssertEqual(status, .unknown)

        let stopped = await engine.confirmLastCommand(delays: [1, 1]) { _ in throw CancellationError() }
        XCTAssertEqual(stopped, .pending)
    }

    func testConfirmedTitles() {
        XCTAssertEqual(DisplayText.confirmed("stop climatisation"), "Climate off")
        XCTAssertEqual(DisplayText.confirmed("lock the car"), "Locked")
        XCTAssertEqual(DisplayText.confirmed("stop charging"), "Charging stopped")
        XCTAssertEqual(DisplayText.confirmed("set charge limits to 80% AC, 80% DC"), "Charge limits set")
    }
}
