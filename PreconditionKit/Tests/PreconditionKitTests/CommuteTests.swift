import Foundation
import XCTest
@testable import PreconditionKit

final class CommuteTests: XCTestCase {
    // MARK: Links

    func testNamedStopsWithDraggedViaPoints() throws {
        let link = "https://www.google.com/maps/dir/Milton+Keynes/Kettering/@52.2,-0.7,10z/data=!3m1!4b1!4m23!4m22!1m14!1m1!1s0xabc:0xdef!2m2!1d-0.7594!2d52.0406!3m4!1m2!1d-0.9!2d52.2!3s0x1:0x2!3m4!1m2!1d-0.8!2d52.3!3s0x5:0x6!1m5!1m1!1s0x3:0x4!2m2!1d-0.72!2d52.39!3e0?entry=ttu"
        let points = try GoogleMapsLink.points(from: link)
        XCTAssertEqual(points, [
            LatLon(lat: 52.0406, lon: -0.7594),
            LatLon(lat: 52.2, lon: -0.9),
            LatLon(lat: 52.3, lon: -0.8),
            LatLon(lat: 52.39, lon: -0.72),
        ])
    }

    func testCoordinateStopsTakeTheirPositionFromThePath() throws {
        let link = "https://www.google.com/maps/dir/52.0406,-0.7594/52.39,-0.72/@52.2,-0.7,10z/data=!4m9!4m8!1m5!3m4!1m2!1d-0.9!2d52.2!3s0x1!1m0!3e0"
        XCTAssertEqual(try GoogleMapsLink.points(from: link), [
            LatLon(lat: 52.0406, lon: -0.7594), LatLon(lat: 52.2, lon: -0.9), LatLon(lat: 52.39, lon: -0.72),
        ])
        // No data block at all.
        XCTAssertEqual(try GoogleMapsLink.points(from: "https://www.google.com/maps/dir/52.1,-0.7/52.4,-0.7/"), [
            LatLon(lat: 52.1, lon: -0.7), LatLon(lat: 52.4, lon: -0.7),
        ])
    }

    func testDocumentedLinksAndTheConsentWrapper() throws {
        let api = "https://www.google.com/maps/dir/?api=1&origin=52.1,-0.7&destination=52.4,-0.7&waypoints=52.2,-0.8%7C52.3,-0.75&travelmode=driving"
        XCTAssertEqual(try GoogleMapsLink.points(from: api).count, 4)
        let inner = "https://www.google.com/maps/dir/52.1,-0.7/52.4,-0.7/"
        var c = URLComponents(string: "https://consent.google.com/m")!
        c.queryItems = [URLQueryItem(name: "continue", value: inner)]
        XCTAssertEqual(try GoogleMapsLink.points(from: c.url!.absoluteString).count, 2)
    }

    func testLinksItCantRead() {
        XCTAssertThrowsError(try GoogleMapsLink.points(from: "https://www.google.com/maps/place/Kettering")) {
            XCTAssertEqual($0 as? GoogleMapsLink.Failure, .notDirections)
        }
        XCTAssertThrowsError(try GoogleMapsLink.points(from: "https://www.google.com/maps/dir/Work/Home/")) {
            XCTAssertEqual($0 as? GoogleMapsLink.Failure, .missingPlace("Work"))
        }
        XCTAssertTrue(GoogleMapsLink.isShort("https://maps.app.goo.gl/AbC123"))
        XCTAssertFalse(GoogleMapsLink.isShort("https://www.google.com/maps/dir/a/b"))
    }

    // MARK: Google Routes

    func testRoutesRequestSendsViaPointsAndReadsTraffic() async throws {
        let server = ScriptedTransport()
        server.setDefault(":computeRoutes", jsonResponse(#"{"routes":[{"duration":"2940s","staticDuration":"2520s","distanceMeters":61234}]}"#))
        let points = [LatLon(lat: 52.0, lon: -0.7), LatLon(lat: 52.2, lon: -0.9), LatLon(lat: 52.4, lon: -0.7)]
        let time = try await GoogleRoutesClient(transport: server, key: "k").time(points)
        XCTAssertEqual(time.minutes, 49)
        XCTAssertEqual(time.delayMinutes, 7)
        let request = try XCTUnwrap(server.seen.last)
        XCTAssertEqual(request.header("X-Goog-Api-Key"), "k")
        let body = try XCTUnwrap(request.body.flatMap(JSONValue.parse))
        XCTAssertEqual(body["intermediates"]?.array?.count, 1)
        XCTAssertEqual(body.path("intermediates.0.via"), true)
        XCTAssertEqual(body.path("destination.location.latLng.latitude"), 52.4)
        XCTAssertEqual(body["routingPreference"], "TRAFFIC_AWARE")
    }

    func testABadKeySaysWhatToTurnOn() async {
        let server = ScriptedTransport()
        server.setDefault(":computeRoutes", HTTPResponse(status: 403, body: Data("{}".utf8)))
        do {
            _ = try await GoogleRoutesClient(transport: server, key: "k").time([LatLon(lat: 52, lon: 0), LatLon(lat: 53, lon: 0)])
            XCTFail("should throw")
        } catch {
            XCTAssertTrue("\(error)".contains("Routes API"))
        }
    }

    // MARK: Choosing

    let now = Date(timeIntervalSince1970: 1_790_000_000) // a Tuesday afternoon
    func route(_ name: String) -> CommuteRoute { CommuteRoute(name: name, link: "", points: []) }

    func testThePreferredRouteWinsWhenItIsNearlyAsQuick() {
        let checks = [
            RouteCheck(route: route("M1 and A14"), time: DriveTime(seconds: 48 * 60, typicalSeconds: 46 * 60)),
            RouteCheck(route: route("Northampton"), time: DriveTime(seconds: 41 * 60, typicalSeconds: 44 * 60)),
        ]
        let advice = CommuteAdvisor.advise(checks, toleranceMinutes: 10, now: now)
        XCTAssertEqual(advice.pick?.route.name, "M1 and A14")
        XCTAssertEqual(advice.headline, "M1 and A14 is clear: 48 min.")
        let arrival = try? XCTUnwrap(advice.arrival)
        XCTAssertEqual(arrival.map { $0.timeIntervalSince(now) >= 48 * 60 }, true)
        XCTAssertEqual(arrival.map { $0.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) }, 0)
    }

    func testASlowPreferredRouteIsSkipped() {
        let checks = [
            RouteCheck(route: route("M1 and A14"), time: DriveTime(seconds: 70 * 60, typicalSeconds: 46 * 60)),
            RouteCheck(route: route("Northampton"), time: DriveTime(seconds: 44 * 60)),
            RouteCheck(route: route("A5"), time: DriveTime(seconds: 42 * 60)),
        ]
        let advice = CommuteAdvisor.advise(checks, toleranceMinutes: 10, now: now)
        XCTAssertEqual(advice.pick?.route.name, "Northampton")
        XCTAssertEqual(advice.headline, "M1 and A14 is slow (70 min). Northampton is 26 min quicker: 44 min.")
    }

    func testTrafficOnTheBestRouteIsMentioned() {
        let checks = [RouteCheck(route: route("M1 and A14"), time: DriveTime(seconds: 58 * 60, typicalSeconds: 46 * 60))]
        let advice = CommuteAdvisor.advise(checks, toleranceMinutes: 10, now: now)
        XCTAssertEqual(advice.headline, "M1 and A14 is still the best way: 58 min, with 12 min of traffic.")
    }

    func testNothingCheckedSaysWhy() {
        let checks = [RouteCheck(route: route("M1"), problem: "Google answered 500.")]
        let advice = CommuteAdvisor.advise(checks, toleranceMinutes: 10, now: now)
        XCTAssertNil(advice.pick)
        XCTAssertEqual(advice.headline, "Google answered 500.")
    }

    func testTheMessageFillsInTheBlanks() {
        let commute = Commute(name: "Home", message: "I'll be home at {eta}, love you, see you soon ({minutes} min via {route})")
        XCTAssertEqual(commute.messageText(eta: "18:38", minutes: 42, route: "M1"), "I'll be home at 18:38, love you, see you soon (42 min via M1)")
    }

    func testCheckingTimesEveryRouteInOrder() async {
        struct Fake: DriveTimer {
            func time(_ points: [LatLon]) async throws -> DriveTime {
                if points.first?.lat == 0 { throw GoogleRoutesClient.Failure.noRoute }
                return DriveTime(seconds: points[0].lat * 60)
            }
        }
        let commute = Commute(name: "Home", routes: [
            CommuteRoute(name: "Broken", link: "", points: [LatLon(lat: 0, lon: 0), LatLon(lat: 1, lon: 0)]),
            CommuteRoute(name: "Slow", link: "", points: [LatLon(lat: 60, lon: 0), LatLon(lat: 1, lon: 0)]),
            CommuteRoute(name: "Quick", link: "", points: [LatLon(lat: 40, lon: 0), LatLon(lat: 1, lon: 0)]),
        ])
        let advice = await CommuteAdvisor.check(commute, with: Fake(), now: now)
        XCTAssertEqual(advice.checks.map(\.route.name), ["Broken", "Slow", "Quick"])
        XCTAssertEqual(advice.checks[0].problem, "Google couldn't find that route.")
        XCTAssertEqual(advice.pick?.route.name, "Quick")
    }
}
