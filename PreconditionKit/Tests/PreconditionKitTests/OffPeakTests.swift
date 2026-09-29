import Foundation
import XCTest
@testable import PreconditionKit

/// The off-peak charging window: Kia's 12-hour times, reading it from the status, and changing it.
final class OffPeakTests: XCTestCase {
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

    static let statusWithSchedule = #"""
    {"retCode":"S","resCode":"0000","resMsg":{"vehicleStatusInfo":{"vehicleStatus":{"evStatus":{"reservChargeInfos":{
      "reservChargeInfo":{"reservChargeInfoDetail":{"reservInfo":{"day":[1,2,3,4,5],"time":{"time":"0730","timeSection":0}},"reservChargeSet":true}},
      "reserveChargeInfo2":{"reservChargeInfoDetail":{"reservInfo":{"day":[6],"time":{"time":"0900","timeSection":0}},"reservChargeSet":false}},
      "reservFlag":1,
      "offpeakPowerInfo":{"offPeakPowerTime1":{"starttime":{"time":"1100","timeSection":1},"endtime":{"time":"0600","timeSection":0}},"offPeakPowerFlag":1}
    }}}}}}
    """#

    override func setUp() {
        super.setUp()
        server.setDefault("/oauth2/token", jsonResponse(KiaClientTests.tokenOK))
        server.setDefault("/notifications/register", okResponse(#"{"deviceId":"dev-1"}"#))
        server.setDefault("/spa/vehicles", okResponse(KiaClientTests.vehiclesLegacy))
        server.setDefault("/user/pin", jsonResponse(#"{"controlToken":"ctl-1","expiresTime":600}"#))
        server.setDefault("/status/latest", jsonResponse(Self.statusWithSchedule))
        server.setDefault("/reservation/chargehvac", jsonResponse(#"{"retCode":"S","resCode":"0000","resMsg":{},"msgId":"m1"}"#))
    }

    func testKiaTimesAreTwelveHourWithASection() {
        XCTAssertEqual(OffPeakWindow.kiaTime(ClockTime(hour: 23)), ["time": "1100", "timeSection": 1])
        XCTAssertEqual(OffPeakWindow.kiaTime(ClockTime(hour: 6, minute: 30)), ["time": "0630", "timeSection": 0])
        XCTAssertEqual(OffPeakWindow.kiaTime(ClockTime(hour: 0)), ["time": "1200", "timeSection": 0])
        XCTAssertEqual(OffPeakWindow.kiaTime(ClockTime(hour: 12)), ["time": "1200", "timeSection": 1])
        for minutes in stride(from: 0, to: 1440, by: 30) {
            let t = ClockTime(hour: 0, minute: minutes)
            XCTAssertEqual(OffPeakWindow.clockTime(OffPeakWindow.kiaTime(t)), t)
        }
        // Some cars send 24-hour times.
        XCTAssertEqual(OffPeakWindow.clockTime(["time": "2300", "timeSection": 1]), ClockTime(hour: 23))
    }

    func testTheWindowIsReadFromTheStatus() throws {
        let status = try XCTUnwrap(JSONValue.parse(Data(Self.statusWithSchedule.utf8)))
        let snapshot = KiaMapper.toSnapshot(status: status, park: nil, ccs2: false, fetchedAt: Date())
        XCTAssertEqual(snapshot.details?.offPeak, OffPeakWindow(start: ClockTime(hour: 23), end: ClockTime(hour: 6)))
    }

    func testChangingTheWindowKeepsTheDepartures() async throws {
        let window = OffPeakWindow(start: ClockTime(hour: 0, minute: 30), end: ClockTime(hour: 5, minute: 30), onlyOffPeak: true)
        await expectSuccess(await client.send(.setOffPeak(window), kind: .manual))
        let request = try XCTUnwrap(server.last("/reservation/chargehvac"))
        XCTAssertTrue(request.url.path.contains("/api/v2/spa/"))
        XCTAssertEqual(request.header("Authorization"), "Bearer ctl-1")
        let sent = try XCTUnwrap(body(request))
        XCTAssertEqual(sent.path("offPeakPowerInfo.offPeakPowerFlag"), 2)
        XCTAssertEqual(sent.path("offPeakPowerInfo.offPeakPowerTime1.starttime"), ["time": "1230", "timeSection": 0])
        XCTAssertEqual(sent.path("offPeakPowerInfo.offPeakPowerTime1.endtime"), ["time": "0530", "timeSection": 0])
        XCTAssertEqual(sent.path("reservChargeInfo1.reservChargeInfoDetail.reservInfo.time.time"), "0730")
        XCTAssertEqual(sent.path("reservChargeInfo1.reservChargeInfoDetail.reservChargeSet"), true)
        XCTAssertEqual(sent.path("reservChargeInfo2.reservChargeInfoDetail.reservInfo.day"), [6])
        XCTAssertEqual(sent["reservFlag"], 1)
    }

    func testWithoutAPinItSaysSo() async {
        creds.set(Credentials(refreshToken: KiaClientTests.refresh))
        let result = await client.send(.setOffPeak(OffPeakWindow(start: ClockTime(hour: 23), end: ClockTime(hour: 6))), kind: .manual)
        guard case .failure(.loginFailed(let reason), _) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(reason.contains("PIN"))
        XCTAssertNil(server.last("/reservation/chargehvac"))
    }

    func testTheFakeCarKeepsTheWindow() async throws {
        let fake = FakeKia(time: time)
        let client = KiaClient(
            transport: fake,
            budget: RateBudget(store: InMemoryRateBudgetStore(), time: time),
            credentials: creds,
            sessions: InMemoryKiaSessionStore(),
            time: time
        )
        let before = await client.getVehicle(.manual).value
        XCTAssertEqual(before?.snapshot.details?.offPeak?.text, "23:00–06:00")
        await expectSuccess(await client.send(.setOffPeak(OffPeakWindow(start: ClockTime(hour: 0), end: ClockTime(hour: 7))), kind: .manual))
        let after = await client.getVehicle(.manual).value
        XCTAssertEqual(after?.snapshot.details?.offPeak?.text, "00:00–07:00")
    }
}
