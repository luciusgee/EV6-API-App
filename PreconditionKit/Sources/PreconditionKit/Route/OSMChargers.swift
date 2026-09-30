import Foundation

/// How many charge points a site has and how fast they are, from OpenStreetMap (free, no key).
/// Apple Maps only gives a charger's name and place.
public struct ChargerDetails: Equatable, Sendable {
    /// Charge points (cars that can charge at once), when mapped.
    public var count: Int?
    /// CCS (the EV6's rapid plug) points, when mapped.
    public var rapidCount: Int?
    /// The fastest CCS point, else the fastest of any kind.
    public var maxKW: Double?
    public var operatorName: String?

    public init(count: Int? = nil, rapidCount: Int? = nil, maxKW: Double? = nil, operatorName: String? = nil) {
        self.count = count
        self.rapidCount = rapidCount
        self.maxKW = maxKW
        self.operatorName = operatorName
    }

    /// "6 chargers · 150 kW", "4 rapid of 8 · 50 kW".
    public var summary: String? {
        var parts: [String] = []
        if let count {
            if let rapidCount, rapidCount > 0, rapidCount < count {
                parts.append("\(rapidCount) rapid of \(count)")
            } else {
                parts.append("\(count) charger\(count == 1 ? "" : "s")")
            }
        } else if let rapidCount, rapidCount > 0 {
            parts.append("\(rapidCount) rapid")
        }
        if let maxKW { parts.append("\(Int(maxKW.rounded())) kW") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public struct OSMChargersClient: Sendable {
    public static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    public enum Failure: Error, Equatable {
        case http(Int)
        case unreadable
    }

    /// Details for each point (by id): the nearest mapped charging site within `radiusM`.
    public func details(for points: [(id: String, position: LatLon)], radiusM: Double = 150) async throws -> [String: ChargerDetails] {
        guard !points.isEmpty else { return [:] }
        let query = Self.query(points.map(\.position), radiusM: radiusM)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        let request = HTTPRequest(method: "POST", url: Self.endpoint, headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "MyEV6 (personal iPhone app)",
        ], body: Data(body.utf8))
        let response = try await transport.send(request)
        guard response.status == 200 else { throw Failure.http(response.status) }
        return Self.match(points, sites: try Self.parse(response.body), radiusM: radiusM)
    }

    static func query(_ positions: [LatLon], radiusM: Double) -> String {
        let parts = positions.map { p in
            String(format: "nwr[\"amenity\"=\"charging_station\"](around:%.0f,%.6f,%.6f);", radiusM, p.lat, p.lon)
        }
        return "[out:json][timeout:20];(" + parts.joined() + ");out center tags;"
    }

    static func parse(_ data: Data) throws -> [(position: LatLon, details: ChargerDetails)] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { throw Failure.unreadable }
        return elements.compactMap { e in
            let centre = e["center"] as? [String: Any]
            guard let lat = (e["lat"] ?? centre?["lat"]) as? Double, let lon = (e["lon"] ?? centre?["lon"]) as? Double,
                  let tags = e["tags"] as? [String: String] else { return nil }
            return (LatLon(lat: lat, lon: lon), details(tags))
        }
    }

    static func details(_ tags: [String: String]) -> ChargerDetails {
        func int(_ key: String) -> Int? { tags[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        let sockets = tags.filter { $0.key.hasPrefix("socket:") && !$0.key.dropFirst(7).contains(":") }
        let socketCounts = sockets.compactMap { Int($0.value) }
        let rapid = int("socket:type2_combo")
        let count = int("capacity") ?? (socketCounts.isEmpty ? nil : max(socketCounts.max() ?? 0, rapid ?? 0))
        let ccsKW = kW(tags["socket:type2_combo:output"])
        let anyKW = tags.filter { $0.key.hasSuffix(":output") || $0.key == "maxpower" }.compactMap { kW($0.value) }.max()
        return ChargerDetails(count: count, rapidCount: rapid, maxKW: ccsKW ?? anyKW, operatorName: tags["operator"] ?? tags["brand"])
    }

    /// "150 kW", "50kW", "350 kW;150 kW", "22000 W" → the largest, in kW.
    static func kW(_ text: String?) -> Double? {
        guard let text else { return nil }
        return text.split(separator: ";").compactMap { part -> Double? in
            let s = part.lowercased().replacingOccurrences(of: " ", with: "")
            if s.hasSuffix("kw"), let v = Double(s.dropLast(2)) { return v }
            if s.hasSuffix("w"), let v = Double(s.dropLast(1)) { return v / 1000 }
            return Double(s)
        }.max()
    }

    static func match(_ points: [(id: String, position: LatLon)], sites: [(position: LatLon, details: ChargerDetails)], radiusM: Double) -> [String: ChargerDetails] {
        var out: [String: ChargerDetails] = [:]
        for p in points {
            let nearest = sites.map { ($0.details, $0.position.distance(to: p.position)) }
                .filter { $0.1 <= radiusM }
                .min { $0.1 < $1.1 }
            if let nearest { out[p.id] = nearest.0 }
        }
        return out
    }
}
