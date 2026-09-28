import Foundation

/// The backup file: `{"version":1,"places":[…],"rules":[…]}`. Never contains credentials or the VIN.
public struct RuleBundle: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var places: [Place]
    public var rules: [Rule]

    public init(version: Int = RuleBundle.currentVersion, places: [Place] = [], rules: [Rule] = []) {
        self.version = version
        self.places = places
        self.rules = rules
    }
}

public struct ImportIssue: Equatable, Sendable, CustomStringConvertible {
    public var section: String
    /// 0-based; shown 1-based.
    public var index: Int
    public var name: String?
    public var message: String

    /// `rule #3 "Leaving work": …`
    public var description: String {
        "\(section) #\(index + 1)\(name.map { " \"\($0)\"" } ?? ""): \(message)"
    }
}

public struct ImportResult: Equatable, Sendable {
    public var places: [Place]
    public var rules: [Rule]
    public var issues: [ImportIssue]
    public var ok: Bool { issues.isEmpty }
}

/// Export and import of rules and places, compatible with the Android app's backups (HANDOVER.md §4.1).
public enum RuleJSON {
    public static func export(places: [Place], rules: [Rule]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(RuleBundle(places: places, rules: rules))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes and validates each place and rule separately, so one bad entry doesn't hide the rest.
    /// - Parameter existingPlaceIds: places already on the phone; rules may refer to them too.
    public static func `import`(_ text: String, existingPlaceIds: Set<String> = []) -> ImportResult {
        guard let root = JSONValue.parse(text), root.isObject else {
            return ImportResult(places: [], rules: [], issues: [ImportIssue(section: "file", index: 0, name: nil, message: "not a JSON object")])
        }
        var issues: [ImportIssue] = []

        let version = root["version"]?.int ?? RuleBundle.currentVersion
        if version > RuleBundle.currentVersion {
            issues.append(ImportIssue(section: "file", index: 0, name: nil, message: "version \(version) is newer than this app supports"))
            return ImportResult(places: [], rules: [], issues: issues)
        }

        var places: [Place] = []
        for (i, place) in decodeEach(Place.self, root["places"], section: "place", issues: &issues) {
            let problems = RuleValidator.validatePlace(place)
            problems.forEach { issues.append(ImportIssue(section: "place", index: i, name: place.name, message: $0)) }
            if problems.isEmpty { places.append(place) }
        }

        let placeIds = existingPlaceIds.union(places.map(\.id))
        var seen = Set<String>()
        var rules: [Rule] = []
        for (i, rule) in decodeEach(Rule.self, root["rules"], section: "rule", issues: &issues) {
            var problems = RuleValidator.validate(rule, placeIds: placeIds)
            if !seen.insert(rule.id).inserted { problems.append("duplicate id '\(rule.id)'") }
            problems.forEach { issues.append(ImportIssue(section: "rule", index: i, name: rule.name, message: $0)) }
            if problems.isEmpty { rules.append(rule) }
        }

        return ImportResult(places: places, rules: rules, issues: issues)
    }

    private static func decodeEach<T: Decodable>(_ type: T.Type, _ element: JSONValue?, section: String, issues: inout [ImportIssue]) -> [(Int, T)] {
        guard let element else { return [] }
        guard let array = element.array else {
            issues.append(ImportIssue(section: section, index: 0, name: nil, message: "'\(section)s' is not a list"))
            return []
        }
        var out: [(Int, T)] = []
        for (i, item) in array.enumerated() {
            do {
                out.append((i, try JSONDecoder().decode(T.self, from: item.data)))
            } catch {
                issues.append(ImportIssue(section: section, index: i, name: item["name"]?.str, message: message(for: error)))
            }
        }
        return out
    }

    /// A readable reason from a decoding error: "Invalid time '25:00', expected HH:mm", "missing 'action'".
    static func message(for error: Error) -> String {
        guard let e = error as? DecodingError else { return String(describing: error) }
        func path(_ keys: [CodingKey]) -> String { keys.map(\.stringValue).joined(separator: ".") }
        switch e {
        case .dataCorrupted(let ctx): return ctx.debugDescription
        case .keyNotFound(let key, let ctx): return "missing '\(path(ctx.codingPath + [key]))'"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx): return "wrong type for '\(path(ctx.codingPath))'"
        @unknown default: return String(describing: e)
        }
    }
}
