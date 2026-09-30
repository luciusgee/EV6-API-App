import Foundation

/// One drive from the car's own trip log (Kia's `tripinfo`).
public struct CarTrip: Codable, Equatable, Sendable {
    public var start: Date
    public var driveMinutes: Double
    public var idleMinutes: Double
    public var distanceKm: Double
    public var averageKmh: Double?
    public var maxKmh: Double?

    public init(start: Date, driveMinutes: Double, idleMinutes: Double = 0, distanceKm: Double, averageKmh: Double? = nil, maxKmh: Double? = nil) {
        self.start = start
        self.driveMinutes = driveMinutes
        self.idleMinutes = idleMinutes
        self.distanceKm = distanceKm
        self.averageKmh = averageKmh
        self.maxKmh = maxKmh
    }

    public var end: Date { start.addingTimeInterval((driveMinutes + idleMinutes) * 60) }

    /// The clock Kia's EU trip log is written in.
    public static let kiaCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    /// Kia's day trip list: `resMsg.dayTripList[].tripList[]` with the day as "yyyyMMdd" and each trip's
    /// time as "HHmmss", in the car's (the owner's) time zone.
    /// `requested` is the day asked for: a one-day reply doesn't always say which day it is.
    static func parseDay(_ json: JSONValue, requested: CalendarDay? = nil, calendar: Calendar = .current) -> [CarTrip] {
        var out: [CarTrip] = []
        let asked = requested.map { String(format: "%04d%02d%02d", $0.year, $0.month, $0.day) }
        for day in json.path("resMsg.dayTripList")?.array ?? [] {
            guard let raw = day["tripDayInMonth"]?.str ?? day["tripDay"]?.str ?? asked, raw.count == 8,
                  let y = Int(raw.prefix(4)), let m = Int(raw.dropFirst(4).prefix(2)), let d = Int(raw.suffix(2)) else { continue }
            for trip in day["tripList"]?.array ?? [] {
                guard let t = trip["tripTime"]?.str ?? trip["serviceTC"]?.str.map({ String($0.suffix(6)) }), t.count >= 4,
                      let hh = Int(t.prefix(2)), let mm = Int(t.dropFirst(2).prefix(2)) else { continue }
                let ss = t.count >= 6 ? Int(t.dropFirst(4).prefix(2)) ?? 0 : 0
                var comps = DateComponents(year: y, month: m, day: d, hour: hh, minute: mm, second: ss)
                comps.timeZone = calendar.timeZone
                guard let start = calendar.date(from: comps) else { continue }
                out.append(CarTrip(
                    start: start,
                    driveMinutes: number(trip["tripDrvTime"]) ?? 0,
                    idleMinutes: number(trip["tripIdleTime"]) ?? 0,
                    distanceKm: number(trip["tripDist"]) ?? 0,
                    averageKmh: number(trip["tripAvgSpeed"]),
                    maxKmh: number(trip["tripMaxSpeed"])
                ))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    private static func number(_ v: JSONValue?) -> Double? {
        v?.num ?? v?.str.flatMap(Double.init)
    }
}

/// Where the car was seen parked, from each read of its state.
public struct CarSighting: Codable, Equatable, Sendable {
    public var at: Date
    public var position: LatLon

    public init(at: Date, position: LatLon) {
        self.at = at
        self.position = position
    }
}

/// The car's drives and where it was seen parked: enough to say when it arrived at and left a place.
public struct CarMovements: Codable, Equatable, Sendable {
    public var trips: [CarTrip] = []
    public var sightings: [CarSighting] = []
    /// Days fetched ("2026-09-28") and when: a day fetched after it ended never changes.
    public var fetched: [String: Date] = [:]
    /// Trips were read in Kia's own time zone. Before that they were an hour out in the UK, so
    /// older saved trips are fetched again.
    public var tripTimesInKiaZone: Bool?

    /// Forgets trips read with the wrong clock, so they're fetched again. True when anything changed.
    public mutating func dropTripsWithOldTimes() -> Bool {
        guard tripTimesInKiaZone != true else { return false }
        tripTimesInKiaZone = true
        trips = []
        fetched = [:]
        return true
    }

    public init() {}

    /// Keep this much history.
    static let keep: TimeInterval = 120 * 86400

    public mutating func record(_ sighting: CarSighting) {
        if let last = sightings.last, last.at == sighting.at { return }
        sightings.append(sighting)
        sightings.sort { $0.at < $1.at }
        let cutoff = sighting.at.addingTimeInterval(-Self.keep)
        sightings.removeAll { $0.at < cutoff }
    }

    /// Replaces the trips for `day` with a fresh list.
    public mutating func store(_ newTrips: [CarTrip], for day: CalendarDay, fetchedAt: Date, calendar: Calendar = .current) {
        trips.removeAll { CalendarDay(date: $0.start, calendar: calendar) == day }
        trips.append(contentsOf: newTrips)
        trips.sort { $0.start < $1.start }
        fetched[day.description] = fetchedAt
        let cutoff = fetchedAt.addingTimeInterval(-Self.keep)
        trips.removeAll { $0.start < cutoff }
    }

    /// Whether `day` still needs fetching: never fetched, or fetched before it was over.
    public func needs(_ day: CalendarDay, now: Date, calendar: Calendar = .current) -> Bool {
        guard let at = fetched[day.description] else { return true }
        guard let start = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return true }
        if at >= end.addingTimeInterval(30 * 60) { return false }
        // Today: at most once every 20 minutes.
        return now.timeIntervalSince(at) > 20 * 60
    }

    /// Stays at tracked places: each gap between one drive's end and the next drive's start, placed
    /// by where the car was seen parked during it. A gap nobody saw the car in is left out.
    public func stays(places: [Place], tracked: Set<String>, now: Date) -> [Visit] {
        let watched = places.filter { tracked.contains($0.id) }
        guard !watched.isEmpty, !trips.isEmpty else { return [] }
        var out: [Visit] = []
        for (i, trip) in trips.enumerated() {
            let arrived = trip.end
            let next = i + 1 < trips.count ? trips[i + 1].start : nil
            guard next.map({ $0 > arrived }) ?? true else { continue }
            // Seen parked during the gap (a little slack for the car's upload after switching off).
            let seen = sightings.last { $0.at >= arrived.addingTimeInterval(-120) && $0.at <= (next ?? now).addingTimeInterval(60) }
            let place: Place?
            if let seen {
                place = watched.first { $0.centre.distance(to: seen.position) <= Double($0.radiusM) + 75 }
            } else {
                place = guessPlace(arrivingBy: trip, leavingBy: next == nil ? nil : trips[i + 1],
                                   parkedSince: i > 0 ? trips[i - 1].end : nil,
                                   parkedUntil: i + 2 < trips.count ? trips[i + 2].start : now, among: watched)
            }
            guard let place else { continue }
            out.append(Visit(
                id: "car-\(Int(arrived.timeIntervalSince1970))",
                placeId: place.id, arrived: arrived, left: next, source: .car
            ))
        }
        return out
    }

    /// Nobody saw where the car stopped: work it out from where it was seen before the drive there or
    /// after the drive away, and how far those drives went. Only a single tracked place that fits both
    /// counts (roads are longer than a straight line, but not usually by more than about 2.5 times).
    /// `parkedSince`/`parkedUntil` bound the stops either side, so only sightings from those count.
    func guessPlace(arrivingBy inbound: CarTrip, leavingBy outbound: CarTrip?, parkedSince: Date?, parkedUntil: Date,
                    among watched: [Place]) -> Place? {
        func fits(_ place: Place, from known: LatLon, drive: CarTrip) -> Bool {
            let straight = max(0, place.centre.distance(to: known) - Double(place.radiusM)) / 1000
            return drive.distanceKm > 0.5 && straight <= drive.distanceKm * 1.05 + 0.3 && straight >= drive.distanceKm * 0.4
        }
        let before = sightings.last { $0.at <= inbound.start.addingTimeInterval(60) && $0.at >= (parkedSince ?? .distantPast).addingTimeInterval(-120) }
        let after = outbound.flatMap { out in
            sightings.first { $0.at >= out.end.addingTimeInterval(-120) && $0.at <= parkedUntil.addingTimeInterval(60) }
        }
        guard before != nil || after != nil else { return nil }
        let matches = watched.filter { place in
            (before.map { fits(place, from: $0.position, drive: inbound) } ?? true)
                && (after.map { a in outbound.map { fits(place, from: a.position, drive: $0) } ?? true } ?? true)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

public extension CalendarDay {
    init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}
