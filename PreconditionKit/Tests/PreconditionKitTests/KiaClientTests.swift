import Foundation
import XCTest
@testable import PreconditionKit

/// Port of the Android `KiaClientTest`.
final class KiaClientTests: XCTestCase {
    static let refresh = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCDEFGHIJKL"
    static let tokenOK = #"{"token_type":"Bearer","access_token":"acc-1","expires_in":3600}"#

    static let vehiclesLegacy = """
    {"vehicles":[
      {"vehicleId":"veh-ice","nickname":"Ceed","vehicleName":"CEED","vin":"U5YH000000000001","type":"GN","ccuCCS2ProtocolSupport":0},
      {"vehicleId":"veh-ev","nickname":"EV6","vehicleName":"EV6","vin":"KNAC381ABN5000001","type":"EV","ccuCCS2ProtocolSupport":0}
    ]}
    """
    static let vehiclesCcs2 = vehiclesLegacy.replacingOccurrences(of: #""ccuCCS2ProtocolSupport":0}"#, with: #""ccuCCS2ProtocolSupport":1}"#)

    static let vehiclesTwo = """
    {"vehicles":[
      {"vehicleId":"veh-one","vin":"KNAC381ABN5000001","type":"EV","ccuCCS2ProtocolSupport":0},
      {"vehicleId":"veh-two","vin":"KNAC381ABN5000002","type":"EV","ccuCCS2ProtocolSupport":0}
    ]}
    """

    static let legacyStatus = """
    {"vehicleStatusInfo":{
      "vehicleStatus":{
        "time":"20260923175800","airCtrlOn":false,"engine":false,
        "airTemp":{"value":"0EH","unit":0},
        "evStatus":{
          "batteryStatus":74,"batteryCharge":true,"batteryPlugin":2,
          "batteryPower":{"batteryStndChrgPower":10.9,"batteryFstChrgPower":0},
          "remainTime2":{"atc":{"value":95,"unit":1}},
          "drvDistance":[{"rangeByFuel":{"evModeRange":{"value":312,"unit":1},"totalAvailableRange":{"value":312,"unit":1}}}]
        }
      },
      "vehicleLocation":{"coord":{"lat":50.0,"lon":14.0},"time":"20260922120000"},
      "odometer":{"value":18234.5,"unit":1}
    }}
    """

    static let park = #"{"coord":{"lat":50.1,"lon":14.4,"type":0},"time":"20260923170000"}"#

    static let ccs2Status = """
    {"state":{"Vehicle":{
      "Date":"20260923143005.123",
      "DrivingReady":0,
      "Green":{
        "BatteryManagement":{"BatteryRemain":{"Ratio":58}},
        "ChargingInformation":{"ConnectorFastening":{"State":0},"Charging":{"RemainTime":0}}
      },
      "Drivetrain":{"FuelSystem":{"DTE":{"Total":250,"Unit":2}}},
      "Cabin":{"HVAC":{
        "Row1":{"Driver":{"Temperature":{"Value":"22","Unit":0},"Blower":{"SpeedLevel":3}}},
        "OutsideTemperature":{"Value":"4.5","Unit":0}
      }},
      "Location":{"GeoCoord":{"Latitude":50.2,"Longitude":14.2}}
    }}}
    """

    let time = MutableTime()
    let server = ScriptedTransport()
    let budgetStore = InMemoryRateBudgetStore()
    let sink = RecordingMetaSink()
    let sessions = InMemoryKiaSessionStore()
    let creds = TestCredentials(Credentials(refreshToken: KiaClientTests.refresh))
    lazy var budget = RateBudget(store: budgetStore, time: time, config: BudgetConfig(limit: 80, manualReserve: 8, window: 24 * 3600))
    lazy var client = KiaClient(
        transport: server,
        budget: budget,
        credentials: creds,
        sessions: sessions,
        metaSink: sink,
        time: time,
        config: KiaConfig(apiBase: "https://api.test:8080", idpBase: "https://idp.test"),
        rng: SeededRNG(1)
    )

    override func setUp() {
        super.setUp()
        server.setDefault("/oauth2/token", jsonResponse(Self.tokenOK))
        server.setDefault("/notifications/register", okResponse(#"{"deviceId":"dev-1"}"#))
        server.setDefault("/spa/vehicles", okResponse(Self.vehiclesLegacy))
        server.setDefault("/status/latest", okResponse(Self.legacyStatus))
        server.setDefault("/ccs2/carstatus/latest", okResponse(Self.ccs2Status))
        server.setDefault("/location/park", okResponse(Self.park))
        server.setDefault("/control/temperature", jsonResponse(#"{"retCode":"S","resCode":"0000","resMsg":{},"msgId":"m1"}"#))
        server.setDefault("/user/pin", jsonResponse(#"{"controlToken":"ctl-1","expiresTime":600}"#))
    }

    private func fetch(file: StaticString = #filePath, line: UInt = #line) async throws -> VehicleFetch {
        let result = await client.getVehicle(.manual)
        let value = result.value
        return try XCTUnwrap(value, "\(String(describing: result.error))", file: file, line: line)
    }


    // MARK: - Login and session

    func testFirstReadLogsInRegistersPicksTheEVAndReadsCachedStatusAndParkedPosition() async throws {
        let v = try await fetch().snapshot
        XCTAssertEqual(server.paths, [
            "v2/user/oauth2/token",
            "v1/spa/notifications/register",
            "v1/spa/vehicles",
            "v1/spa/vehicles/veh-ev/status/latest",
            "v1/spa/vehicles/veh-ev/location/park",
        ])
        let token = server.seen.first!.bodyText
        XCTAssertTrue(token.contains("grant_type=refresh_token"))
        XCTAssertTrue(token.contains("refresh_token=\(Self.refresh)"))
        XCTAssertTrue(token.contains("client_secret=secret"))

        let register = try XCTUnwrap(body(server.last("/notifications/register")))
        XCTAssertEqual(register["pushType"], "APNS")
        XCTAssertEqual(register["pushRegId"]?.str?.count, 64)
        XCTAssertNil(server.last("/notifications/register")?.header("Authorization"))

        let status = try XCTUnwrap(server.last("/status/latest"))
        XCTAssertEqual(status.header("Authorization"), "Bearer acc-1")
        XCTAssertEqual(status.header("ccsp-device-id"), "dev-1")
        XCTAssertEqual(status.header("Ccuccs2protocolsupport"), "0")
        XCTAssertEqual(status.header("User-Agent"), "okhttp/3.12.0")
        XCTAssertNotNil(status.header("Stamp"))

        XCTAssertEqual(v.socPercent, 74)
        XCTAssertEqual(v.rangeKm, 312)
        XCTAssertEqual(v.pluggedIn, true)
        XCTAssertEqual(v.chargingState, .charging)
        XCTAssertEqual(v.chargePowerKw, 10.9)
        XCTAssertEqual(v.minutesToFullyCharged, 95)
        XCTAssertEqual(v.climate, .off)
        XCTAssertEqual(v.targetTempC, 21.0)
        XCTAssertEqual(v.parked, true)
        // location/park wins over the older position inside the status
        XCTAssertEqual(v.parkingPosition, LatLon(lat: 50.1, lon: 14.4))
        // 17:58:00 in Berlin (CEST) = 15:58 UTC
        XCTAssertEqual(v.carCapturedAt, date("2026-09-23T15:58:00Z"))
        XCTAssertEqual(v.fetchedAt, time.now())
        let seen = await sink.seen
        XCTAssertEqual(seen.count, 1)
        XCTAssertNil(seen.first?.1)
    }

    func testRawJSONHoldsStatusAndPark() async throws {
        let text = try await fetch().rawJSON
        let raw = try XCTUnwrap(JSONValue.parse(text))
        XCTAssertEqual(raw.path("status.resMsg.vehicleStatusInfo.vehicleStatus.evStatus.batteryStatus"), 74)
        XCTAssertEqual(raw.path("park.resMsg.coord.lat"), 50.1)
    }

    func testLaterReadsReuseTheSessionAndCostOneBudgetSlotEach() async throws {
        _ = try await fetch()
        server.clearSeen()
        _ = try await fetch()
        XCTAssertEqual(server.paths, ["v1/spa/vehicles/veh-ev/status/latest", "v1/spa/vehicles/veh-ev/location/park"])
        let sent = await budgetStore.state.sent
        XCTAssertEqual(sent.count, 2)
    }

    func testARotatedRefreshTokenIsKeptAndTheAccessTokenIsRenewedBeforeItExpires() async throws {
        server.respond("/oauth2/token", jsonResponse(#"{"token_type":"Bearer","access_token":"acc-1","expires_in":3600,"refresh_token":"NEWREFRESH"}"#))
        _ = try await fetch()
        let session = await sessions.session
        XCTAssertEqual(session?.refreshToken, "NEWREFRESH")
        XCTAssertEqual(session?.enteredTokenHash, KiaSession.fingerprint(Self.refresh))

        time.advance(3600 - 60)
        server.clearSeen()
        _ = try await fetch()
        XCTAssertTrue(server.seen.first!.bodyText.contains("refresh_token=NEWREFRESH"))
    }

    func testEnteringADifferentTokenStartsANewSession() async throws {
        _ = try await fetch()
        creds.set(Credentials(refreshToken: String(repeating: "B", count: 48)))
        server.clearSeen()
        _ = try await fetch()
        XCTAssertEqual(server.paths.first, "v2/user/oauth2/token")
        XCTAssertTrue(server.seen.first!.bodyText.contains("refresh_token=" + String(repeating: "B", count: 48)))
    }

    func testARejectedRefreshTokenStopsAutomationAndDoesNotCountAgainstTheBudget() async throws {
        server.respond("/oauth2/token", jsonResponse(#"{"error":"invalid_grant"}"#, status: 400))
        let error = try await failure(await client.getVehicle(.automation))
        XCTAssertEqual(error, .loginFailed(reason: "Kia rejected the refresh token"))
        XCTAssertTrue(error.isAuthFailure)
        let seen = await sink.seen
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.1?.isAuthFailure, true)
        let sent = await budgetStore.state.sent
        XCTAssertTrue(sent.isEmpty)
    }

    func testALoginServerErrorIsAServerError() async throws {
        server.respond("/oauth2/token", jsonResponse("down", status: 503))
        let error = try await failure(await client.getVehicle(.manual))
        XCTAssertEqual(error, .server(httpCode: 503, code: "login"))
        XCTAssertFalse(error.isAuthFailure)
    }

    func testAnExpiredAccessTokenIsRefreshedOnceAndTheCallRetried() async throws {
        _ = try await fetch()
        server.respond("/status/latest", jsonResponse(#"{"error":"Key not authorized: Token is expired"}"#, status: 401))
        server.respond("/oauth2/token", jsonResponse(Self.tokenOK.replacingOccurrences(of: "acc-1", with: "acc-2")))
        server.clearSeen()
        _ = try await fetch()
        XCTAssertEqual(server.paths[1], "v2/user/oauth2/token")
        XCTAssertEqual(server.last("/status/latest")?.header("Authorization"), "Bearer acc-2")
    }

    func testALoginThatKeepsFailingAfterARefreshIsAnAuthFailure() async throws {
        let expired = jsonResponse(#"{"retCode":"F","resCode":"7501","resMsg":"expired"}"#)
        server.respond("/status/latest", expired, expired)
        let error = try await failure(await client.getVehicle(.manual))
        XCTAssertEqual(error, .loginFailed(reason: "Kia Connect login no longer accepted"))
    }

    func testADroppedDeviceIdIsReRegisteredOnce() async throws {
        _ = try await fetch()
        server.respond("/status/latest", jsonResponse(#"{"retCode":"F","resCode":"4002","resMsg":"Invalid request body - invalid deviceId"}"#, status: 400))
        server.respond("/notifications/register", okResponse(#"{"deviceId":"dev-2"}"#))
        server.clearSeen()
        _ = try await fetch()
        XCTAssertEqual(server.last("/status/latest")?.header("ccsp-device-id"), "dev-2")
    }

    func testAVinPicksThatCarAndAnUnknownVinIsReported() async throws {
        server.respond("/spa/vehicles", okResponse(Self.vehiclesTwo))
        creds.set(Credentials(refreshToken: Self.refresh, vin: "knac381abn5000002"))
        _ = try await fetch()
        XCTAssertTrue(server.last("/status/latest")!.url.path.contains("veh-two"))
        let session = await sessions.session
        XCTAssertEqual(session?.vehicleVin, "KNAC381ABN5000002")

        creds.set(Credentials(refreshToken: Self.refresh, vin: "KNAC381ABN5999999"))
        server.respond("/spa/vehicles", okResponse(Self.vehiclesTwo))
        await expectError(await client.getVehicle(.manual), .vehicleNotFound(code: nil))
    }

    func testMissingCredentialsMakeNoRequest() async throws {
        creds.set(nil)
        await expectError(await client.getVehicle(.manual), .notConfigured)
        XCTAssertTrue(server.seen.isEmpty)
    }

    func testAnEmptyBudgetMakesNoRequest() async throws {
        await budgetStore.save(RateBudgetState(exhaustedUntil: t0.addingTimeInterval(60)))
        await expectError(await client.getVehicle(.manual), .budgetExhausted(.manual))
        XCTAssertTrue(server.seen.isEmpty)
    }

    func testResetForgetsTheSession() async throws {
        _ = try await fetch()
        await client.reset()
        let session = await sessions.session
        XCTAssertNil(session)
    }

    // MARK: - Errors

    func testKiasRequestLimitBlocksTheBudgetForAnHour() async throws {
        server.respond("/status/latest", jsonResponse(#"{"retCode":"F","resCode":"5091","resMsg":"Exceeds number of requests"}"#))
        let error = try await failure(await client.getVehicle(.automation))
        XCTAssertEqual(error, .rateLimited(retryAfter: 3600))
        let until = await budgetStore.state.exhaustedUntil
        XCTAssertEqual(until, time.now().addingTimeInterval(3600))
    }

    func testABusyCarIsReportedAsNotAcceptingRequests() async throws {
        server.respond("/control/temperature", jsonResponse(#"{"retCode":"F","resCode":"5031","resMsg":"Unavailable remote control"}"#, status: 400))
        await expectError(await client.startClimate(targetC: 21, kind: .manual), .vehicleNotAcceptingRequests(retryAfter: 120))
    }

    func testOtherBusyCodes() async throws {
        for code in ["4081", "9999", "4004"] {
            server.respond("/control/temperature", jsonResponse(#"{"retCode":"F","resCode":"\#(code)","resMsg":"x"}"#))
            await expectError(await client.startClimate(targetC: 21, kind: .manual), .vehicleNotAcceptingRequests(retryAfter: 120), code)
        }
    }

    func testUnsupportedControlAndServerErrorsAreMapped() async throws {
        server.respond("/control/temperature", jsonResponse(#"{"retCode":"F","resCode":"4005","resMsg":"Unsupported"}"#))
        await expectError(await client.startClimate(targetC: 21, kind: .manual), .operationNotSupported(code: "4005"))
        server.respond("/status/latest", jsonResponse("bad gateway", status: 502))
        await expectError(await client.getVehicle(.manual), .server(httpCode: 502, code: nil))
    }

    func testANonJSONSuccessIsABadResponse() async throws {
        server.respond("/status/latest", jsonResponse("<html>", status: 200))
        await expectError(await client.getVehicle(.manual), .badResponse(httpCode: 200, cause: "not JSON"))
    }

    func testNoConnectionIsANetworkErrorThatStillCounts() async throws {
        _ = try await fetch()
        server.offline = true
        guard case .network = try await failure(await client.getVehicle(.automation)) else { return XCTFail("expected a network error") }
        let sent = await budgetStore.state.sent
        XCTAssertEqual(sent.count, 2)
    }

    func testAFailedParkedPositionReadStillReturnsTheStatus() async throws {
        server.respond("/location/park", jsonResponse(#"{"retCode":"F","resCode":"5921","resMsg":"No Data Found v2"}"#))
        let fetch = try await fetch()
        XCTAssertEqual(fetch.snapshot.parkingPosition, LatLon(lat: 50.0, lon: 14.0))
        XCTAssertNil(JSONValue.parse(fetch.rawJSON)?["park"])
    }

    // MARK: - Climate

    func testStartAndStopClimateOnAnOlderCar() async throws {
        await expectSuccess(await client.startClimate(targetC: 21.2, kind: .manual))
        let start = try XCTUnwrap(body(server.last("/control/temperature")))
        XCTAssertEqual(start["action"], "start")
        XCTAssertEqual(start["tempCode"], "0EH")
        XCTAssertEqual(start.path("options.igniOnDuration"), 15)
        XCTAssertEqual(server.last("/control/temperature")?.header("Authorization"), "Bearer acc-1")
        XCTAssertEqual(server.last("/control/temperature")?.method, "POST")

        await expectSuccess(await client.stopClimate(.manual))
        XCTAssertEqual(body(server.last("/control/temperature"))?["action"], "stop")
    }

    func testTargetsAreRoundedToHalfDegreesAndClamped() async throws {
        _ = await client.startClimate(targetC: 21.3, kind: .manual)
        XCTAssertEqual(body(server.last("/control/temperature"))?["tempCode"], "0FH") // 21.5
        _ = await client.startClimate(targetC: 35, kind: .manual)
        XCTAssertEqual(body(server.last("/control/temperature"))?["tempCode"], "1FH") // 29.5
        _ = await client.startClimate(targetC: 5, kind: .manual)
        XCTAssertEqual(body(server.last("/control/temperature"))?["tempCode"], "00H") // 14.0
    }

    func testCCS2CarsMapTheNewStatusFormat() async throws {
        server.respond("/spa/vehicles", okResponse(Self.vehiclesCcs2))
        let v = try await fetch().snapshot
        XCTAssertTrue(server.paths.contains("v1/spa/vehicles/veh-ev/ccs2/carstatus/latest"))
        XCTAssertEqual(server.last("/ccs2/carstatus/latest")?.header("Ccuccs2protocolsupport"), "1")
        XCTAssertEqual(server.last("/location/park")?.header("Ccuccs2protocolsupport"), "0")
        XCTAssertEqual(v.socPercent, 58)
        XCTAssertEqual(v.pluggedIn, false)
        XCTAssertEqual(v.chargingState, .unplugged)
        XCTAssertEqual(v.climate, .running)
        XCTAssertEqual(v.targetTempC, 22.0)
        XCTAssertEqual(v.outsideTempC, 4.5)
        XCTAssertEqual(v.rangeKm, 402)
        XCTAssertEqual(v.parked, true)
        XCTAssertEqual(v.carCapturedAt, date("2026-09-23T14:30:05Z"))
    }

    func testCCS2ClimateNeedsThePinAndUsesAControlToken() async throws {
        server.respond("/spa/vehicles", okResponse(Self.vehiclesCcs2))
        let noPin = try await failure(await client.startClimate(targetC: 21, kind: .manual))
        XCTAssertTrue(noPin.isAuthFailure)
        XCTAssertTrue(noPin.message.contains("PIN"))
        XCTAssertFalse(server.seen.contains { $0.url.path.hasSuffix("/control/temperature") })

        creds.set(Credentials(refreshToken: Self.refresh, pin: "1234"))
        await expectSuccess(await client.startClimate(targetC: 21, kind: .manual))
        let pinRequest = try XCTUnwrap(server.last("/user/pin"))
        XCTAssertEqual(pinRequest.method, "PUT")
        XCTAssertEqual(pinRequest.header("Authorization"), "Bearer acc-1")
        XCTAssertEqual(body(pinRequest)?["pin"], "1234")
        XCTAssertEqual(body(pinRequest)?["deviceId"], "dev-1")

        let command = try XCTUnwrap(server.last("/ccs2/control/temperature"))
        XCTAssertTrue(command.url.path.contains("/api/v2/spa/"))
        XCTAssertEqual(command.header("Authorization"), "Bearer ctl-1")
        XCTAssertEqual(command.header("AuthorizationCCSP"), "Bearer ctl-1")
        let start = try XCTUnwrap(body(command))
        XCTAssertEqual(start["command"], "start")
        XCTAssertEqual(start["hvacTemp"], 21.0)

        // The control token is reused while it's valid.
        server.clearSeen()
        await expectSuccess(await client.stopClimate(.manual))
        XCTAssertFalse(server.seen.contains { $0.url.path.hasSuffix("/user/pin") })
        XCTAssertEqual(body(server.last("/ccs2/control/temperature")), ["command": "stop"])

        // ...and fetched again once it's within 30 s of expiring.
        time.advance(600 - 29)
        server.clearSeen()
        await expectSuccess(await client.stopClimate(.manual))
        XCTAssertTrue(server.seen.contains { $0.url.path.hasSuffix("/user/pin") })
    }

    func testAWrongPinIsAnAuthFailure() async throws {
        server.respond("/spa/vehicles", okResponse(Self.vehiclesCcs2))
        server.respond("/user/pin", jsonResponse(#"{"errCode":"4001","errMsg":"invalid pin"}"#, status: 400))
        creds.set(Credentials(refreshToken: Self.refresh, pin: "9999"))
        let error = try await failure(await client.startClimate(targetC: 21, kind: .manual))
        XCTAssertEqual(error, .loginFailed(reason: "Kia Connect PIN rejected"))
    }

    func testAPinCallWithAnExpiredAccessTokenRefreshesTheLogin() async throws {
        server.respond("/spa/vehicles", okResponse(Self.vehiclesCcs2))
        server.respond("/user/pin", jsonResponse(#"{"error":"Token is expired"}"#, status: 401))
        server.respond("/oauth2/token", jsonResponse(Self.tokenOK), jsonResponse(Self.tokenOK.replacingOccurrences(of: "acc-1", with: "acc-2")))
        creds.set(Credentials(refreshToken: Self.refresh, pin: "1234"))
        await expectSuccess(await client.startClimate(targetC: 21, kind: .manual))
        XCTAssertEqual(server.last("/user/pin")?.header("Authorization"), "Bearer acc-2")
    }

    // MARK: - Payloads match the handover fixtures

    func testClimatePayloadsMatchTheFixtures() async throws {
        let payloads = try Fixtures.json("kia-climate-payloads.json")
        // The handover fixtures ran climate for 10 minutes; the app now asks for 15, like Kia's app.
        func tenMinutes(_ v: JSONValue?) -> JSONValue? {
            guard var text = v.map({ String(decoding: $0.data, as: UTF8.self) }) else { return nil }
            text = text.replacingOccurrences(of: "\"igniOnDuration\":10", with: "\"igniOnDuration\":15")
                .replacingOccurrences(of: "\"ignitionDuration\":10", with: "\"ignitionDuration\":15")
            return JSONValue.parse(text)
        }

        _ = await client.startClimate(targetC: 21, kind: .manual)
        XCTAssertEqual(body(server.last("/control/temperature")), tenMinutes(payloads.path("legacy_start.body")))
        _ = await client.stopClimate(.manual)
        XCTAssertEqual(body(server.last("/control/temperature")), payloads.path("legacy_stop.body"))

        await sessions.save(nil)
        server.respond("/spa/vehicles", okResponse(Self.vehiclesCcs2))
        creds.set(Credentials(refreshToken: Self.refresh, pin: "1234"))
        _ = await client.startClimate(targetC: 21, kind: .manual)
        XCTAssertEqual(body(server.last("/ccs2/control/temperature")), tenMinutes(payloads.path("ccs2_start.body")))
        _ = await client.stopClimate(.manual)
        XCTAssertEqual(body(server.last("/ccs2/control/temperature")), payloads.path("ccs2_stop.body"))
    }

    // MARK: - Encoding

    func testStampIsTheAppIdAndTimeXORedWithTheFixedKey() {
        let config = KiaConfig()
        let stamp = Array(Data(base64Encoded: config.stamp(epochSeconds: 1_700_000_000))!)
        let key = Array(Data(base64Encoded: "wLTVxwidmH8CfJYBWSnHD6E0huk0ozdiuygB4hLkM5XCgzAL1Dk5sE36d/bx5PFMbZs=")!)
        let plain = String(decoding: zip(stamp, key).map { $0 ^ $1 }, as: UTF8.self)
        XCTAssertEqual(plain, "\(config.appId):1700000000")
        XCTAssertEqual(stamp.count, 47)
    }

    func testTokenFingerprintIsSHA256Hex() {
        XCTAssertEqual(KiaSession.fingerprint("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
