import Foundation
import XCTest
@testable import PreconditionKit

final class TrafficAheadTests: XCTestCase {
    func testPolylinesDecode() {
        let points = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].lat, 38.5, accuracy: 1e-9)
        XCTAssertEqual(points[0].lon, -120.2, accuracy: 1e-9)
        XCTAssertEqual(points[2].lat, 43.252, accuracy: 1e-9)
        XCTAssertEqual(points[2].lon, -126.453, accuracy: 1e-9)
        XCTAssertEqual(Polyline.decode(""), [])
    }

    /// A straight line north, and one that bulges 5 km east in the middle.
    func line(bulgeKm: Double) -> [LatLon] {
        (0...40).map { i in
            let t = Double(i) / 40
            let east = bulgeKm * sin(t * .pi) / 68 // ~68 km per degree of longitude at 52°
            return LatLon(lat: 52 + t * 0.5, lon: -0.7 + east)
        }
    }

    func testTheViaPointIsWhereTheRoutesAreFurthestApart() throws {
        let direct = line(bulgeKm: 0)
        let detour = line(bulgeKm: 5)
        let via = try XCTUnwrap(TrafficAhead.distinctivePoint(of: detour, avoiding: [direct]))
        XCTAssertEqual(via.lat, 52.25, accuracy: 0.02)
        XCTAssertGreaterThan(via.lon, -0.64)
        // Routes that are the same road have nothing to send.
        XCTAssertNil(TrafficAhead.distinctivePoint(of: direct, avoiding: [line(bulgeKm: 0.3)]))
    }

    func testAlternativesComeBackWithTrafficAndPaths() async throws {
        let server = ScriptedTransport()
        server.setDefault(":computeRoutes", jsonResponse(#"""
        {"routes":[
          {"duration":"4380s","staticDuration":"3300s","distanceMeters":98000,"description":"M1","polyline":{"encodedPolyline":"_p~iF~ps|U_ulLnnqC"}},
          {"duration":"4020s","staticDuration":"3900s","distanceMeters":104000,"description":"A5 and A43","polyline":{"encodedPolyline":"_p~iF~ps|U"}}
        ]}
        """#))
        let options = try await GoogleRoutesClient(transport: server, key: "k").alternatives(from: LatLon(lat: 52, lon: -0.7), to: LatLon(lat: 53, lon: -1))
        XCTAssertEqual(options.map(\.name), ["M1", "A5 and A43"])
        XCTAssertEqual(options[0].time.delayMinutes, 18)
        XCTAssertEqual(options[0].path.count, 2)
        let body = try XCTUnwrap(server.seen.last?.body.flatMap(JSONValue.parse))
        XCTAssertEqual(body["computeAlternativeRoutes"], true)
        XCTAssertEqual(TrafficAhead.summary(options), "Traffic's clear: 1 h 7 min on the quickest way, A5 and A43.")
    }

    func testSendToCarPostsTheStopsInOrderWithThePin() async throws {
        let time = MutableTime()
        let server = ScriptedTransport()
        server.setDefault("/oauth2/token", jsonResponse(KiaClientTests.tokenOK))
        server.setDefault("/notifications/register", okResponse(#"{"deviceId":"dev-1"}"#))
        server.setDefault("/spa/vehicles", okResponse(KiaClientTests.vehiclesLegacy))
        server.setDefault("/user/pin", jsonResponse(#"{"controlToken":"ctl-1","expiresTime":600}"#))
        server.setDefault("/location/routes", jsonResponse(#"{"retCode":"S","resCode":"0000","resMsg":{},"msgId":"m1"}"#))
        let client = KiaClient(
            transport: server,
            budget: RateBudget(store: InMemoryRateBudgetStore(), time: time),
            credentials: TestCredentials(Credentials(refreshToken: KiaClientTests.refresh, pin: "1234")),
            sessions: InMemoryKiaSessionStore(),
            time: time
        )
        let points = [NavPoint(name: "Via", position: LatLon(lat: 52.2, lon: -0.6)), NavPoint(name: "Home", position: LatLon(lat: 52.4, lon: -0.7), address: "1 High St")]
        await expectSuccess(await client.send(.sendToCar(points), kind: .manual))
        let request = try XCTUnwrap(server.last("/location/routes"))
        XCTAssertTrue(request.url.path.contains("/api/v2/spa/"))
        XCTAssertEqual(request.header("Authorization"), "Bearer ctl-1")
        let body = try XCTUnwrap(body(request))
        XCTAssertEqual(body["deviceID"], "dev-1")
        let list = body["poiInfoList"]?.array ?? []
        XCTAssertEqual(list.map { $0["name"] }, ["Via", "Home"])
        XCTAssertEqual(list.map { $0["waypointID"] }, [0, 1])
        XCTAssertEqual(list[1].path("coord.lat"), 52.4)
        XCTAssertEqual(list[1]["addr"], "1 High St")
    }
}
