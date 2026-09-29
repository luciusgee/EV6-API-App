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

    static let preview = CarGlance(
        socPercent: 62, rangeText: "151 mi", charging: false, pluggedIn: false, locked: true,
        climateOn: false, targetText: "21.0 °C", chargeLimit: 80, minutesToFull: nil,
        carReportedAt: Date(), fetchedAt: Date(), status: nil
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
