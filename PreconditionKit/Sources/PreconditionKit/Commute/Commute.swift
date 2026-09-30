import Foundation

/// One way of driving a commute, e.g. "M1 and A14", from a Google Maps link.
public struct CommuteRoute: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The link as shared, opened to show the route in Google Maps.
    public var link: String
    /// Start, via points and end.
    public var points: [LatLon]

    public init(id: UUID = UUID(), name: String, link: String, points: [LatLon]) {
        self.id = id
        self.name = name
        self.link = link
        self.points = points
    }

    /// The shared link, or for a route with none (a way back made in the app), Google Maps directions
    /// through the same points.
    public var mapsURL: URL? {
        if !link.isEmpty { return URL(string: link) }
        guard let first = points.first, let last = points.last, points.count >= 2 else { return nil }
        var c = URLComponents(string: "https://www.google.com/maps/dir/")!
        var items = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "origin", value: "\(first.lat),\(first.lon)"),
            URLQueryItem(name: "destination", value: "\(last.lat),\(last.lon)"),
            URLQueryItem(name: "travelmode", value: "driving"),
        ]
        let via = points.dropFirst().dropLast()
        if !via.isEmpty { items.append(URLQueryItem(name: "waypoints", value: via.map { "\($0.lat),\($0.lon)" }.joined(separator: "|"))) }
        c.queryItems = items
        return c.url
    }
}

public enum MessageChannel: String, Codable, CaseIterable, Sendable {
    case messages, whatsapp

    public var title: String { self == .messages ? "Messages" : "WhatsApp" }
}

/// A regular drive, e.g. "Home" from work, with its routes in the order you'd rather take them.
public struct Commute: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Best first: the first one that isn't much slower than the quickest is the one to take.
    public var routes: [CommuteRoute]
    /// How many minutes slower than the quickest a route you prefer can be and still be picked.
    public var toleranceMinutes: Int
    /// The ETA message, with {eta}, {minutes} and {route} filled in.
    public var message: String
    /// Who gets it: a phone number, with country code for WhatsApp.
    public var recipient: String
    public var channel: MessageChannel
    /// Checking by itself: when you leave the start, and a reminder at a set time.
    public var auto: CommuteAuto

    public static let defaultMessage = "I'll be home at {eta}, see you soon x"

    public init(id: UUID = UUID(), name: String, routes: [CommuteRoute] = [], toleranceMinutes: Int = 10,
                message: String = Commute.defaultMessage, recipient: String = "", channel: MessageChannel = .messages,
                auto: CommuteAuto = CommuteAuto()) {
        self.id = id
        self.name = name
        self.routes = routes
        self.toleranceMinutes = toleranceMinutes
        self.message = message
        self.recipient = recipient
        self.channel = channel
        self.auto = auto
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Home"
        routes = try c.decodeIfPresent([CommuteRoute].self, forKey: .routes) ?? []
        toleranceMinutes = try c.decodeIfPresent(Int.self, forKey: .toleranceMinutes) ?? 10
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? Self.defaultMessage
        recipient = try c.decodeIfPresent(String.self, forKey: .recipient) ?? ""
        channel = try c.decodeIfPresent(MessageChannel.self, forKey: .channel) ?? .messages
        auto = try c.decodeIfPresent(CommuteAuto.self, forKey: .auto) ?? CommuteAuto()
    }

    /// Where the favourite route starts and ends.
    public var start: LatLon? { routes.first?.points.first }
    public var end: LatLon? { routes.first?.points.last }

    /// The same drive the other way: every route reversed, for the trip back.
    public func reversed(name: String, message: String) -> Commute {
        Commute(
            name: name,
            routes: routes.map { CommuteRoute(name: $0.name, link: "", points: $0.points.reversed()) },
            toleranceMinutes: toleranceMinutes, message: message, recipient: recipient, channel: channel
        )
    }

    /// The region watched for leaving the start.
    public static let regionPrefix = "commute:"
    public static let leaveRadiusM = 300.0

    public var leaveRegion: GeofenceSpec? {
        guard auto.whenLeaving, let start else { return nil }
        return GeofenceSpec(id: Self.regionPrefix + id.uuidString, centre: start, radiusM: Self.leaveRadiusM, enter: false, exit: true)
    }

    public static func id(fromRegion regionId: String) -> UUID? {
        guard regionId.hasPrefix(regionPrefix) else { return nil }
        return UUID(uuidString: String(regionId.dropFirst(regionPrefix.count)))
    }

    /// The message with the blanks filled in.
    public func messageText(eta: String, minutes: Int, route: String) -> String {
        message
            .replacingOccurrences(of: "{eta}", with: eta)
            .replacingOccurrences(of: "{minutes}", with: "\(minutes)")
            .replacingOccurrences(of: "{route}", with: route)
    }
}

/// How long a drive takes now, and normally.
public struct DriveTime: Equatable, Sendable {
    public var seconds: Double
    /// Without traffic, when the source says.
    public var typicalSeconds: Double?
    public var meters: Double?

    public init(seconds: Double, typicalSeconds: Double? = nil, meters: Double? = nil) {
        self.seconds = seconds
        self.typicalSeconds = typicalSeconds
        self.meters = meters
    }

    public var minutes: Int { Int((seconds / 60).rounded()) }
    /// Minutes lost to traffic.
    public var delayMinutes: Int? { typicalSeconds.map { max(0, Int(((seconds - $0) / 60).rounded())) } }
}

/// Times a drive through the given points, with current traffic.
public protocol DriveTimer: Sendable {
    func time(_ points: [LatLon]) async throws -> DriveTime
}

/// Google's Routes API: the same traffic Google Maps shows, through your via points.
public struct GoogleRoutesClient: DriveTimer {
    let transport: HTTPTransport
    let key: String

    public init(transport: HTTPTransport, key: String) {
        self.transport = transport
        self.key = key
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badKey, http(Int), noRoute
        public var description: String {
            switch self {
            case .badKey: return "Google didn't accept the key. Turn on the Routes API for it in Google Cloud."
            case .http(let code): return "Google answered \(code)."
            case .noRoute: return "Google couldn't find that route."
            }
        }
    }

    static func waypoint(_ p: LatLon, via: Bool = false) -> JSONValue {
        var w: [String: JSONValue] = ["location": ["latLng": ["latitude": .number(p.lat), "longitude": .number(p.lon)]]]
        if via { w["via"] = true }
        return .object(w)
    }

    static func body(_ points: [LatLon]) -> JSONValue {
        [
            "origin": waypoint(points[0]),
            "destination": waypoint(points[points.count - 1]),
            "intermediates": .array(points.dropFirst().dropLast().map { waypoint($0, via: true) }),
            "travelMode": "DRIVE",
            "routingPreference": "TRAFFIC_AWARE",
        ]
    }

    public func time(_ points: [LatLon]) async throws -> DriveTime {
        guard points.count >= 2 else { throw Failure.noRoute }
        let request = HTTPRequest(
            method: "POST",
            url: URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!,
            headers: [
                "Content-Type": "application/json",
                "X-Goog-Api-Key": key,
                "X-Goog-FieldMask": "routes.duration,routes.staticDuration,routes.distanceMeters",
            ],
            body: Self.body(points).data
        )
        let response = try await transport.send(request)
        if response.status == 401 || response.status == 403 { throw Failure.badKey }
        guard response.status == 200 else { throw Failure.http(response.status) }
        guard let route = JSONValue.parse(response.body)?["routes"]?.array?.first,
              let seconds = Self.seconds(route["duration"]?.str) else { throw Failure.noRoute }
        return DriveTime(seconds: seconds, typicalSeconds: Self.seconds(route["staticDuration"]?.str), meters: route["distanceMeters"]?.num)
    }

    /// "1834s" → 1834.
    static func seconds(_ text: String?) -> Double? {
        guard let text, text.hasSuffix("s") else { return nil }
        return Double(text.dropLast())
    }
}

/// One route's result.
public struct RouteCheck: Equatable, Identifiable, Sendable {
    public var route: CommuteRoute
    public var time: DriveTime?
    public var problem: String?
    public var id: UUID { route.id }

    public init(route: CommuteRoute, time: DriveTime? = nil, problem: String? = nil) {
        self.route = route
        self.time = time
        self.problem = problem
    }
}

public struct CommuteAdvice: Equatable, Sendable {
    public var checks: [RouteCheck]
    /// The route to take.
    public var pick: RouteCheck?
    public var arrival: Date?
    /// "M1 and A14 is clear: 42 min."
    public var headline: String
    public var checkedAt: Date
}

public enum CommuteAdvisor {
    /// Takes the first route you prefer that's within `toleranceMinutes` of the quickest.
    public static func advise(_ checks: [RouteCheck], toleranceMinutes: Int, now: Date) -> CommuteAdvice {
        let timed = checks.filter { $0.time != nil }
        guard let fastest = timed.map({ $0.time!.seconds }).min() else {
            let why = checks.compactMap(\.problem).first ?? "No routes to check."
            return CommuteAdvice(checks: checks, pick: nil, arrival: nil, headline: why, checkedAt: now)
        }
        let slack = Double(toleranceMinutes) * 60
        let pick = timed.first { $0.time!.seconds <= fastest + slack }!
        let time = pick.time!
        // Round the arrival up to the next minute.
        let arrival = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 + time.seconds) / 60).rounded(.up) * 60)

        let headline: String
        if let first = checks.first, first.id != pick.id {
            if let t = first.time {
                let slower = t.minutes - time.minutes
                headline = "\(first.route.name) is slow (\(t.minutes) min). \(pick.route.name) is \(slower) min quicker: \(time.minutes) min."
            } else {
                headline = "Couldn't check \(first.route.name). \(pick.route.name): \(time.minutes) min."
            }
        } else if let delay = time.delayMinutes, delay >= 5 {
            headline = "\(pick.route.name) is still the best way: \(time.minutes) min, with \(delay) min of traffic."
        } else {
            headline = "\(pick.route.name) is clear: \(time.minutes) min."
        }
        return CommuteAdvice(checks: checks, pick: pick, arrival: arrival, headline: headline, checkedAt: now)
    }

    /// Times every route at once.
    public static func check(_ commute: Commute, with timer: DriveTimer, now: Date) async -> CommuteAdvice {
        let results = await withTaskGroup(of: (Int, RouteCheck).self) { group in
            for (i, route) in commute.routes.enumerated() {
                group.addTask {
                    do {
                        return (i, RouteCheck(route: route, time: try await timer.time(route.points)))
                    } catch {
                        return (i, RouteCheck(route: route, problem: (error as? LocalizedError)?.errorDescription ?? String(describing: error)))
                    }
                }
            }
            var out: [(Int, RouteCheck)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return advise(results, toleranceMinutes: commute.toleranceMinutes, now: now)
    }
}

/// Commutes to add from a link: `ev6://commutes?d=<base64url JSON>`, where the JSON is
/// `[{"name":"Home","routes":[{"name":"M1","link":"https://maps.app.goo.gl/…"}]}]`.
/// Only names and links travel in it; the app reads each link to place the route.
public struct CommuteImport: Codable, Equatable, Sendable {
    public struct Route: Codable, Equatable, Sendable {
        public var name: String
        public var link: String
        public init(name: String, link: String) {
            self.name = name
            self.link = link
        }
    }

    public var name: String
    public var routes: [Route]

    public init(name: String, routes: [Route]) {
        self.name = name
        self.routes = routes
    }

    public static func parse(_ url: URL) -> [CommuteImport]? {
        guard url.scheme == "ev6", url.host == "commutes",
              let d = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "d" })?.value
        else { return nil }
        var b64 = d.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let list = try? JSONDecoder().decode([CommuteImport].self, from: data), !list.isEmpty else { return nil }
        return list
    }

    public static func link(_ list: [CommuteImport]) -> URL? {
        guard let data = try? JSONEncoder().encode(list) else { return nil }
        let d = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "ev6://commutes?d=\(d)")
    }
}

/// A commute checking itself: when you drive away from its start, and a reminder at a set time.
public struct CommuteAuto: Codable, Equatable, Sendable {
    public var whenLeaving: Bool
    /// Nil: no reminder.
    public var remindAt: ClockTime?
    public var days: Set<Weekday>

    public init(whenLeaving: Bool = false, remindAt: ClockTime? = nil, days: Set<Weekday> = Weekday.weekdays) {
        self.whenLeaving = whenLeaving
        self.remindAt = remindAt
        self.days = days
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whenLeaving = try c.decodeIfPresent(Bool.self, forKey: .whenLeaving) ?? false
        remindAt = try c.decodeIfPresent(ClockTime.self, forKey: .remindAt)
        days = try c.decodeIfPresent(Set<Weekday>.self, forKey: .days) ?? Weekday.weekdays
    }
}

public extension Array where Element == Commute {
    /// The commute that starts where you are: the nearest start within `withinM`. A commute ends
    /// where another starts (home to work, work to home), so where you are says which way you're going.
    func starting(near position: LatLon, withinM: Double = 2500) -> Commute? {
        compactMap { c in c.start.map { (c, $0.distance(to: position)) } }
            .filter { $0.1 <= withinM }
            .min { $0.1 < $1.1 }?.0
    }
}
