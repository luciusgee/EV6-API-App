import Foundation

public enum CarAlertKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case pluggedIn, notCharging, chargingStopped, chargeComplete, leftUnlocked, windowOpen, lowAuxBattery, tyrePressure, lowCharge

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pluggedIn: return "Plugged in"
        case .notCharging: return "Not charging in the off-peak window"
        case .chargingStopped: return "Charging stopped early"
        case .chargeComplete: return "Charge complete"
        case .leftUnlocked: return "Left unlocked"
        case .windowOpen: return "Window open"
        case .lowAuxBattery: return "12 V battery low"
        case .tyrePressure: return "Tyre pressure"
        case .lowCharge: return "Low charge"
        }
    }
}

public struct CarAlert: Equatable, Sendable {
    public var kind: CarAlertKind
    public var title: String
    public var body: String
}

public struct AlertSettings: Codable, Equatable, Sendable {
    public var enabled: Set<CarAlertKind>
    public var lowChargePercent: Int
    public var lowAuxPercent: Int
    /// Read the car in the background every so often to catch these (uses Kia requests).
    public var backgroundChecks: Bool
    public var backgroundEveryHours: Int
    /// The evening "not plugged in yet" reminder.
    public var plugReminder: PlugReminder

    public init(
        enabled: Set<CarAlertKind> = Set(CarAlertKind.allCases),
        lowChargePercent: Int = 20,
        lowAuxPercent: Int = 70,
        backgroundChecks: Bool = true,
        backgroundEveryHours: Int = 2,
        plugReminder: PlugReminder = PlugReminder()
    ) {
        self.enabled = enabled
        self.lowChargePercent = lowChargePercent
        self.lowAuxPercent = lowAuxPercent
        self.backgroundChecks = backgroundChecks
        self.backgroundEveryHours = backgroundEveryHours
        self.plugReminder = plugReminder
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, lowChargePercent, lowAuxPercent, backgroundChecks, backgroundEveryHours, plugReminder, knownKinds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertSettings()
        // Kinds added since these settings were saved start switched on.
        let known = try c.decodeIfPresent(Set<CarAlertKind>.self, forKey: .knownKinds)
            ?? [.chargingStopped, .chargeComplete, .leftUnlocked, .windowOpen, .lowAuxBattery, .tyrePressure, .lowCharge]
        let saved = try c.decodeIfPresent(Set<CarAlertKind>.self, forKey: .enabled) ?? d.enabled
        enabled = saved.union(Set(CarAlertKind.allCases).subtracting(known))
        lowChargePercent = try c.decodeIfPresent(Int.self, forKey: .lowChargePercent) ?? d.lowChargePercent
        lowAuxPercent = try c.decodeIfPresent(Int.self, forKey: .lowAuxPercent) ?? d.lowAuxPercent
        backgroundChecks = try c.decodeIfPresent(Bool.self, forKey: .backgroundChecks) ?? d.backgroundChecks
        backgroundEveryHours = try c.decodeIfPresent(Int.self, forKey: .backgroundEveryHours) ?? d.backgroundEveryHours
        plugReminder = try c.decodeIfPresent(PlugReminder.self, forKey: .plugReminder) ?? d.plugReminder
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(lowChargePercent, forKey: .lowChargePercent)
        try c.encode(lowAuxPercent, forKey: .lowAuxPercent)
        try c.encode(backgroundChecks, forKey: .backgroundChecks)
        try c.encode(backgroundEveryHours, forKey: .backgroundEveryHours)
        try c.encode(plugReminder, forKey: .plugReminder)
        try c.encode(Set(CarAlertKind.allCases), forKey: .knownKinds)
    }
}

/// "Not plugged in yet": a reminder at a set time each evening, skipped when the car is already
/// plugged in or has plenty of charge.
public struct PlugReminder: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var at: ClockTime
    /// No reminder when the car has at least this much.
    public var skipAbovePercent: Int

    public init(enabled: Bool = true, at: ClockTime = ClockTime(hour: 21), skipAbovePercent: Int = 90) {
        self.enabled = enabled
        self.at = at
        self.skipAbovePercent = skipAbovePercent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlugReminder()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        at = try c.decodeIfPresent(ClockTime.self, forKey: .at) ?? d.at
        skipAbovePercent = try c.decodeIfPresent(Int.self, forKey: .skipAbovePercent) ?? d.skipAbovePercent
    }

    /// When to remind next, given the latest reading: today at `at` unless it's passed or the car is
    /// already sorted (plugged in, seen since the morning, or charged enough), else tomorrow.
    public func next(after now: Date, snapshot: VehicleSnapshot?, calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        guard let today = calendar.date(bySettingHour: at.hour, minute: at.minute, second: 0, of: now) else { return nil }
        let morning = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: now) ?? now
        let reported = snapshot.map { $0.carCapturedAt ?? $0.fetchedAt }
        let pluggedToday = snapshot?.pluggedIn == true && (reported ?? .distantPast) >= morning
        let full = (snapshot?.socPercent ?? 0) >= skipAbovePercent
        if today > now && !pluggedToday && !full { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// The reminder's words.
    /// It's booked ahead from the last reading, so it says when that was: plugging in after that
    /// reading can't be known unless the app got to check the car first.
    public static func message(snapshot: VehicleSnapshot?, now: Date, timeZone: TimeZone = .current) -> (title: String, body: String) {
        var seen = ""
        if let snapshot {
            let when = DisplayText.clock(snapshot.carCapturedAt ?? snapshot.fetchedAt, timeZone)
            seen = "At \(when) it was unplugged" + (snapshot.socPercent.map { " at \($0)%" } ?? "") + ". "
        }
        return ("Is your EV6 plugged in?", seen + "Plug in if it needs charging tonight. Already plugged in? Tap to check.")
    }

    /// Shortly before the reminder, the app asks iOS for a chance to check the car, so a car that's
    /// since been plugged in cancels it.
    public static let checkAhead: TimeInterval = 25 * 60
}

/// Which lasting conditions have already been announced, so each is said once until it clears.
public struct AlertState: Codable, Equatable, Sendable {
    public var raised: Set<CarAlertKind> = []
    public var lastSnapshotAt: Date?
    public init() {}
}

/// Turns a new reading of the car into notifications worth sending.
public enum AlertEngine {
    public static func evaluate(
        previous: VehicleSnapshot?,
        current s: VehicleSnapshot,
        state: inout AlertState,
        settings: AlertSettings,
        now: Date,
        calendar: Calendar = .current,
        chargerKW: Double = 7.4,
        usableKWh: Double = 74
    ) -> [CarAlert] {
        let reportedAt = s.carCapturedAt ?? s.fetchedAt
        // The same report again: no new changes, though lasting conditions (like not charging by now)
        // are still checked.
        let isNew = state.lastSnapshotAt.map { reportedAt > $0 } ?? true
        if isNew { state.lastSnapshotAt = reportedAt }

        var out: [CarAlert] = []
        let soc = s.socPercent
        let parked = s.parked != false
        let details = s.details

        // Changes: only when the previous reading showed charging.
        if isNew, let previous, previous.chargingState == .charging, s.chargingState != .charging, let soc {
            let limit = details?.chargeLimitAC ?? 100
            if soc >= limit - 2 {
                out.append(CarAlert(kind: .chargeComplete, title: "EV6 charged to \(soc)%", body: "Charging has finished."))
            } else if s.pluggedIn == true {
                out.append(CarAlert(kind: .chargingStopped, title: "EV6 stopped charging at \(soc)%",
                                    body: "It's still plugged in but not charging, below its \(limit)% limit."))
            }
        }

        // Plugged in: say so, and what happens next.
        if isNew, let previous, previous.pluggedIn == false, s.pluggedIn == true {
            out.append(CarAlert(kind: .pluggedIn, title: "EV6 plugged in\(soc.map { " at \($0)%" } ?? "")", body: pluggedInBody(s, now: now, calendar: calendar, chargerKW: chargerKW, usableKWh: usableKWh)))
        }

        // Conditions: said once, then again only after they've cleared.
        func condition(_ kind: CarAlertKind, _ active: Bool, _ title: @autoclosure () -> String, _ body: @autoclosure () -> String) {
            if active {
                if !state.raised.contains(kind) {
                    state.raised.insert(kind)
                    out.append(CarAlert(kind: kind, title: title(), body: body()))
                }
            } else {
                state.raised.remove(kind)
            }
        }
        condition(.leftUnlocked, details?.locked == false && parked && now.timeIntervalSince(reportedAt) >= 10 * 60,
                  "EV6 is unlocked", "It's been unlocked since at least \(clock(reportedAt)). Lock it from My EV6.")
        let windows = details?.openWindows ?? []
        condition(.windowOpen, !windows.isEmpty && parked,
                  windows.count == 1 ? "EV6 window open" : "EV6 windows open",
                  "\(Self.list(windows).capitalizingFirstLetter) \(windows.count == 1 ? "is" : "are") open.")
        if let aux = details?.auxBatteryPercent {
            condition(.lowAuxBattery, aux < settings.lowAuxPercent,
                      "EV6 12 V battery at \(aux)%", "It's normally 80–100%. If it keeps falling, have the ICCU checked.")
        }
        condition(.tyrePressure, details?.tyreWarning == true,
                  "EV6 tyre pressure warning", (details?.tyreWarnings ?? []).isEmpty ? "Check the tyres." : "Check: \((details?.tyreWarnings ?? []).joined(separator: ", ")).")
        if let window = details?.offPeak, let soc {
            let limit = details?.chargeLimitAC ?? 100
            condition(.notCharging, s.pluggedIn == true && s.chargingState != .charging && soc < limit - 2 && Self.lateInWindow(window, now: now, calendar: calendar),
                      "EV6 plugged in but not charging",
                      "It's past \(window.start.text) and it hasn't started. If your charger needs confirming in its app, do that now.")
        }
        if let soc {
            condition(.lowCharge, soc < settings.lowChargePercent && s.pluggedIn != true,
                      "EV6 at \(soc)%", "Charge is below \(settings.lowChargePercent)% and it isn't plugged in.")
        }
        return out.filter { settings.enabled.contains($0.kind) }
    }

    /// "It'll charge 23:00–06:00 to 80%. All set for tomorrow."
    /// What happens next, with the charge it should have by the end: "…should reach 80% (its limit)
    /// by about 02:55. All set for tomorrow." or "…should be at about 72% by 06:00."
    static func pluggedInBody(_ s: VehicleSnapshot, now: Date, calendar: Calendar = .current,
                              chargerKW: Double = 7.4, usableKWh: Double = 74) -> String {
        let limit = s.details?.chargeLimitAC.map { " to \($0)%" } ?? ""
        func outlook(_ w: OffPeakWindow) -> String? {
            guard let e = OffPeakForecast.estimate(s, window: w, now: now, chargerKW: chargerKW, usableKWh: usableKWh, calendar: calendar) else { return nil }
            if e.reachesLimit, let done = e.doneAt {
                // To the nearest 5 minutes: it's an estimate.
                let rounded = Date(timeIntervalSinceReferenceDate: (done.timeIntervalSinceReferenceDate / 300).rounded() * 300)
                return "should reach \(e.percent)% (its limit) by about \(clock(rounded, calendar))"
            }
            if e.reachesLimit { return "should reach \(e.percent)% (its limit) by \(clock(e.at, calendar))" }
            return "should be at about \(e.percent)% by \(clock(e.at, calendar)), short of its \(s.details?.chargeLimitAC ?? 100)% limit"
        }
        if s.chargingState == .charging {
            if let w = s.details?.offPeak, let o = outlook(w) { return "Charging now, and it \(o)." }
            return "Charging now\(limit)."
        }
        if let w = s.details?.offPeak {
            if let o = outlook(w) {
                let done = o.contains("(its limit)")
                return "It'll charge in the off-peak window, \(w.text), and \(o).\(done ? " All set for tomorrow." : "")"
            }
            return "It'll charge in the off-peak window, \(w.text)\(limit). All set for tomorrow."
        }
        return "Not charging yet."
    }

    /// At least 20 minutes into the off-peak window, and not past its end.
    static func lateInWindow(_ w: OffPeakWindow, now: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let since = (m - w.start.minutes + 1440) % 1440
        let length = (w.end.minutes - w.start.minutes + 1440) % 1440
        return since >= 20 && since < length
    }

    /// "front left", "front left and rear right", "front left, front right and rear right".
    static func list(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    private static func clock(_ date: Date) -> String {
        clock(date, .current)
    }

    private static func clock(_ date: Date, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
