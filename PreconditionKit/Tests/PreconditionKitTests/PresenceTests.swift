import XCTest
@testable import PreconditionKit

final class PresenceTests: XCTestCase {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func tracked(_ ids: String...) -> PresenceLog {
        var log = PresenceLog()
        log.trackedPlaceIds = Set(ids)
        return log
    }

    func testAWorkingDayWithALunchWalkIsOneStay() {
        var log = tracked("work", "home")
        log.arrive("work", at: date("2026-09-28T08:55:00Z"), source: .boundary)
        log.leave("work", at: date("2026-09-28T12:30:00Z"), source: .boundary)
        // Back in 8 minutes: the same stay.
        log.arrive("work", at: date("2026-09-28T12:38:00Z"), source: .boundary)
        log.leave("work", at: date("2026-09-28T17:40:00Z"), source: .boundary)
        XCTAssertEqual(log.visits.count, 1)
        let secs = log.seconds(at: "work", from: date("2026-09-28T00:00:00Z"), to: date("2026-09-29T00:00:00Z"), now: date("2026-09-29T09:00:00Z"))
        XCTAssertEqual(secs, 8 * 3600 + 45 * 60)
        XCTAssertEqual(DisplayText.hours(secs), "8 h 45 m")

        // A long lunch out is two stays, and the day adds them up.
        log.arrive("work", at: date("2026-09-29T09:00:00Z"), source: .boundary)
        log.leave("work", at: date("2026-09-29T12:00:00Z"), source: .boundary)
        log.arrive("work", at: date("2026-09-29T13:00:00Z"), source: .boundary)
        log.leave("work", at: date("2026-09-29T17:00:00Z"), source: .boundary)
        let rows = log.days(from: date("2026-09-29T00:00:00Z"), to: date("2026-09-30T00:00:00Z"), now: date("2026-09-30T00:00:00Z"), calendar: utc)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].seconds, 7 * 3600)
        XCTAssertEqual(rows[0].firstArrival, date("2026-09-29T09:00:00Z"))
        XCTAssertEqual(rows[0].lastDeparture, date("2026-09-29T17:00:00Z"))
    }

    func testArrivingSomewhereElseEndsTheLastStayAndUntrackedPlacesAreIgnored() {
        var log = tracked("work", "home")
        log.arrive("work", at: date("2026-09-28T09:00:00Z"), source: .boundary)
        // The exit was missed; getting home ends work.
        log.arrive("home", at: date("2026-09-28T18:00:00Z"), source: .boundary)
        XCTAssertEqual(log.visits.first { $0.placeId == "work" }?.left, date("2026-09-28T18:00:00Z"))
        log.arrive("gym", at: date("2026-09-28T19:00:00Z"), source: .boundary)
        XCTAssertFalse(log.visits.contains { $0.placeId == "gym" })
    }

    func testAMissedExitIsCappedAndANightShiftSplitsAcrossMidnight() {
        var log = tracked("work")
        log.arrive("work", at: date("2026-09-28T22:00:00Z"), source: .boundary)
        let now = date("2026-09-30T12:00:00Z")
        // Never left: counted up to 16 hours, then flagged.
        XCTAssertEqual(log.seconds(at: "work", from: .distantPast, to: .distantFuture, now: now), 16 * 3600)
        let rows = log.days(from: date("2026-09-28T00:00:00Z"), to: date("2026-10-01T00:00:00Z"), now: now, calendar: utc)
        let expected: [TimeInterval] = [14 * 3600, 2 * 3600]
        XCTAssertEqual(rows.map(\.seconds), expected)
        XCTAssertTrue(rows[0].open)
    }

    func testAVisitReportFillsInAMissedArrival() {
        var log = tracked("work")
        log.leave("work", at: date("2026-09-28T17:00:00Z"), arrivedAt: date("2026-09-28T09:10:00Z"), source: .visit)
        XCTAssertEqual(log.visits.count, 1)
        XCTAssertEqual(log.visits[0].arrived, date("2026-09-28T09:10:00Z"))
        // The same visit reported again isn't doubled.
        log.leave("work", at: date("2026-09-28T17:00:00Z"), arrivedAt: date("2026-09-28T09:10:00Z"), source: .visit)
        XCTAssertEqual(log.visits.count, 1)
    }

    func testTimesheetCSV() {
        var log = tracked("work")
        log.arrive("work", at: date("2026-09-28T08:55:00Z"), source: .boundary)
        log.leave("work", at: date("2026-09-28T17:40:00Z"), source: .boundary)
        let csv = log.csv(from: date("2026-09-28T00:00:00Z"), to: date("2026-09-29T00:00:00Z"), placeNames: ["work": "Work, Leeds"], now: date("2026-09-29T00:00:00Z"), calendar: utc)
        XCTAssertEqual(csv, "Date,Place,Arrived,Left,Hours\n2026-09-28,Work  Leeds,08:55,17:40,8.75\n")
    }

    func testTrackedPlacesAreWatchedBothWaysAndFirst() {
        let places = (0..<25).map { Place(id: "p\($0)", name: "P\($0)", centre: LatLon(lat: 51, lon: Double($0) / 100), radiusM: 200) }
        let specs = Geofences.required([], places: places, tracked: ["p24"])
        XCTAssertEqual(specs.first?.id, "place:p24")
        XCTAssertEqual(specs.first?.enter, true)
        XCTAssertEqual(specs.first?.exit, true)
        XCTAssertEqual(Geofences.placeId(for: "place:p24"), "p24")
        XCTAssertNil(Geofences.placeId(for: "car:200"))
    }
}
