import Foundation

/// One Codable value in a JSON file, read once and cached. Writes are atomic. Secrets never go here:
/// they belong in the Keychain.
public actor JSONFileStore<Value: Codable & Sendable> {
    private let url: URL
    private let defaultValue: Value
    private var cached: Value?

    public init(url: URL, default defaultValue: Value) {
        self.url = url
        self.defaultValue = defaultValue
    }

    public func load() -> Value {
        if let cached { return cached }
        let value = (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(Value.self, from: $0) } ?? defaultValue
        cached = value
        return value
    }

    public func save(_ value: Value) {
        cached = value
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(value)
            #if os(iOS)
            // Readable after the first unlock.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        } catch {
            // The in-memory copy stays current; the next save tries again.
        }
    }

    /// Read-modify-write without another caller getting in between.
    @discardableResult
    public func update(_ change: @Sendable (inout Value) -> Void) -> Value {
        var value = load()
        change(&value)
        save(value)
        return value
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
