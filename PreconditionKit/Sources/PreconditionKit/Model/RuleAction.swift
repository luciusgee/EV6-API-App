import Foundation

/// What a rule (or the user) asks the car to do. JSON matches the Android backups:
/// `{"type":"startClimate","targetC":21.0}` and `{"type":"stopClimate"}`.
public enum RuleAction: Equatable, Hashable, Sendable {
    case startClimate(targetC: Double)
    case stopClimate
}

public extension RuleAction {
    var isStop: Bool { self == .stopClimate }
}

extension RuleAction: Codable {
    private enum CodingKeys: String, CodingKey { case type, targetC }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "startClimate": self = .startClimate(targetC: try c.decode(Double.self, forKey: .targetC))
        case "stopClimate": self = .stopClimate
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown action type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .startClimate(let target):
            try c.encode("startClimate", forKey: .type)
            try c.encode(target, forKey: .targetC)
        case .stopClimate:
            try c.encode("stopClimate", forKey: .type)
        }
    }
}

/// User-facing wording, as in the Android `Describe.kt`. It appears in the log and notifications.
public enum Describe {
    /// `"21.0 °C"`.
    public static func temp(_ c: Double) -> String {
        String(format: "%.1f °C", c)
    }

    public static func action(_ a: RuleAction) -> String {
        switch a {
        case .startClimate(let target): return "climatise to \(temp(target))"
        case .stopClimate: return "stop climatisation"
        }
    }
}
