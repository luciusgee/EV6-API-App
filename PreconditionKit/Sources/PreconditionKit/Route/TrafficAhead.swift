import Foundation

public extension Polyline {
    static func decode(_ text: String) -> [LatLon] {
        var out: [LatLon] = []
        var lat = 0, lon = 0
        var chars = Array(text.utf8)[...]
        func next() -> Int? {
            var result = 0, shift = 0
            while let c = chars.first {
                chars = chars.dropFirst()
                let b = Int(c) - 63
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
            }
            return nil
        }
        while !chars.isEmpty {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat
            lon += dLon
            out.append(LatLon(lat: Double(lat) / 1e5, lon: Double(lon) / 1e5))
        }
        return out
    }
}

/// One way to drive from here to there, with current traffic.
public struct DriveOption: Equatable, Identifiable, Sendable {
    public var id: Int
    /// "M1 and A14", when the source says.
    public var name: String
    public var time: DriveTime
    public var path: [LatLon]

    public init(id: Int, name: String, time: DriveTime, path: [LatLon]) {
        self.id = id
        self.name = name
        self.time = time
        self.path = path
    }
}

public extension GoogleRoutesClient {
    /// The best route now and up to two alternatives, with traffic.
    func alternatives(from: LatLon, to: LatLon) async throws -> [DriveOption] {
        var body = Self.body([from, to])
        if case .object(var o) = body {
            o["computeAlternativeRoutes"] = true
            body = .object(o)
        }
        let request = HTTPRequest(
            method: "POST",
            url: URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!,
            headers: [
                "Content-Type": "application/json",
                "X-Goog-Api-Key": key,
                "X-Goog-FieldMask": "routes.duration,routes.staticDuration,routes.distanceMeters,routes.description,routes.polyline.encodedPolyline",
            ],
            body: body.data
        )
        let response = try await transport.send(request)
        if response.status == 401 || response.status == 403 { throw Failure.badKey }
        guard response.status == 200 else { throw Failure.http(response.status) }
        let routes = JSONValue.parse(response.body)?["routes"]?.array ?? []
        let options: [DriveOption] = routes.enumerated().compactMap { i, r -> DriveOption? in
            guard let seconds = Self.seconds(r["duration"]?.str) else { return nil }
            let name = r["description"]?.str ?? ""
            return DriveOption(
                id: i,
                name: name.isEmpty ? "Route \(i + 1)" : name,
                time: DriveTime(seconds: seconds, typicalSeconds: Self.seconds(r["staticDuration"]?.str), meters: r["distanceMeters"]?.num),
                path: Polyline.decode(r.path("polyline.encodedPolyline")?.str ?? "")
            )
        }
        guard !options.isEmpty else { throw Failure.noRoute }
        return options
    }
}

public enum TrafficAhead {
    /// A point on `route` as far as possible from every other route: sending it as a waypoint makes the
    /// car's nav take this way. Nil when the routes don't split by at least `minimumM`.
    public static func distinctivePoint(of route: [LatLon], avoiding others: [[LatLon]], minimumM: Double = 1500) -> LatLon? {
        let others = others.map { thin($0, every: 250) }.filter { !$0.isEmpty }
        guard !others.isEmpty else { return nil }
        var best: (LatLon, Double)?
        for p in thin(route, every: 250) {
            let gap = others.map { path in path.map { $0.distance(to: p) }.min() ?? 0 }.min() ?? 0
            if gap > (best?.1 ?? 0) { best = (p, gap) }
        }
        guard let best, best.1 >= minimumM else { return nil }
        return best.0
    }

    /// Keeps a point about every `every` metres, for speed.
    static func thin(_ path: [LatLon], every: Double) -> [LatLon] {
        guard let first = path.first else { return [] }
        var out = [first]
        for p in path.dropFirst() where p.distance(to: out[out.count - 1]) >= every {
            out.append(p)
        }
        if let last = path.last, out.last != last { out.append(last) }
        return out
    }

    /// "Clear: 1 h 12 min, arrive 18:40." or "Heavy traffic: 25 min of delays."
    public static func summary(_ options: [DriveOption]) -> String {
        guard let best = options.min(by: { $0.time.seconds < $1.time.seconds }) else { return "No routes found." }
        let delay = best.time.delayMinutes ?? 0
        let lead: String
        switch delay {
        case ..<5: lead = "Traffic's clear"
        case ..<15: lead = "Some traffic"
        default: lead = "Heavy traffic"
        }
        var text = "\(lead): \(duration(best.time.seconds)) on the quickest way, \(best.name)"
        if delay >= 5 { text += ", with \(delay) min of delays" }
        return text + "."
    }

    public static func duration(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}
