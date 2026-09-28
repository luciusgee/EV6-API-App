import Foundation

/// A JSON tree. Kia's JSON is loosely typed (booleans as `0`/`1`, numbers as strings, fields that come
/// and go), so responses are read as a tree and picked apart with lenient accessors rather than decoded
/// into fixed structs. Missing or odd values come back as `nil`, which the app treats as "unknown".
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Parsing and printing

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

public extension JSONValue {
    /// Nil if `data` isn't JSON.
    static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }

    /// Compact JSON with sorted keys, so output is stable.
    var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    var text: String { String(decoding: data, as: UTF8.self) }
}

// MARK: - Lenient accessors

public extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// Follows a dotted path through objects, and through arrays for numeric parts: `"drvDistance.0.rangeByFuel"`.
    func path(_ dotted: String) -> JSONValue? {
        var current: JSONValue? = self
        for part in dotted.split(separator: ".", omittingEmptySubsequences: false) {
            switch current {
            case .object(let o)?:
                current = o[String(part)]
            case .array(let a)?:
                guard let i = Int(part), a.indices.contains(i) else { return nil }
                current = a[i]
            default:
                return nil
            }
        }
        return current
    }

    /// A string, or a number or boolean as text.
    var str: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return Self.format(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// A number, or a numeric string.
    var num: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// A whole number (truncated), or nil if there's no finite number.
    var int: Int? {
        guard let n = num, n.isFinite, abs(n) < 1e15 else { return nil }
        return Int(n)
    }

    /// Kia mixes `true`/`false` with `0`/`1`, sometimes as strings.
    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s):
            switch s.lowercased() {
            case "true": return true
            case "false": return false
            default: return Double(s).map { $0 != 0 }
            }
        default: return nil
        }
    }

    var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    /// `21.0` → `"21"`, `10.9` → `"10.9"`.
    static func format(_ n: Double) -> String {
        if n.isFinite, n.rounded() == n, abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }
}

// MARK: - Literals, for building request bodies

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
