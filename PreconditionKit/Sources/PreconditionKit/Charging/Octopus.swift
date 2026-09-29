import Foundation

/// Octopus Energy's public API (no account needed): the region for a postcode and Agile prices.
public struct OctopusClient: Sendable {
    public static let base = "https://api.octopus.energy/v1"
    let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownPostcode
        case noAgileProduct
        case http(Int)
        case unreadable

        public var description: String {
            switch self {
            case .unknownPostcode: return "Octopus doesn't recognise that postcode."
            case .noAgileProduct: return "Octopus isn't listing an Agile tariff right now."
            case .http(let code): return "Octopus answered \(code)."
            case .unreadable: return "Octopus sent something unexpected."
            }
        }
    }

    /// The DNO region letter (A–P) for a UK postcode.
    public func region(postcode: String) async throws -> String {
        let code = postcode.uppercased().filter { $0.isLetter || $0.isNumber }
        let json = try await get("/industry/grid-supply-points/", ["postcode": code])
        guard let results = json["results"] as? [[String: Any]],
              let group = results.first?["group_id"] as? String, group.count == 2 else { throw Failure.unknownPostcode }
        return String(group.dropFirst())
    }

    /// The newest Agile import product, e.g. "AGILE-24-10-01".
    public func agileProduct() async throws -> String {
        let json = try await get("/products/", ["brand": "OCTOPUS_ENERGY", "is_variable": "true", "page_size": "100"])
        let results = json["results"] as? [[String: Any]] ?? []
        let codes = results.compactMap { r -> String? in
            guard let code = r["code"] as? String, code.hasPrefix("AGILE-"),
                  (r["direction"] as? String ?? "IMPORT") == "IMPORT" else { return nil }
            return code
        }
        // Dated codes ("AGILE-24-10-01") sort by date; older variants ("AGILE-FLEX-…") only as a fallback.
        let dated = codes.filter { $0.range(of: #"^AGILE-\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
        guard let newest = dated.max() ?? codes.max() else { throw Failure.noAgileProduct }
        return newest
    }

    /// Half-hour prices between `from` and `to`, oldest first.
    public func agileRates(product: String, region: String, from: Date, to: Date) async throws -> [PriceSlot] {
        let tariff = "E-1R-\(product)-\(region)"
        let iso = ISO8601DateFormatter()
        let json = try await get("/products/\(product)/electricity-tariffs/\(tariff)/standard-unit-rates/", [
            "period_from": iso.string(from: from), "period_to": iso.string(from: to), "page_size": "1500",
        ])
        guard let results = json["results"] as? [[String: Any]] else { throw Failure.unreadable }
        return results.compactMap { r -> PriceSlot? in
            guard let price = (r["value_inc_vat"] as? NSNumber)?.doubleValue,
                  let fromText = r["valid_from"] as? String, let start = Self.date(fromText) else { return nil }
            let end = (r["valid_to"] as? String).flatMap(Self.date) ?? start.addingTimeInterval(1800)
            return PriceSlot(start: start, end: end, pencePerKWh: price)
        }
        .sorted { $0.start < $1.start }
    }

    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        var comps = URLComponents(string: Self.base + path)!
        comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let response = try await transport.send(HTTPRequest(method: "GET", url: comps.url!, headers: ["Accept": "application/json"]))
        if response.status == 404 { throw Failure.unknownPostcode }
        guard response.status == 200 else { throw Failure.http(response.status) }
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { throw Failure.unreadable }
        return json
    }
}
