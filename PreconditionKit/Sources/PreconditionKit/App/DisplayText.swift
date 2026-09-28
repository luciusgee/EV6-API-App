import Foundation

/// Short texts the screens show, kept here so they're tested.
public enum DisplayText {
    /// The dashboard's budget line: "80 left of 80 · 72 for automation · 8 kept for you · resets 17:10".
    public static func budget(_ b: BudgetSnapshot, timeZone: TimeZone = .current) -> String {
        if let until = b.exhaustedUntil {
            return "Kia's request limit reached · try again at \(clock(until, timeZone))"
        }
        var parts = [
            "\(b.remaining) left of \(b.limit)",
            "\(b.automationAvailable) for automation",
            "\(b.manualReserve) kept for you",
        ]
        if let reset = b.resetAt { parts.append("resets \(clock(reset, timeZone))") }
        return parts.joined(separator: " · ")
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
}
