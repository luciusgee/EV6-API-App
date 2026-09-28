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
            // Readable after the first unlock, so background wakes (geofences, Shortcuts) can use it.
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

/// The app's non-secret state, one file each, in a folder such as Application Support.
public struct FileStores: Sendable {
    public let budget: FileRateBudgetStore
    public let vehicleCache: FileVehicleCache
    public let automationState: FileAutomationStateStore
    public let log: FileEventLog
    public let settings: FileSettingsStore
    /// The last driving history, so the Energy screen opens without a request.
    public let energy: JSONFileStore<DrivingHistory?>

    public init(directory: URL, time: TimeSource = SystemTime()) {
        budget = FileRateBudgetStore(file: JSONFileStore(url: directory.appendingPathComponent("budget.json"), default: RateBudgetState()))
        vehicleCache = FileVehicleCache(file: JSONFileStore(url: directory.appendingPathComponent("vehicle.json"), default: nil))
        automationState = FileAutomationStateStore(file: JSONFileStore(url: directory.appendingPathComponent("automation.json"), default: AutomationState()))
        log = FileEventLog(file: JSONFileStore(url: directory.appendingPathComponent("log.json"), default: []), time: time)
        settings = FileSettingsStore(file: JSONFileStore(url: directory.appendingPathComponent("settings.json"), default: AppSettings()))
        energy = JSONFileStore(url: directory.appendingPathComponent("energy.json"), default: nil)
    }
}

public struct FileRateBudgetStore: RateBudgetStore {
    let file: JSONFileStore<RateBudgetState>
    public func load() async -> RateBudgetState { await file.load() }
    public func save(_ state: RateBudgetState) async { await file.save(state) }
}

public struct FileVehicleCache: VehicleCacheStore {
    let file: JSONFileStore<VehicleSnapshot?>
    public func load() async -> VehicleSnapshot? { await file.load() }
    public func save(_ snapshot: VehicleSnapshot?) async { await file.save(snapshot) }
}

public struct FileAutomationStateStore: AutomationStateStore {
    let file: JSONFileStore<AutomationState>
    public func load() async -> AutomationState { await file.load() }
    @discardableResult
    public func update(_ change: @Sendable (inout AutomationState) -> Void) async -> AutomationState {
        await file.update(change)
    }
}

public struct FileEventLog: EventLog {
    let file: JSONFileStore<[LogEntry]>
    let time: TimeSource

    public func append(_ entry: LogEntry) async {
        let now = time.now()
        await file.update { entries in
            entries.append(entry)
            entries = LogRetention.trim(entries, now: now)
        }
    }

    public func entries() async -> [LogEntry] { await file.load() }

    public func clear() async { await file.save([]) }
}
