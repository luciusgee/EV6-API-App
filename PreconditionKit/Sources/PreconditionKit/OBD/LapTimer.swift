import Foundation

/// A place on the ground, in degrees.
public struct GeoPoint: Codable, Equatable, Sendable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    static let earthRadius = 6_371_000.0

    /// Metres east and north of `origin`. Flat-earth, which is exact enough across a circuit.
    func offset(from origin: GeoPoint) -> (x: Double, y: Double) {
        let k = Double.pi / 180
        return ((lon - origin.lon) * k * cos(origin.lat * k) * Self.earthRadius, (lat - origin.lat) * k * Self.earthRadius)
    }

    public func metres(to other: GeoPoint) -> Double {
        let o = other.offset(from: self)
        return (o.x * o.x + o.y * o.y).squareRoot()
    }
}

/// A start/finish line: where it is, the way the car crosses it, and how wide it is.
public struct FinishLine: Codable, Equatable, Sendable {
    public var centre: GeoPoint
    /// Direction of travel across the line, degrees clockwise from north.
    public var heading: Double
    /// Metres either side of the centre that count.
    public var halfWidth: Double

    public init(centre: GeoPoint, heading: Double, halfWidth: Double = 20) {
        self.centre = centre
        self.heading = heading
        self.halfWidth = halfWidth
    }

    /// Metres ahead of the line along the direction of travel, and metres to the side of the centre.
    func position(_ p: GeoPoint) -> (ahead: Double, side: Double) {
        let o = p.offset(from: centre)
        let h = heading * Double.pi / 180
        let fx = sin(h), fy = cos(h)
        return (o.x * fx + o.y * fy, o.x * fy - o.y * fx)
    }
}

public struct Lap: Codable, Equatable, Sendable, Identifiable {
    public var number: Int
    public var seconds: Double
    public var metres: Double
    public var topKmh: Double
    public var id: Int { number }
}

extension Lap {
    /// Lenient, so laps saved by another build still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        seconds = try c.decode(Double.self, forKey: .seconds)
        metres = try c.decodeIfPresent(Double.self, forKey: .metres) ?? 0
        topKmh = try c.decodeIfPresent(Double.self, forKey: .topKmh) ?? 0
    }
}

/// Times laps from GPS fixes crossing a start/finish line. Crossings are interpolated between fixes.
public struct LapTimer: Sendable {
    public let line: FinishLine
    public private(set) var laps: [Lap] = []
    /// When the lap under way started; nil until the car first crosses the line, unless the timer was started on it.
    public private(set) var lapStart: Date?
    private var last: (at: Date, point: GeoPoint, ahead: Double, side: Double)?
    private var lapMetres = 0.0
    private var lapTop = 0.0
    /// Seconds into the lap at each distance, for the lap under way and the best lap.
    private var current: [(metres: Double, seconds: Double)] = []
    private var bestTrace: [(metres: Double, seconds: Double)] = []

    /// Crossings closer together than this are GPS wobble, not laps.
    public static let minimumLap: Double = 15
    /// Slower than this (km/h), a crossing is GPS wobble while parked or crawling near the line.
    public static let minimumCrossingKmh: Double = 18
    /// A crossing must be heading within this many degrees of the line's direction.
    public static let maximumCrossingAngle: Double = 60

    /// `startedAt` is when the car was on the line as it was set: the first lap runs from then.
    public init(line: FinishLine, startedAt: Date? = nil) {
        self.line = line
        if let startedAt {
            lapStart = startedAt
            last = (startedAt, line.centre, 0, 0)
        }
    }

    public var best: Lap? { laps.min { $0.seconds < $1.seconds } }

    public func elapsed(at now: Date) -> Double? {
        lapStart.map { now.timeIntervalSince($0) }
    }

    /// Ahead (+) or behind (–) the best lap at this point of the lap, seconds. Negative is faster.
    public var delta: Double? {
        guard let here = current.last, !bestTrace.isEmpty else { return nil }
        guard let i = bestTrace.firstIndex(where: { $0.metres >= here.metres }) else { return nil }
        let b = bestTrace[i]
        var bestSeconds = b.seconds
        if i > 0 {
            let a = bestTrace[i - 1]
            let f = b.metres > a.metres ? (here.metres - a.metres) / (b.metres - a.metres) : 1
            bestSeconds = a.seconds + (b.seconds - a.seconds) * f
        }
        return here.seconds - bestSeconds
    }

    /// Feeds one GPS fix, with its speed and course (degrees from north) when known. Returns the lap it completed, if it did.
    @discardableResult
    public mutating func add(at: Date, point: GeoPoint, kmh: Double? = nil, course: Double? = nil) -> Lap? {
        let pos = line.position(point)
        defer { last = (at, point, pos.ahead, pos.side) }
        guard let last else { return nil }
        let step = last.point.metres(to: point)
        lapMetres += step
        if let kmh { lapTop = max(lapTop, kmh) }

        // Crossed from behind the line to ahead of it, near enough to the centre.
        guard last.ahead < 0, pos.ahead >= 0, isDriving(kmh: kmh, course: course) else {
            record(at: at)
            return nil
        }
        let f = pos.ahead > last.ahead ? -last.ahead / (pos.ahead - last.ahead) : 1
        let side = last.side + (pos.side - last.side) * f
        guard abs(side) <= line.halfWidth else {
            record(at: at)
            return nil
        }
        let crossed = last.at.addingTimeInterval(at.timeIntervalSince(last.at) * f)
        let pastLine = step * (1 - f)

        var done: Lap?
        if let lapStart {
            let seconds = crossed.timeIntervalSince(lapStart)
            guard seconds >= Self.minimumLap else {
                record(at: at)
                return nil
            }
            let lap = Lap(number: laps.count + 1, seconds: seconds, metres: lapMetres - pastLine, topKmh: lapTop)
            current.append((lap.metres, seconds))
            if lap.seconds < (best?.seconds ?? .infinity) { bestTrace = current }
            laps.append(lap)
            done = lap
        }
        lapStart = crossed
        lapMetres = pastLine
        lapTop = kmh ?? 0
        current = []
        record(at: at)
        return done
    }

    /// Moving at speed the line's way, so a crossing is real and not jitter around a parked car.
    private func isDriving(kmh: Double?, course: Double?) -> Bool {
        if let kmh, kmh < Self.minimumCrossingKmh { return false }
        if let course, course >= 0 {
            let off = abs((course - line.heading).truncatingRemainder(dividingBy: 360))
            if min(off, 360 - off) > Self.maximumCrossingAngle { return false }
        }
        return true
    }

    private mutating func record(at: Date) {
        guard let lapStart else { return }
        current.append((lapMetres, at.timeIntervalSince(lapStart)))
    }
}
