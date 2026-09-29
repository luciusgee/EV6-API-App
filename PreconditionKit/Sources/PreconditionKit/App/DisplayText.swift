import Foundation

/// Short texts the screens show, kept here so they're tested.
public enum DisplayText {
    /// The line under the dashboard's request count: "Next one frees up at 17:10".
    public static func budget(_ b: BudgetSnapshot, timeZone: TimeZone = .current) -> String {
        if let until = b.exhaustedUntil {
            return "Kia's daily limit is used up. Try again at \(clock(until, timeZone))."
        }
        if let reset = b.resetAt { return "Each one comes back 24 hours after it's used. Next at \(clock(reset, timeZone))." }
        return "None used in the last 24 hours."
    }

    /// "just now", "5 min ago", "3 h ago", "2 days ago".
    public static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<(48 * 3600): return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86400)) days ago"
        }
    }

    /// "Charging · 10.9 kW · full in 1 h 35 min", "Plugged in", "Unplugged".
    public static func charging(_ v: VehicleSnapshot) -> String? {
        switch v.chargingState {
        case .charging?:
            var parts = ["Charging"]
            if let kw = v.chargePowerKw { parts.append(String(format: "%.1f kW", kw)) }
            if let minutes = v.minutesToFullyCharged { parts.append("full in \(duration(minutes: minutes))") }
            return parts.joined(separator: " · ")
        case .pluggedIn?: return "Plugged in"
        case .unplugged?: return "Unplugged"
        case nil: return nil
        }
    }

    public static func duration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    public static func clock(_ date: Date, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    public static let kmPerMile = 1.609344

    /// "196 mi", "315 km".
    public static func distance(km: Double, miles: Bool) -> String {
        miles ? "\(Int((km / kmPerMile).rounded())) mi" : "\(Int(km.rounded())) km"
    }

    /// "3.9 mi/kWh" or "16.0 kWh/100 km"; nil when there's nothing to divide.
    public static func efficiency(kWhPer100km: Double?, miles: Bool) -> String? {
        guard let e = kWhPer100km, e > 0 else { return nil }
        if miles { return String(format: "%.1f mi/kWh", 100 / e / kmPerMile) }
        return String(format: "%.1f kWh/100 km", e)
    }

    /// "12.4 kWh", "850 Wh".
    public static func energy(wh: Double) -> String {
        abs(wh) >= 1000 ? String(format: "%.1f kWh", wh / 1000) : "\(Int(wh.rounded())) Wh"
    }

    /// What Siri says for "How's my car?": "72%, 196 mi range. Charging at 7.4 kW, full in 1 h 5 min. Locked. Climate on at 21.0 °C."
    public static func spokenStatus(_ v: VehicleSnapshot, miles: Bool) -> String {
        var parts: [String] = []
        var first = v.socPercent.map { "\($0)%" } ?? "Charge unknown"
        if let range = v.rangeKm { first += ", \(distance(km: Double(range), miles: miles)) range" }
        parts.append(first)
        switch v.chargingState {
        case .charging?:
            var c = "Charging"
            if let kw = v.chargePowerKw { c += String(format: " at %.1f kW", kw) }
            if let m = v.minutesToFullyCharged { c += ", full in \(duration(minutes: m))" }
            parts.append(c)
        case .pluggedIn?: parts.append("Plugged in, not charging")
        default: break
        }
        if let locked = v.details?.locked { parts.append(locked ? "Locked" : "Unlocked") }
        if v.climate == .running { parts.append("Climate on" + (v.targetTempC.map { " at \(Describe.temp($0))" } ?? "")) }
        if let alerts = v.details?.alerts, !alerts.isEmpty { parts.append(alerts.joined(separator: ". ")) }
        return parts.joined(separator: ". ") + "."
    }

    /// A confirmed command as a headline: "Climate on · 21.0 °C", "Locked", "Charging stopped".
    public static func confirmed(_ description: String) -> String {
        if description.hasPrefix("climatise to ") { return "Climate on · " + description.dropFirst("climatise to ".count) }
        switch description {
        case "stop climatisation": return "Climate off"
        case "lock the car": return "Locked"
        case "unlock the car": return "Unlocked"
        case "start charging": return "Charging started"
        case "stop charging": return "Charging stopped"
        default:
            if description.hasPrefix("set charge limits") { return "Charge limits set" }
            if description.hasPrefix("set off-peak charging to ") { return "Off-peak charging set to " + description.dropFirst("set off-peak charging to ".count) }
            if description.hasPrefix("send ") { return "Sent " + description.dropFirst("send ".count) }
            return description.capitalizingFirstLetter
        }
    }

    /// A command's description in plain words: "start climate at 21.0 °C", "stop climate", "lock the car".
    public static func request(_ description: String) -> String {
        if description.hasPrefix("climatise to ") { return "start climate at " + description.dropFirst("climatise to ".count) }
        if description == "stop climatisation" { return "stop climate" }
        return description
    }

    /// A status line fit for Siri or the Watch: no tick, and commands in plain words.
    public static func plain(_ message: String) -> String {
        var text = message
        if text.hasPrefix("✓ ") { text = String(text.dropFirst(2)) }
        text = text.replacingOccurrences(of: "climatise to ", with: "start climate at ")
        text = text.replacingOccurrences(of: "stop climatisation", with: "stop climate")
        return text.capitalizingFirstLetter
    }
}
