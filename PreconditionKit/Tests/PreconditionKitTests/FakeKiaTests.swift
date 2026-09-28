import Foundation
import XCTest
@testable import PreconditionKit

/// The real client against the fake car, as in fake-car mode.
final class FakeKiaTests: XCTestCase {
    let time = MutableTime()
    lazy var fake = FakeKia(time: time)
    let sessions = InMemoryKiaSessionStore()
    lazy var client = KiaClient(
        transport: fake,
        budget: RateBudget(store: InMemoryRateBudgetStore(), time: time),
        credentials: TestCredentials(Credentials(refreshToken: "FAKE")),
        sessions: sessions,
        time: time
    )

    private func vehicle(file: StaticString = #filePath, line: UInt = #line) async throws -> VehicleSnapshot {
        let fetched = await expectSuccess(await client.getVehicle(.manual), file: file, line: line)
        return try XCTUnwrap(fetched, file: file, line: line).snapshot
    }

    func testReadsTheFakeCar() async throws {
        fake.state.socPercent = 40
        fake.state.pluggedIn = true
        fake.state.charging = true
        let v = try await vehicle()
        XCTAssertEqual(v.socPercent, 40)
        XCTAssertEqual(v.rangeKm, 200)
        XCTAssertEqual(v.chargingState, .charging)
        XCTAssertEqual(v.minutesToFullyCharged, 300)
        XCTAssertEqual(v.climate, .off)
        XCTAssertEqual(v.parkingPosition, LatLon(lat: 50.4113, lon: 14.9053))
        XCTAssertEqual(v.carCapturedAt, t0.addingTimeInterval(-120))
        let session = await sessions.session
        XCTAssertEqual(session?.vehicleId, FakeKia.vehicleId)
        XCTAssertEqual(session?.refreshToken, "FAKEREFRESH")
    }

    func testClimateCommandsChangeTheFakeCar() async throws {
        await expectSuccess(await client.startClimate(targetC: 19.5, kind: .manual))
        XCTAssertTrue(fake.state.climateOn)
        XCTAssertEqual(fake.state.targetTempC, 19.5)
        let v = try await vehicle()
        XCTAssertEqual(v.climate, .running)
        XCTAssertEqual(v.targetTempC, 19.5)

        await expectSuccess(await client.stopClimate(.manual))
        XCTAssertFalse(fake.state.climateOn)
    }

    func testScenariosMapToTheRightErrors() async throws {
        let expected: [(FakeScenario, (ApiError) -> Bool)] = [
            (.refreshTokenRejected, { $0.isAuthFailure }),
            (.accessTokenRejected, { $0.isAuthFailure }),
            (.vehicleBusy, { $0 == .vehicleNotAcceptingRequests(retryAfter: 120) }),
            (.serverError, { if case .server(503, _) = $0 { return true } else { return false } }),
            // Last: it blocks the budget for an hour.
            (.rateLimited, { $0 == .rateLimited(retryAfter: 3600) }),
        ]
        for (scenario, matches) in expected {
            await sessions.save(nil)
            fake.state.scenario = scenario
            let error = await client.getVehicle(.manual).error
            XCTAssertTrue(error.map(matches) ?? false, "\(scenario): \(String(describing: error))")
        }
    }

    func testNotSupportedOnlyAffectsCommands() async throws {
        fake.state.scenario = .notSupported
        await expectSuccess(await client.getVehicle(.manual))
        await expectError(await client.startClimate(targetC: 21, kind: .manual), .operationNotSupported(code: "4005"))
    }

    func testPartialHasNoPosition() async throws {
        fake.state.scenario = .partial
        let v = try await vehicle()
        XCTAssertNil(v.parkingPosition)
        XCTAssertEqual(v.socPercent, 62)
    }

    func testTheDailyLimitRunsOutAndResets() async throws {
        fake.state.dailyLimit = 4 // register, vehicles, status, park
        await expectSuccess(await client.getVehicle(.manual))
        await expectError(await client.getVehicle(.manual), .rateLimited(retryAfter: 3600))
    }

    func testRoutingSendsKiaTrafficToTheFakeOnlyInFakeMode() async throws {
        let live = ScriptedTransport()
        let router = RoutingTransport.kia(live: live, fake: fake)
        let request = HTTPRequest(method: "GET", url: URL(string: "https://prd.eu-ccapi.kia.com:8080/api/v1/spa/vehicles")!)

        _ = try await router.send(request)
        XCTAssertEqual(live.seen.count, 1)

        router.fakeMode = true
        let response = try await router.send(request)
        XCTAssertEqual(live.seen.count, 1)
        XCTAssertEqual(JSONValue.parse(response.body)?.path("resMsg.vehicles.0.vin")?.str, FakeKia.vin)

        _ = try await router.send(HTTPRequest(method: "GET", url: URL(string: "https://api.open-meteo.com/v1/forecast")!))
        XCTAssertEqual(live.seen.count, 2)
    }
}
