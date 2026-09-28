import Foundation

/// A coordinate. JSON: `{"lat":50.087,"lon":14.421}`.
public struct LatLon: Codable, Hashable, Sendable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    /// Great-circle (haversine) distance in metres.
    public func distance(to other: LatLon) -> Double {
        let r = 6_371_000.0
        let dLat = (other.lat - lat) * .pi / 180
        let dLon = (other.lon - lon) * .pi / 180
        let sinLat = sin(dLat / 2)
        let sinLon = sin(dLon / 2)
        let a = sinLat * sinLat + cos(lat * .pi / 180) * cos(other.lat * .pi / 180) * sinLon * sinLon
        return 2 * r * asin(sqrt(min(max(a, 0), 1)))
    }
}

/// A named circle: home, the office. JSON matches the Android backups (HANDOVER.md §4.1).
public struct Place: Codable, Identifiable, Hashable, Sendable {
    public static let minRadiusM = 100
    public static let maxRadiusM = 2000

    public var id: String
    public var name: String
    public var centre: LatLon
    public var radiusM: Int
    /// Where the car is usually parked for this place; used for weather when the car's position is unknown.
    public var usualParkingSpot: LatLon?

    public init(id: String, name: String, centre: LatLon, radiusM: Int, usualParkingSpot: LatLon? = nil) {
        self.id = id
        self.name = name
        self.centre = centre
        self.radiusM = radiusM
        self.usualParkingSpot = usualParkingSpot
    }

    public func contains(_ point: LatLon) -> Bool {
        centre.distance(to: point) <= Double(radiusM)
    }

    /// Best guess at where the car is when it is "at" this place.
    public var parkingSpotOrCentre: LatLon { usualParkingSpot ?? centre }

    private enum CodingKeys: String, CodingKey { case id, name, centre, radiusM, usualParkingSpot }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(centre, forKey: .centre)
        try c.encode(radiusM, forKey: .radiusM)
        // Android writes an explicit null; keep the files identical.
        try c.encode(usualParkingSpot, forKey: .usualParkingSpot)
    }
}
