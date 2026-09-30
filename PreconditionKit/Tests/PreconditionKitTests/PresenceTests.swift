import XCTest
@testable import PreconditionKit

final class PresenceTests: XCTestCase {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func stay(_ place: String, _ from: String, _ to: String?) -> Visit {
        Visit(placeId: place, arrived: date(from), left: to.map(date), source: .car)
    }

    func testDaysAddUpStaysSplitAtMidnightAndCapAMissedTrip() {
        var log = PresenceLog()
        log.trackedPlaceIds = ["work"]
        log.replaceCarStays([
            stay("work", "2026-09-29T09:00:00Z", "2026-09-29T12:00:00Z"),
            stay("work", "2026-09-29T13:00:00Z", "2026-09-29T17:00:00Z"),
            stay("work", "2026-09-30T22:00:00Z", nil),
        ])
        let rows = log.days(from: date("2026-09-29T00:00:00Z"), to: date("2026-10-02T00:00:00Z"), now: date("2026-10-02T12:00:00Z"), calendar: utc)
        let seconds: [TimeInterval] = [14 * 3600, 2 * 3600, 7 * 3600]
        XCTAssertEqual(rows.map(\.seconds), seconds)
        XCTAssertTrue(rows[0].open)
        XCTAssertEqual(rows[2].firstArrival, date("2026-09-29T09:00:00Z"))
        XCTAssertEqual(rows[2].lastDeparture, date("2026-09-29T17:00:00Z"))
        XCTAssertEqual(DisplayText.hours(7 * 3600 + 45 * 60), "7 h 45 m")
    }

    func testHandMadeStaysSurviveAndOldPhoneStaysDontCount() {
        var log = PresenceLog()
        log.visits = [
            Visit(placeId: "work", arrived: date("2026-09-28T09:00:00Z"), left: date("2026-09-28T17:00:00Z"), source: .manual),
            Visit(placeId: "work", arrived: date("2026-09-27T09:00:00Z"), left: date("2026-09-27T17:00:00Z"), source: .boundary),
        ]
        log.replaceCarStays([stay("work", "2026-09-29T09:00:00Z", "2026-09-29T10:00:00Z")])
        XCTAssertEqual(log.visits.count, 2)
        let total = log.seconds(at: "work", from: .distantPast, to: .distantFuture, now: date("2026-09-30T00:00:00Z"))
        XCTAssertEqual(total, 9 * 3600)
    }

    func testTimesheetCSV() {
        var log = PresenceLog()
        log.replaceCarStays([stay("work", "2026-09-28T08:55:00Z", "2026-09-28T17:40:00Z")])
        let csv = log.csv(from: date("2026-09-28T00:00:00Z"), to: date("2026-09-29T00:00:00Z"), placeNames: ["work": "Work, Leeds"], now: date("2026-09-29T00:00:00Z"), calendar: utc)
        XCTAssertEqual(csv, "Date,Place,Arrived,Left,Hours\n2026-09-28,Work  Leeds,08:55,17:40,8.75\n")
    }

    // MARK: The car's trips

    static let dayTrips = #"""
    {"retCode":"S","resCode":"0000","resMsg":{"dayTripList":[{"tripDayInMonth":"20260928","tripCnt":3,"tripList":[
      {"tripTime":"082500","tripDrvTime":28,"tripIdleTime":2,"tripDist":21.5,"tripAvgSpeed":46,"tripMaxSpeed":98},
      {"tripTime":"123000","tripDrvTime":6,"tripIdleTime":0,"tripDist":2.1,"tripAvgSpeed":21,"tripMaxSpeed":48},
      {"tripTime":"173000","tripDrvTime":30,"tripIdleTime":1,"tripDist":21.4,"tripAvgSpeed":42,"tripMaxSpeed":96}
    ]}]}}
    """#

    func testParsesTheCarsDayTrips() throws {
        let trips = CarTrip.parseDay(try XCTUnwrap(JSONValue.parse(Data(Self.dayTrips.utf8))), calendar: utc)
        XCTAssertEqual(trips.count, 3)
        XCTAssertEqual(trips[0].start, date("2026-09-28T08:25:00Z"))
        XCTAssertEqual(trips[0].end, date("2026-09-28T08:55:00Z"))
        XCTAssertEqual(trips[0].distanceKm, 21.5)
    }

    func testTheCarsTripsAndParkedPositionsGiveTheStays() throws {
        let work = Place(id: "work", name: "Work", centre: LatLon(lat: 53.8, lon: -1.55), radiusM: 200)
        let home = Place(id: "home", name: "Home", centre: LatLon(lat: 53.9, lon: -1.6), radiusM: 150)
        var m = CarMovements()
        m.store(CarTrip.parseDay(try XCTUnwrap(JSONValue.parse(Data(Self.dayTrips.utf8))), calendar: utc), for: CalendarDay(2026, 9, 28), fetchedAt: date("2026-09-28T20:00:00Z"), calendar: utc)
        // Seen at work mid-morning and mid-afternoon, somewhere else at lunch, home in the evening.
        m.record(CarSighting(at: date("2026-09-28T10:00:00Z"), position: LatLon(lat: 53.8003, lon: -1.5502)))
        m.record(CarSighting(at: date("2026-09-28T12:50:00Z"), position: LatLon(lat: 53.81, lon: -1.56)))
        m.record(CarSighting(at: date("2026-09-28T15:00:00Z"), position: LatLon(lat: 53.8001, lon: -1.5499)))
        m.record(CarSighting(at: date("2026-09-28T19:00:00Z"), position: LatLon(lat: 53.9, lon: -1.6)))
        let stays = m.stays(places: [work, home], tracked: ["work"], now: date("2026-09-28T21:00:00Z"))
        // 08:55 → 12:30 at work; the lunch stop isn't a tracked place; back 12:36 → 17:30; home isn't tracked.
        XCTAssertEqual(stays.map(\.arrived), [date("2026-09-28T08:55:00Z"), date("2026-09-28T12:36:00Z")])
        XCTAssertEqual(stays.map(\.left), [date("2026-09-28T12:30:00Z"), date("2026-09-28T17:30:00Z")])

        var log = PresenceLog()
        log.trackedPlaceIds = ["work"]
        log.replaceCarStays(stays)
        let secs = log.seconds(at: "work", from: date("2026-09-28T00:00:00Z"), to: date("2026-09-29T00:00:00Z"), now: date("2026-09-28T21:00:00Z"))
        // 3 h 35 m + 4 h 54 m.
        let expected: TimeInterval = 30_540
        XCTAssertEqual(secs, expected)

        // Fetched at 8 pm the 28th wasn't the whole day; fetched the next morning, it's done.
        XCTAssertTrue(m.needs(CalendarDay(2026, 9, 28), now: date("2026-09-29T09:00:00Z"), calendar: utc))
        m.store([], for: CalendarDay(2026, 9, 28), fetchedAt: date("2026-09-29T09:00:00Z"), calendar: utc)
        XCTAssertFalse(m.needs(CalendarDay(2026, 9, 28), now: date("2026-09-29T10:00:00Z"), calendar: utc))
        XCTAssertTrue(m.needs(CalendarDay(2026, 9, 27), now: date("2026-09-29T09:00:00Z"), calendar: utc))
    }

    func testAStopNobodySawIsWorkedOutFromTheDrives() throws {
        let work = Place(id: "work", name: "Work", centre: LatLon(lat: 53.8, lon: -1.55), radiusM: 200)
        let home = Place(id: "home", name: "Home", centre: LatLon(lat: 53.9, lon: -1.6), radiusM: 150)
        var m = CarMovements()
        // A one-day reply that doesn't say which day it is.
        let reply = Self.dayTrips.replacingOccurrences(of: #""tripDayInMonth":"20260928","#, with: "")
        let trips = CarTrip.parseDay(try XCTUnwrap(JSONValue.parse(Data(reply.utf8))), requested: CalendarDay(2026, 9, 28), calendar: utc)
        XCTAssertEqual(trips.count, 3)
        m.store(trips, for: CalendarDay(2026, 9, 28), fetchedAt: date("2026-09-28T20:00:00Z"), calendar: utc)
        // Only ever seen at home: before leaving and in the evening.
        m.record(CarSighting(at: date("2026-09-28T07:00:00Z"), position: LatLon(lat: 53.9001, lon: -1.6)))
        m.record(CarSighting(at: date("2026-09-28T19:00:00Z"), position: LatLon(lat: 53.9, lon: -1.6001)))
        let stays = m.stays(places: [work, home], tracked: ["work", "home"], now: date("2026-09-28T21:00:00Z"))
        // Home, then a 21.5 km drive: work. After the lunch hop, a 21.4 km drive home: back at work. Home that evening was seen.
        XCTAssertEqual(stays.map(\.placeId), ["work", "work", "home"])
        XCTAssertEqual(stays.first?.arrived, date("2026-09-28T08:55:00Z"))
    }

    func testKiaTripTimesAreCentralEuropeanNotUK() throws {
        // 08:25 on Kia's clock in late September (CEST, UTC+2) is 07:25 in the UK (BST).
        let trips = CarTrip.parseDay(try XCTUnwrap(JSONValue.parse(Data(Self.dayTrips.utf8))), calendar: CarTrip.kiaCalendar)
        XCTAssertEqual(trips[0].start, date("2026-09-28T06:25:00Z"))
        var old = CarMovements()
        old.store(trips, for: CalendarDay(2026, 9, 28), fetchedAt: date("2026-09-28T20:00:00Z"), calendar: utc)
        XCTAssertTrue(old.dropTripsWithOldTimes())
        XCTAssertTrue(old.trips.isEmpty)
        XCTAssertTrue(old.needs(CalendarDay(2026, 9, 28), now: date("2026-09-29T09:00:00Z"), calendar: utc))
        XCTAssertFalse(old.dropTripsWithOldTimes())
    }
}
