import Foundation

/// The non-secret settings (HANDOVER.md §6, Settings). Credentials live in the Keychain, not here.
public struct AppSettings: Codable, Equatable, Sendable {
    public static let minTargetC = 16.0
    public static let maxTargetC = 30.0

    public var minSocPercent: Int
    public var defaultTargetC: Double
    public var globalCooldownMinutes: Int
    public var automationPaused: Bool
    /// Kia: requests per rolling 24 h.
    public var budgetLimit: Int
    public var budgetReserve: Int
    /// Developer: talk to the fake car instead of Kia.
    public var fakeMode: Bool
    /// Days when automation never runs.
    public var holidays: [CalendarDay]
    /// Developer: the fake weather's temperature.
    public var fakeWeatherC: Double

    public init(
        minSocPercent: Int = 25,
        defaultTargetC: Double = 21,
        globalCooldownMinutes: Int = 15,
        automationPaused: Bool = false,
        budgetLimit: Int = BudgetConfig.kia.limit,
        budgetReserve: Int = BudgetConfig.kia.manualReserve,
        fakeMode: Bool = false,
        holidays: [CalendarDay] = [],
        fakeWeatherC: Double = 3
    ) {
        self.minSocPercent = minSocPercent
        self.defaultTargetC = defaultTargetC
        self.globalCooldownMinutes = globalCooldownMinutes
        self.automationPaused = automationPaused
        self.budgetLimit = budgetLimit
        self.budgetReserve = budgetReserve
        self.fakeMode = fakeMode
        self.holidays = holidays
        self.fakeWeatherC = fakeWeatherC
    }

    public init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minSocPercent = try c.decodeIfPresent(Int.self, forKey: .minSocPercent) ?? d.minSocPercent
        defaultTargetC = try c.decodeIfPresent(Double.self, forKey: .defaultTargetC) ?? d.defaultTargetC
        globalCooldownMinutes = try c.decodeIfPresent(Int.self, forKey: .globalCooldownMinutes) ?? d.globalCooldownMinutes
        automationPaused = try c.decodeIfPresent(Bool.self, forKey: .automationPaused) ?? d.automationPaused
        budgetLimit = try c.decodeIfPresent(Int.self, forKey: .budgetLimit) ?? d.budgetLimit
        budgetReserve = try c.decodeIfPresent(Int.self, forKey: .budgetReserve) ?? d.budgetReserve
        fakeMode = try c.decodeIfPresent(Bool.self, forKey: .fakeMode) ?? d.fakeMode
        holidays = try c.decodeIfPresent([CalendarDay].self, forKey: .holidays) ?? d.holidays
        fakeWeatherC = try c.decodeIfPresent(Double.self, forKey: .fakeWeatherC) ?? d.fakeWeatherC
    }

    /// Values forced into their allowed ranges.
    public var clamped: AppSettings {
        var s = self
        s.minSocPercent = min(max(s.minSocPercent, 0), 100)
        s.defaultTargetC = min(max((s.defaultTargetC * 2).rounded() / 2, Self.minTargetC), Self.maxTargetC)
        s.globalCooldownMinutes = min(max(s.globalCooldownMinutes, 0), 24 * 60)
        s.budgetLimit = min(max(s.budgetLimit, 10), 200)
        s.budgetReserve = min(max(s.budgetReserve, 0), s.budgetLimit / 2)
        s.holidays = Array(Set(s.holidays)).sorted()
        s.fakeWeatherC = min(max(s.fakeWeatherC, -30), 45)
        return s
    }

    public var budgetConfig: BudgetConfig {
        BudgetConfig(limit: budgetLimit, manualReserve: budgetReserve, window: BudgetConfig.kia.window)
    }

    public var guards: GuardSettings {
        GuardSettings(
            minSocPercent: minSocPercent,
            globalCooldown: TimeInterval(globalCooldownMinutes * 60),
            automationPaused: automationPaused,
            holidays: Set(holidays)
        )
    }
}

public struct FileSettingsStore: SettingsSource {
    let file: JSONFileStore<AppSettings>

    public func load() async -> AppSettings { await file.load() }

    public func save(_ settings: AppSettings) async { await file.save(settings.clamped) }

    public func guards() async -> GuardSettings { await load().guards }

    public func defaultTargetC() async -> Double { await load().defaultTargetC }
}

// MARK: - Fake-car mode plumbing

/// Credentials that switch to a stand-in while fake-car mode is on, so the fake works without a token.
public struct ModeAwareCredentials: CredentialsProvider {
    private let real: CredentialsProvider
    private let isFake: @Sendable () -> Bool

    public init(real: CredentialsProvider, isFake: @escaping @Sendable () -> Bool) {
        self.real = real
        self.isFake = isFake
    }

    public func credentials() async -> Credentials? {
        if isFake() { return Credentials(refreshToken: "FAKE0000000000000000000000000000000000000000000", pin: "0000") }
        return await real.credentials()
    }
}

/// Keeps the fake car's session in its own slot, so the simulator can never overwrite a real (possibly
/// rotated) refresh token.
public struct ModeAwareSessionStore: KiaSessionStore {
    private let real: KiaSessionStore
    private let fake: KiaSessionStore
    private let isFake: @Sendable () -> Bool

    public init(real: KiaSessionStore, fake: KiaSessionStore, isFake: @escaping @Sendable () -> Bool) {
        self.real = real
        self.fake = fake
        self.isFake = isFake
    }

    public func load() async -> KiaSession? { await (isFake() ? fake : real).load() }
    public func save(_ session: KiaSession?) async { await (isFake() ? fake : real).save(session) }
}
