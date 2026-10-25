import Foundation

/// One Codable value in a JSON file, read once and cached. Writes are atomic. Secrets never go here:
/// they belong in the Keychain. A file that exists but won't decode (corrupt, or written by a
/// different schema) is moved aside to `<name>.unreadable-<timestamp>.json` rather than written over.
public actor JSONFileStore<Value: Codable & Sendable> {
    private let url: URL
    private let defaultValue: Value
    private var cached: Value?
    /// The file exists but couldn't be read (e.g. still protected) or couldn't be moved aside, so
    /// saves don't write over it. Cleared by a load that reads it, or by a save that merges with it.
    private var blocked = false
    /// Combines the file's contents with a value built while it was unreadable (file, then saved value).
    private let merge: (@Sendable (Value, Value) -> Value)?

    /// `merge`, when given, lets a save made while the file was unreadable be written once it reads:
    /// it gets the file's contents and the saved value. Without it, saves wait for a load that reads it.
    public init(url: URL, default defaultValue: Value, merge: (@Sendable (Value, Value) -> Value)? = nil) {
        self.url = url
        self.defaultValue = defaultValue
        self.merge = merge
    }

    public func load() -> Value {
        if let cached { return cached }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            cached = defaultValue
            return defaultValue
        }
        if let data = try? Data(contentsOf: url) {
            if let value = try? Self.decoder.decode(Value.self, from: data) {
                blocked = false
                cached = value
                return value
            }
            // Undecodable: keep it for recovery, then start from the default.
            blocked = !setAside()
            cached = defaultValue
            return defaultValue
        }
        // Exists but unreadable for now: don't cache, so the next load tries again, and don't save over it.
        blocked = true
        return defaultValue
    }

    /// Moves the current file to `<name>.unreadable-<timestamp>.json`. True when it's out of the way.
    private func setAside() -> Bool {
        let stamp = Int(Date().timeIntervalSince1970)
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        let target = url.deletingLastPathComponent().appendingPathComponent("\(name).unreadable-\(stamp).\(ext)")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return true
        } catch {
            return false
        }
    }

    /// Returns the value now held: the saved one, merged with the file's when that happened.
    @discardableResult
    public func save(_ value: Value) -> Value {
        var value = value
        if blocked {
            // Never write over a file we couldn't read. Carry on only once it's gone, moved aside or merged.
            guard FileManager.default.fileExists(atPath: url.path) else { blocked = false; return save(value) }
            guard let data = try? Data(contentsOf: url) else {
                // Still unreadable: don't cache, so a load reads the file once it can.
                cached = nil
                return value
            }
            if let onFile = try? Self.decoder.decode(Value.self, from: data) {
                // It reads now, and this value was built on the default: write it only merged with the
                // file. Without a merge, stay blocked until a load picks the file up.
                guard let merge else { cached = nil; return value }
                value = merge(onFile, value)
            } else {
                // Undecodable, so the default was right; keep the value in memory until it's out of the way.
                guard setAside() else { cached = value; return value }
            }
            blocked = false
        }
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
        return value
    }

    /// Read-modify-write without another caller getting in between.
    @discardableResult
    public func update(_ change: @Sendable (inout Value) -> Void) -> Value {
        var value = load()
        change(&value)
        return save(value)
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
