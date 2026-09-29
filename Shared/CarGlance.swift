import Foundation

/// What the widgets and the Watch show: a small copy of the car's last known state, written by the app
/// whenever it changes. The widgets and the Watch never talk to Kia themselves.
struct CarGlance: Codable, Equatable, Sendable {
    var socPercent: Int?
    /// Already in the owner's units, e.g. "151 mi".
    var rangeText: String?
    var charging: Bool
    var pluggedIn: Bool
    var locked: Bool?
    var climateOn: Bool
    /// e.g. "21.0 °C".
    var targetText: String?
    var chargeLimit: Int?
    var minutesToFull: Int?
    /// When the car last reported this state.
    var carReportedAt: Date?
    /// When the app last read it from Kia.
    var fetchedAt: Date
    /// The latest one-line result, e.g. "Climate on, confirmed by the car".
    var status: String?
    /// A command or refresh in progress.
    var busy: Bool = false
    /// What charging will do, e.g. "Charges 23:00–06:00 to 80%".
    var plan: String? = nil
    /// The next scheduled rule, e.g. "Weekday warm-up · tomorrow 07:30".
    var next: String? = nil
    /// Sent, and waiting for the car to confirm (nil in glances saved by older builds).
    var waitingForCar: Bool? = nil

    static let preview = CarGlance(
        socPercent: 62, rangeText: "151 mi", charging: false, pluggedIn: false, locked: true,
        climateOn: false, targetText: "21.0 °C", chargeLimit: 80, minutesToFull: nil,
        carReportedAt: Date(), fetchedAt: Date(), status: nil,
        plan: "Charges 23:00–06:00 to 80%", next: "Weekday warm-up · tomorrow 07:30"
    )

    /// "Locked · Climate off" style summary.
    var summary: String {
        var parts: [String] = []
        if charging {
            parts.append("Charging")
        } else if pluggedIn {
            parts.append("Plugged in")
        }
        if let locked { parts.append(locked ? "Locked" : "Unlocked") }
        parts.append(climateOn ? "Climate on" : "Climate off")
        return parts.joined(separator: " · ")
    }

    /// When the car last reported this, else when the app last read it.
    var reportedAt: Date { carReportedAt ?? fetchedAt }

    /// Older than this, the widgets and the Watch say how old the data is.
    static let staleAfter: TimeInterval = 3600

    func isStale(at now: Date) -> Bool { now.timeIntervalSince(reportedAt) > Self.staleAfter }

    /// "Updated 14:05", "Updated yesterday 21:30", "Updated Thu 07:30". A fixed time rather than a
    /// ticking "… ago", which runs long and changes every second.
    func updatedText(now: Date) -> String { "Updated " + Self.when(reportedAt, now: now) }

    /// What a busy glance is doing.
    var busyText: String { waitingForCar == true ? "Waiting for the car…" : "Updating…" }

    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time)"
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = now.timeIntervalSince(date) < 6 * 86400 ? "EEE" : "d MMM"
        return "\(f.string(from: date)) \(time)"
    }
}

/// Commands the Watch (and widget links) can ask the app to send.
enum GlanceCommand: String, Codable, Sendable, CaseIterable {
    case refresh, climateStart, climateStop, lock, unlock, chargeStart, chargeStop

    /// ev6://command/climateStart
    var url: URL { URL(string: "ev6://command/\(rawValue)")! }

    init?(url: URL) {
        guard url.scheme == "ev6", url.host == "command" else { return nil }
        self.init(rawValue: url.lastPathComponent)
    }
}
