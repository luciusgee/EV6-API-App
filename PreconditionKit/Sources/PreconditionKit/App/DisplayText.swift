import Foundation

/// Words and numbers as the app shows them.
public enum DisplayText {
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

    /// "132 kW" for rapid charging, "7.2 kW" at home.
    public static func kW(_ kw: Double) -> String {
        abs(kw) >= 20 ? "\(Int(kw.rounded())) kW" : String(format: "%.1f kW", kw)
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

    /// "60 mph" or "97 km/h".
    public static func speed(kmh: Double, miles: Bool) -> String {
        miles ? "\(Int((kmh / kmPerMile).rounded())) mph" : "\(Int(kmh.rounded())) km/h"
    }

    /// "402 m" or "1,320 ft" for short distances.
    public static func shortDistance(metres: Double, miles: Bool) -> String {
        miles ? "\(Int((metres / 0.3048).rounded())) ft" : "\(Int(metres.rounded())) m"
    }

    /// "4.21 s", "1:32.48" for laps.
    public static func seconds(_ s: Double) -> String {
        guard s >= 60 else { return String(format: "%.2f s", s) }
        let m = Int(s / 60)
        return String(format: "%d:%05.2f", m, s - Double(m) * 60)
    }

    /// "12.4 kWh", "850 Wh".
    public static func energy(wh: Double) -> String {
        abs(wh) >= 1000 ? String(format: "%.1f kWh", wh / 1000) : "\(Int(wh.rounded())) Wh"
    }
}
