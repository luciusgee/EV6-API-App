import Foundation

// The services the engine needs from the app (the Android `Ports.kt`). The kit ships file-backed
// implementations (FileStores.swift) and in-memory ones for tests; the app supplies the Keychain and
// notification pieces.

// MARK: - Log

public enum LogKind: String, Codable, CaseIterable, Sendable {
    case fired = "FIRED"
    case skipped = "SKIPPED"
    case command = "COMMAND"
    case manual = "MANUAL"
    case dryRun = "DRY_RUN"
    case error = "ERROR"
    case info = "INFO"
}

public struct LogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var at: Date
    public var kind: LogKind
    /// Short outcome: "fired", "skipped", "sent", "failed", "refused"...
    public var decision: String
    public var reason: String
    public var trigger: String?
    public var ruleId: String?
    public var ruleName: String?
    public var httpCode: Int?
    public var requestsUsed: Int
    /// One line per check, or the first vehicle response (VIN masked).
    public var details: String?

    public init(
        id: UUID = UUID(),
        at: Date,
        kind: LogKind,
        decision: String,
        reason: String,
        trigger: String? = nil,
        ruleId: String? = nil,
        ruleName: String? = nil,
        httpCode: Int? = nil,
        requestsUsed: Int = 0,
        details: String? = nil
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.decision = decision
        self.reason = reason
        self.trigger = trigger
        self.ruleId = ruleId
        self.ruleName = ruleName
        self.httpCode = httpCode
        self.requestsUsed = requestsUsed
        self.details = details
    }
}

public protocol EventLog: Sendable {
    func append(_ entry: LogEntry) async
    /// Oldest first.
    func entries() async -> [LogEntry]
}

public enum LogRetention {
    public static let maxEntries = 2000
    public static let maxAge: TimeInterval = 30 * 24 * 3600

    /// Keeps the last 30 days or 2,000 entries, whichever is smaller.
    public static func trim(_ entries: [LogEntry], now: Date) -> [LogEntry] {
        let cutoff = now.addingTimeInterval(-maxAge)
        return Array(entries.filter { $0.at >= cutoff }.suffix(maxEntries))
    }

    /// For the Activity screen's export.
    public static func csv(_ entries: [LogEntry]) -> String {
        let iso = ISO8601DateFormatter()
        func field(_ s: String?) -> String {
            guard let s, !s.isEmpty else { return "" }
            guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return s }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["time,kind,decision,reason,trigger,rule,http,requests,details"]
        for e in entries {
            lines.append([
                iso.string(from: e.at), e.kind.rawValue, field(e.decision), field(e.reason), field(e.trigger),
                field(e.ruleName), e.httpCode.map(String.init) ?? "", String(e.requestsUsed), field(e.details),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public actor InMemoryEventLog: EventLog {
    public private(set) var all: [LogEntry] = []
    public init() {}
    public func append(_ entry: LogEntry) { all.append(entry) }
    public func entries() -> [LogEntry] { all }
}

// MARK: - Automation state

public struct LastCommand: Codable, Equatable, Sendable {
    public var at: Date
    public var description: String
    public var automated: Bool

    public init(at: Date, description: String, automated: Bool) {
        self.at = at
        self.description = description
        self.automated = automated
    }
}

/// Persisted between runs. Unknown or missing keys decode as defaults, so new fields never break old files.
public struct AutomationState: Codable, Equatable, Sendable {
    public var lastAutomatedCommandAt: Date?
    public var lastFiredByRule: [String: Date]
    /// Per trigger dedup key, when that geofence event was last handled.
    public var lastTriggerAt: [String: Date]
    public var consecutiveFailures: Int
    public var pausedAfterFailures: Bool
    /// Set when Kia rejects the login; automation stays stopped until the token is replaced or a request succeeds.
    public var authFailure: String?
    public var firstVehicleDumpDone: Bool
    public var lastCommand: LastCommand?

    public init(
        lastAutomatedCommandAt: Date? = nil,
        lastFiredByRule: [String: Date] = [:],
        lastTriggerAt: [String: Date] = [:],
        consecutiveFailures: Int = 0,
        pausedAfterFailures: Bool = false,
        authFailure: String? = nil,
        firstVehicleDumpDone: Bool = false,
        lastCommand: LastCommand? = nil
    ) {
        self.lastAutomatedCommandAt = lastAutomatedCommandAt
        self.lastFiredByRule = lastFiredByRule
        self.lastTriggerAt = lastTriggerAt
        self.consecutiveFailures = consecutiveFailures
        self.pausedAfterFailures = pausedAfterFailures
        self.authFailure = authFailure
        self.firstVehicleDumpDone = firstVehicleDumpDone
        self.lastCommand = lastCommand
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastAutomatedCommandAt = try c.decodeIfPresent(Date.self, forKey: .lastAutomatedCommandAt)
        lastFiredByRule = try c.decodeIfPresent([String: Date].self, forKey: .lastFiredByRule) ?? [:]
        lastTriggerAt = try c.decodeIfPresent([String: Date].self, forKey: .lastTriggerAt) ?? [:]
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        pausedAfterFailures = try c.decodeIfPresent(Bool.self, forKey: .pausedAfterFailures) ?? false
        authFailure = try c.decodeIfPresent(String.self, forKey: .authFailure)
        firstVehicleDumpDone = try c.decodeIfPresent(Bool.self, forKey: .firstVehicleDumpDone) ?? false
        lastCommand = try c.decodeIfPresent(LastCommand.self, forKey: .lastCommand)
    }

    /// Why automation won't run, or nil if it may.
    public var automationBlockedReason: String? {
        if let authFailure { return "automation stopped: \(authFailure)" }
        if pausedAfterFailures { return "automation paused after \(consecutiveFailures) consecutive failures" }
        return nil
    }
}

public protocol AutomationStateStore: Sendable {
    func load() async -> AutomationState
    /// Read-modify-write in one step. Returns the new state.
    @discardableResult
    func update(_ change: @Sendable (inout AutomationState) -> Void) async -> AutomationState
}

public actor InMemoryAutomationStateStore: AutomationStateStore {
    public private(set) var state: AutomationState
    public init(_ state: AutomationState = AutomationState()) { self.state = state }
    public func load() -> AutomationState { state }
    @discardableResult
    public func update(_ change: @Sendable (inout AutomationState) -> Void) -> AutomationState {
        change(&state)
        return state
    }
}

// MARK: - Vehicle cache, settings, notifications

public protocol VehicleCacheStore: Sendable {
    func load() async -> VehicleSnapshot?
    func save(_ snapshot: VehicleSnapshot?) async
}

public actor InMemoryVehicleCache: VehicleCacheStore {
    public private(set) var snapshot: VehicleSnapshot?
    public init(_ snapshot: VehicleSnapshot? = nil) { self.snapshot = snapshot }
    public func load() -> VehicleSnapshot? { snapshot }
    public func save(_ snapshot: VehicleSnapshot?) { self.snapshot = snapshot }
}

public struct GuardSettings: Equatable, Sendable {
    public var minSocPercent: Int
    public var globalCooldown: TimeInterval
    public var automationPaused: Bool
    /// Days when automation never runs.
    public var holidays: Set<CalendarDay>

    public init(minSocPercent: Int = 25, globalCooldown: TimeInterval = 15 * 60, automationPaused: Bool = false, holidays: Set<CalendarDay> = []) {
        self.minSocPercent = minSocPercent
        self.globalCooldown = globalCooldown
        self.automationPaused = automationPaused
        self.holidays = holidays
    }
}

public protocol SettingsSource: Sendable {
    func guards() async -> GuardSettings
    func defaultTargetC() async -> Double
    func climatePreferences() async -> ClimatePreferences
}

extension SettingsSource {
    public func climatePreferences() async -> ClimatePreferences { ClimatePreferences() }
}

/// How every climate start is sent.
public struct ClimatePreferences: Equatable, Sendable {
    public var options: ClimateOptions
    /// Stop the charger first when the car is plugged in but not charging.
    public var holdCharger: Bool

    public init(options: ClimateOptions = ClimateOptions(), holdCharger: Bool = false) {
        self.options = options
        self.holdCharger = holdCharger
    }
}

public protocol Notifier: Sendable {
    /// A climate command was accepted. `canStop` adds a Stop action.
    func commandSent(title: String, text: String, canStop: Bool) async
    func problem(title: String, text: String, openSettings: Bool) async
}

public struct NoopNotifier: Notifier {
    public init() {}
    public func commandSent(title: String, text: String, canStop: Bool) async {}
    public func problem(title: String, text: String, openSettings: Bool) async {}
}
