import Foundation

/// Reads the start, the points you dragged the route through, and the end out of a Google Maps
/// directions link, so the app can time exactly that route.
///
/// A shared link (maps.app.goo.gl/…) has to be expanded first; the app follows its redirect.
/// Long links look like
/// `https://www.google.com/maps/dir/52.04,-0.77/Home/@52.1,-0.6,11z/data=!4m19!4m18!1m10!…!3e0`.
/// In `data`, the directions block (`4m`) holds one `1m` per stop, in order. A stop carries its own
/// coordinate (`2m2!1d<lon>!2d<lat>`) unless it was typed as coordinates in the path, and each point
/// you dragged the route through after it (`3m4!1m2!1d<lon>!2d<lat>!3s…`).
public enum GoogleMapsLink {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notDirections
        case missingPlace(String)
        public var description: String {
            switch self {
            case .notDirections: return "That isn't a Google Maps directions link."
            case .missingPlace(let name): return "The link doesn't say where \"\(name)\" is. Share it from Google Maps again, or start and end at a dropped pin."
            }
        }
    }

    /// Is this a short link that needs expanding before it can be read?
    public static func isShort(_ link: String) -> Bool {
        guard let host = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return host == "maps.app.goo.gl" || host == "goo.gl"
    }

    /// Start, via points and end, in driving order.
    public static func points(from link: String) throws -> [LatLon] {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Failure.notDirections
        }
        // Google's consent page wraps the real link.
        if components.host?.contains("consent.") == true,
           let inner = components.queryItems?.first(where: { $0.name == "continue" })?.value {
            return try points(from: inner)
        }
        // The documented form: /maps/dir/?api=1&origin=…&destination=…&waypoints=a|b
        if let items = components.queryItems, items.contains(where: { $0.name == "api" }) {
            let value = { (name: String) in items.first { $0.name == name }?.value }
            guard let o = value("origin").flatMap(coordinate), let d = value("destination").flatMap(coordinate) else {
                throw Failure.notDirections
            }
            let vias = (value("waypoints") ?? "").split(separator: "|").compactMap { coordinate(String($0)) }
            return [o] + vias + [d]
        }

        // What shared links from the Google Maps app expand to:
        // maps.google.com/?saddr=<start>&daddr=<via>+to:<end>&geocode=<start>;<via>;<end>
        if let items = components.queryItems, let daddr = items.first(where: { $0.name == "daddr" })?.value {
            let value = { (name: String) in items.first { $0.name == name }?.value }
            let stops = ([value("saddr") ?? ""] + daddr.replacingOccurrences(of: "+", with: " ").components(separatedBy: " to:"))
                .map { $0.replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespaces) }
            let geocodes = (value("geocode") ?? "").split(separator: ";", omittingEmptySubsequences: false).map { geocodePoint(String($0)) }
            guard stops.count >= 2 else { throw Failure.notDirections }
            return try stops.enumerated().map { i, text in
                if let c = coordinate(text) { return c }
                if i < geocodes.count, let c = geocodes[i] { return c }
                throw Failure.missingPlace(text.isEmpty ? "your location" : text)
            }
        }

        let path = components.percentEncodedPath
        guard let dir = path.range(of: "/dir/") else { throw Failure.notDirections }
        var stops: [String] = []
        var data = ""
        for raw in path[dir.upperBound...].split(separator: "/") {
            let segment = String(raw)
            if segment.hasPrefix("data=") {
                data = String(segment.dropFirst(5))
                break
            }
            if segment.hasPrefix("@") || segment.hasPrefix("am=") { continue }
            let decoded = (segment.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? segment)
            stops.append(decoded)
        }
        let literal = stops.map(coordinate)
        let waypoints = directionStops(data)

        guard !waypoints.isEmpty else {
            // No data block: every stop must be written as coordinates.
            guard stops.count >= 2 else { throw Failure.notDirections }
            return try zip(stops, literal).map { name, c in
                guard let c else { throw Failure.missingPlace(name) }
                return c
            }
        }
        var out: [LatLon] = []
        for (i, stop) in waypoints.enumerated() {
            guard let c = stop.position ?? (i < literal.count ? literal[i] : nil) else {
                throw Failure.missingPlace(i < stops.count ? stops[i] : "stop \(i + 1)")
            }
            out.append(c)
            out.append(contentsOf: stop.vias)
        }
        guard out.count >= 2 else { throw Failure.notDirections }
        // Points dragged after the last stop would be meaningless.
        return out
    }

    /// One `geocode` entry: base64url protobuf with the latitude and longitude as fixed32 fields 2 and 3,
    /// in millionths of a degree.
    static func geocodePoint(_ token: String) -> LatLon? {
        var b64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        let bytes = [UInt8](data)
        var i = 0
        var lat: Int32?, lon: Int32?
        func fixed32(_ at: Int) -> Int32 {
            Int32(bitPattern: UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
        }
        while i < bytes.count {
            let tag = bytes[i]
            i += 1
            switch tag & 7 {
            case 5:
                guard i + 4 <= bytes.count else { return nil }
                if tag >> 3 == 2 { lat = fixed32(i) } else if tag >> 3 == 3 { lon = fixed32(i) }
                i += 4
            case 1:
                i += 8
            case 0:
                while i < bytes.count, bytes[i] & 0x80 != 0 { i += 1 }
                i += 1
            case 2:
                guard i < bytes.count else { return nil }
                i += 1 + Int(bytes[i])
            default:
                return nil
            }
        }
        guard let lat, let lon else { return nil }
        let p = LatLon(lat: Double(lat) / 1e6, lon: Double(lon) / 1e6)
        return abs(p.lat) <= 90 && abs(p.lon) <= 180 ? p : nil
    }

    /// "52.04,-0.77" (or with a space) as a coordinate.
    static func coordinate(_ text: String) -> LatLon? {
        let parts = text.replacingOccurrences(of: " ", with: "").split(separator: ",")
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return LatLon(lat: lat, lon: lon)
    }

    struct Stop: Equatable {
        var position: LatLon?
        var vias: [LatLon]
    }

    /// The stops in the data block's directions message.
    static func directionStops(_ data: String) -> [Stop] {
        let nodes = Node.parse(data)
        guard let directions = Node.first(in: nodes, where: { n in
            n.type == "m" && n.children.filter { $0.field == 1 && $0.type == "m" }.count >= 2
        }) else { return [] }
        return directions.children.filter { $0.field == 1 && $0.type == "m" }.map { stop in
            let position = stop.children.first { $0.field == 2 && $0.type == "m" }.flatMap(\.point)
            let vias = stop.children.filter { $0.field == 3 && $0.type == "m" }.compactMap { via in
                via.children.first { $0.field == 1 && $0.type == "m" }?.point
            }
            return Stop(position: position, vias: vias)
        }
    }

    /// Google's `!<field><type><value>` encoding: an `m` holds the next <value> tokens.
    struct Node: Equatable {
        var field: Int
        var type: Character
        var value: String
        var children: [Node] = []

        /// `1d<lon>` and `2d<lat>` among the children.
        var point: LatLon? {
            guard let lon = children.first(where: { $0.field == 1 && $0.type == "d" }).flatMap({ Double($0.value) }),
                  let lat = children.first(where: { $0.field == 2 && $0.type == "d" }).flatMap({ Double($0.value) })
            else { return nil }
            return LatLon(lat: lat, lon: lon)
        }

        static func parse(_ data: String) -> [Node] {
            let tokens: [Node] = data.split(separator: "!").compactMap { raw in
                let digits = raw.prefix { $0.isNumber }
                guard let field = Int(digits), raw.count > digits.count else { return nil }
                let type = raw[raw.index(raw.startIndex, offsetBy: digits.count)]
                let value = String(raw.dropFirst(digits.count + 1))
                return Node(field: field, type: type, value: value)
            }
            var i = 0
            var out: [Node] = []
            while i < tokens.count { out.append(take(tokens, &i)) }
            return out
        }

        private static func take(_ tokens: [Node], _ i: inout Int) -> Node {
            var node = tokens[i]
            i += 1
            guard node.type == "m", let count = Int(node.value) else { return node }
            let end = min(i + count, tokens.count)
            while i < end { node.children.append(take(tokens, &i)) }
            return node
        }

        static func first(in nodes: [Node], where match: (Node) -> Bool) -> Node? {
            for n in nodes {
                if match(n) { return n }
                if let found = first(in: n.children, where: match) { return found }
            }
            return nil
        }
    }
}
