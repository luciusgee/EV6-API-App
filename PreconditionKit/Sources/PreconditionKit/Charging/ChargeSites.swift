import Foundation

/// A charging site with what's there, from Open Charge Map, plus live data from Google when available.
public struct ChargeSite: Codable, Equatable, Identifiable, Sendable {
    public struct Connectors: Codable, Equatable, Sendable {
        /// "CCS (Type 2)", "CHAdeMO", "Type 2 (Socket Only)"…
        public var type: String
        public var kW: Double?
        public var count: Int
        public var operational: Bool?
        /// DC rapid (CCS/CHAdeMO/Tesla), the kind a road trip needs.
        public var dc: Bool
    }

    public struct Comment: Codable, Equatable, Sendable {
        public var text: String?
        /// 1–5.
        public var rating: Int?
        public var user: String?
        public var date: Date?
        /// "Charged Successfully", "Failed to Charge"…
        public var checkin: String?
        public var positive: Bool?
    }

    public var id: String
    public var name: String
    public var operatorName: String?
    public var address: String?
    public var position: LatLon
    public var connectors: [Connectors]
    public var points: Int?
    public var cost: String?
    public var access: String?
    /// "Operational", "Partly Operational", "Not Operational"…
    public var status: String?
    public var operational: Bool?
    public var statusUpdated: Date?
    public var verified: Date?
    public var comments: [Comment]

    /// The fastest charge an EV6 can get here (DC connectors), else anything.
    public var maxKW: Double? {
        connectors.filter(\.dc).compactMap(\.kW).max() ?? connectors.compactMap(\.kW).max()
    }

    public var rapidCount: Int { connectors.filter(\.dc).map(\.count).reduce(0, +) }

    /// Average of the comment ratings.
    public var rating: Double? {
        let r = comments.compactMap(\.rating)
        return r.isEmpty ? nil : Double(r.reduce(0, +)) / Double(r.count)
    }
}

/// Open Charge Map (openchargemap.org): open data on UK and worldwide chargers. Needs a free API key.
public struct OpenChargeMapClient: Sendable {
    public static let base = "https://api.openchargemap.io/v3/poi/"
    let transport: HTTPTransport
    let key: String

    public init(transport: HTTPTransport, key: String) {
        self.transport = transport
        self.key = key
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badKey, http(Int), unreadable
        public var description: String {
            switch self {
            case .badKey: return "Open Charge Map didn't accept the API key."
            case .http(let code): return "Open Charge Map answered \(code)."
            case .unreadable: return "Open Charge Map sent something unexpected."
            }
        }
    }

    /// Chargers within `radiusKm` of a route (given as its points, simplified here).
    public func along(_ route: [LatLon], radiusKm: Double = 3, minKW: Double = 40, max: Int = 250) async throws -> [ChargeSite] {
        let line = Polyline.encode(Polyline.simplify(route, maxPoints: 150))
        return try await get([
            "polyline": line, "distance": String(radiusKm), "distanceunit": "KM",
            "minpowerkw": String(Int(minKW)), "maxresults": String(max),
        ])
    }

    public func near(_ point: LatLon, radiusKm: Double = 8, minKW: Double? = nil, max: Int = 60) async throws -> [ChargeSite] {
        var q = [
            "latitude": String(point.lat), "longitude": String(point.lon),
            "distance": String(radiusKm), "distanceunit": "KM", "maxresults": String(max),
        ]
        if let minKW { q["minpowerkw"] = String(Int(minKW)) }
        return try await get(q)
    }

    private func get(_ query: [String: String]) async throws -> [ChargeSite] {
        var comps = URLComponents(string: Self.base)!
        let base = ["output": "json", "compact": "false", "verbose": "false", "includecomments": "true", "key": key]
        comps.queryItems = base.merging(query) { _, new in new }.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let response = try await transport.send(HTTPRequest(method: "GET", url: comps.url!, headers: ["Accept": "application/json", "User-Agent": "EV6-iPhone-app"]))
        if response.status == 401 || response.status == 403 { throw Failure.badKey }
        guard response.status == 200 else { throw Failure.http(response.status) }
        guard let json = JSONValue.parse(response.body), let list = json.array else { throw Failure.unreadable }
        return list.compactMap(Self.site)
    }

    static func site(_ j: JSONValue) -> ChargeSite? {
        guard let id = j["ID"]?.num, let a = j["AddressInfo"],
              let lat = a["Latitude"]?.num, let lon = a["Longitude"]?.num else { return nil }
        let address = [a["AddressLine1"]?.str, a["Town"]?.str, a["Postcode"]?.str]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        let connectors: [ChargeSite.Connectors] = (j["Connections"]?.array ?? []).map { c in
            let type = c["ConnectionType"]?["Title"]?.str ?? "Unknown"
            let typeId = Int(c["ConnectionTypeID"]?.num ?? 0)
            // CCS (33), CHAdeMO (2), Tesla Supercharger (27, 30), or DC current.
            let dc = [2, 27, 30, 33].contains(typeId) || c["CurrentTypeID"]?.num == 30 || (c["LevelID"]?.num ?? 0) >= 3
            return ChargeSite.Connectors(
                type: type, kW: c["PowerKW"]?.num, count: Int(c["Quantity"]?.num ?? 1),
                operational: c["StatusType"]?["IsOperational"]?.bool, dc: dc
            )
        }
        let comments: [ChargeSite.Comment] = (j["UserComments"]?.array ?? []).map { c in
            ChargeSite.Comment(
                text: c["Comment"]?.str, rating: c["Rating"]?.num.map { Int($0) }, user: c["UserName"]?.str,
                date: c["DateCreated"]?.str.flatMap(Self.date), checkin: c["CheckinStatusType"]?["Title"]?.str,
                positive: c["CheckinStatusType"]?["IsPositive"]?.bool
            )
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return ChargeSite(
            id: "ocm-\(Int(id))",
            name: a["Title"]?.str ?? "Charger",
            operatorName: j["OperatorInfo"]?["Title"]?.str.flatMap { $0.hasPrefix("(Unknown") ? nil : $0 },
            address: address.isEmpty ? nil : address,
            position: LatLon(lat: lat, lon: lon),
            connectors: connectors,
            points: j["NumberOfPoints"]?.num.map { Int($0) },
            cost: j["UsageCost"]?.str,
            access: j["UsageType"]?["Title"]?.str,
            status: j["StatusType"]?["Title"]?.str,
            operational: j["StatusType"]?["IsOperational"]?.bool,
            statusUpdated: j["DateLastStatusUpdate"]?.str.flatMap(Self.date),
            verified: j["DateLastVerified"]?.str.flatMap(Self.date),
            comments: comments
        )
    }

    static func date(_ s: String) -> Date? { OctopusClient.date(s) }
}

/// Live data and reviews for a charger, from Google Places. Needs the owner's Google API key.
public struct PlaceInsight: Codable, Equatable, Sendable {
    public struct Availability: Codable, Equatable, Sendable {
        public var type: String
        public var kW: Double?
        public var count: Int
        public var available: Int?
        public var outOfService: Int?
        public var updated: Date?
    }

    public struct Review: Codable, Equatable, Sendable {
        public var rating: Int?
        public var text: String?
        public var author: String?
        /// "2 weeks ago".
        public var when: String?
    }

    public var name: String?
    public var rating: Double?
    public var ratingCount: Int?
    public var availability: [Availability]
    public var reviews: [Review]
    public var mapsURL: URL?
}

public struct GooglePlacesClient: Sendable {
    let transport: HTTPTransport
    let key: String

    public init(transport: HTTPTransport, key: String) {
        self.transport = transport
        self.key = key
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badKey, http(Int), notFound
        public var description: String {
            switch self {
            case .badKey: return "Google didn't accept the API key (Places API (New) must be enabled)."
            case .http(let code): return "Google answered \(code)."
            case .notFound: return "Google doesn't list a charger here."
            }
        }
    }

    /// The charging station at (or nearest) `point`.
    public func insight(near point: LatLon, radiusM: Double = 150) async throws -> PlaceInsight {
        let body: JSONValue = [
            "includedTypes": ["electric_vehicle_charging_station"],
            "maxResultCount": 3,
            "locationRestriction": ["circle": ["center": ["latitude": .number(point.lat), "longitude": .number(point.lon)], "radius": .number(radiusM)]],
        ]
        let request = HTTPRequest(
            method: "POST",
            url: URL(string: "https://places.googleapis.com/v1/places:searchNearby")!,
            headers: [
                "Content-Type": "application/json",
                "X-Goog-Api-Key": key,
                "X-Goog-FieldMask": "places.displayName,places.location,places.rating,places.userRatingCount,places.reviews,places.evChargeOptions,places.googleMapsUri",
            ],
            body: body.data
        )
        let response = try await transport.send(request)
        if response.status == 400 || response.status == 401 || response.status == 403 { throw Failure.badKey }
        guard response.status == 200 else { throw Failure.http(response.status) }
        guard let places = JSONValue.parse(response.body)?["places"]?.array, !places.isEmpty else { throw Failure.notFound }
        // The nearest one listed.
        let best = places.min { a, b in
            Self.distance(a, point) < Self.distance(b, point)
        }!
        return Self.insight(best)
    }

    static func distance(_ place: JSONValue, _ p: LatLon) -> Double {
        guard let lat = place["location"]?["latitude"]?.num, let lon = place["location"]?["longitude"]?.num else { return .infinity }
        return LatLon(lat: lat, lon: lon).distance(to: p)
    }

    static func insight(_ p: JSONValue) -> PlaceInsight {
        let availability: [PlaceInsight.Availability] = (p["evChargeOptions"]?["connectorAggregation"]?.array ?? []).map { a in
            PlaceInsight.Availability(
                type: connectorName(a["type"]?.str),
                kW: a["maxChargeRateKw"]?.num,
                count: Int(a["count"]?.num ?? 0),
                available: a["availableCount"]?.num.map { Int($0) },
                outOfService: a["outOfServiceCount"]?.num.map { Int($0) },
                updated: a["availabilityLastUpdateTime"]?.str.flatMap(OctopusClient.date)
            )
        }
        let reviews: [PlaceInsight.Review] = (p["reviews"]?.array ?? []).map { r in
            PlaceInsight.Review(
                rating: r["rating"]?.num.map { Int($0) },
                text: r["text"]?["text"]?.str ?? r["originalText"]?["text"]?.str,
                author: r["authorAttribution"]?["displayName"]?.str,
                when: r["relativePublishTimeDescription"]?.str
            )
        }
        return PlaceInsight(
            name: p["displayName"]?["text"]?.str,
            rating: p["rating"]?.num,
            ratingCount: p["userRatingCount"]?.num.map { Int($0) },
            availability: availability,
            reviews: reviews,
            mapsURL: p["googleMapsUri"]?.str.flatMap(URL.init(string:))
        )
    }

    static func connectorName(_ raw: String?) -> String {
        switch raw {
        case "EV_CONNECTOR_TYPE_CCS_COMBO_2": return "CCS"
        case "EV_CONNECTOR_TYPE_CCS_COMBO_1": return "CCS1"
        case "EV_CONNECTOR_TYPE_CHADEMO": return "CHAdeMO"
        case "EV_CONNECTOR_TYPE_TYPE_2": return "Type 2"
        case "EV_CONNECTOR_TYPE_TESLA": return "Tesla"
        case "EV_CONNECTOR_TYPE_J1772": return "Type 1"
        case "EV_CONNECTOR_TYPE_UNSPECIFIED_WALL_OUTLET": return "Wall socket"
        default: return raw.map { $0.replacingOccurrences(of: "EV_CONNECTOR_TYPE_", with: "").capitalized } ?? "Other"
        }
    }
}

/// Google's encoded polyline format, for Open Charge Map's route search.
public enum Polyline {
    public static func encode(_ points: [LatLon]) -> String {
        var out = ""
        var lastLat = 0, lastLon = 0
        for p in points {
            let lat = Int((p.lat * 1e5).rounded()), lon = Int((p.lon * 1e5).rounded())
            out += value(lat - lastLat) + value(lon - lastLon)
            lastLat = lat
            lastLon = lon
        }
        return out
    }

    private static func value(_ v: Int) -> String {
        var n = v < 0 ? ~(v << 1) : v << 1
        var s = ""
        while n >= 0x20 {
            s.append(Character(UnicodeScalar(UInt8((0x20 | (n & 0x1f)) + 63))))
            n >>= 5
        }
        s.append(Character(UnicodeScalar(UInt8(n + 63))))
        return s
    }

    /// Every n-th point, keeping the ends, so the URL stays short.
    public static func simplify(_ points: [LatLon], maxPoints: Int) -> [LatLon] {
        guard points.count > maxPoints, maxPoints >= 2 else { return points }
        let step = Double(points.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { points[Int((Double($0) * step).rounded())] }
    }
}
