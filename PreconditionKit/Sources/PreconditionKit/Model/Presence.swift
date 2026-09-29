import Foundation

/// A stay at one of your places: when you arrived and left.
public struct Visit: Codable, Equatable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// From an earlier version that used the phone's location; no longer counted.
        case boundary, visit
        /// Added or corrected by hand.
        case manual
        /// Worked out from the car's trips and where it was parked.
        case car
    }

    public var id: String
    public var placeId: String
    public var arrived: Date
    /// Nil while you're still there.
    public var left: Date?
    public var source: Source

    public init(id: String = UUID().uuidString, placeId: String, arrived: Date, left: Date? = nil, source: Source) {
        self.id = id
        self.placeId = placeId
        self.arrived = arrived
        self.left = left
        self.source = source
    }
}

/// Every stay at the places you track time at, worked out from the car's trips.
public struct PresenceLog: Codable, Equatable, Sendable {
    public var visits: [Visit] = []
    public var trackedPlaceIds: Set<String> = []

    public init() {}

    /// A stay with no departure after this long is assumed to have ended (a missed trip).
    public static let maxOpen: TimeInterval = 16 * 3600

    /// The stays that count: the car's, and any added by hand.
    public var counted: [Visit] {
        visits.filter { $0.source == .car || $0.source == .manual }
    }

    /// Replaces the car's stays with a freshly worked-out set.
    public mutating func replaceCarStays(_ stays: [Visit]) {
        visits.removeAll { $0.source != .manual }
        visits.append(contentsOf: stays)
        visits.sort { $0.arrived < $1.arrived }
    }

    /// When a stay ends for counting: its departure, now if you're still there, or capped for a missed exit.
    public static func end(of v: Visit, now: Date) -> Date {
        if let left = v.left { return left }
        return min(now, v.arrived.addingTimeInterval(maxOpen))
    }

    /// Seconds at `placeId` within [from, to).
    public func seconds(at placeId: String, from: Date, to: Date, now: Date) -> TimeInterval {
        counted.filter { $0.placeId == placeId }.reduce(0) { sum, v in
            let start = max(v.arrived, from)
            let end = min(Self.end(of: v, now: now), to)
            return sum + max(0, end.timeIntervalSince(start))
        }
    }

    /// One row per place per day: the first arrival, last departure and time there that day.
    public struct DayRow: Equatable, Identifiable, Sendable {
        public var day: Date
        public var placeId: String
        public var firstArrival: Date
        public var lastDeparture: Date
        public var seconds: TimeInterval
        /// A stay still going, or a missed departure.
        public var open: Bool
        public var id: String { "\(placeId)@\(day.timeIntervalSince1970)" }
    }

    /// Days from `from` to `to`, newest first; stays across midnight are split between the days.
    public func days(from: Date, to: Date, placeIds: Set<String>? = nil, now: Date, calendar: Calendar = .current) -> [DayRow] {
        var rows: [String: DayRow] = [:]
        for v in counted where placeIds?.contains(v.placeId) ?? true {
            var start = max(v.arrived, from)
            let end = min(Self.end(of: v, now: now), to)
            while start < end {
                let day = calendar.startOfDay(for: start)
                let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? end
                let pieceEnd = min(end, nextDay)
                let key = "\(v.placeId)@\(day.timeIntervalSince1970)"
                var row = rows[key] ?? DayRow(day: day, placeId: v.placeId, firstArrival: start, lastDeparture: pieceEnd, seconds: 0, open: false)
                row.firstArrival = min(row.firstArrival, start)
                row.lastDeparture = max(row.lastDeparture, pieceEnd)
                row.seconds += pieceEnd.timeIntervalSince(start)
                if v.left == nil && pieceEnd == end { row.open = true }
                rows[key] = row
                start = pieceEnd
            }
        }
        return rows.values.sorted { $0.day == $1.day ? $0.placeId < $1.placeId : $0.day > $1.day }
    }

    /// A timesheet: Date, Place, Arrived, Left, Hours; oldest first.
    public func csv(from: Date, to: Date, placeNames: [String: String], now: Date, calendar: Calendar = .current) -> String {
        let date = DateFormatter()
        date.calendar = calendar
        date.timeZone = calendar.timeZone
        date.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        var lines = ["Date,Place,Arrived,Left,Hours"]
        for row in days(from: from, to: to, now: now, calendar: calendar).reversed() {
            let name = (placeNames[row.placeId] ?? row.placeId).replacingOccurrences(of: ",", with: " ")
            lines.append([
                date.string(from: row.day), name, time.string(from: row.firstArrival),
                row.open ? "" : time.string(from: row.lastDeparture), String(format: "%.2f", row.seconds / 3600),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public extension DisplayText {
    /// "7 h 45 m", "25 m".
    static func hours(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) m" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) m"
    }
}
