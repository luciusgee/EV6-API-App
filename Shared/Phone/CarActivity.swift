import ActivityKit
import Foundation

/// A Live Activity on the Lock Screen and in the Dynamic Island while the car is warming up or
/// cooling down, or charging. Started and updated by the app from what it reads from Kia.
struct CarActivityAttributes: ActivityAttributes {
    enum Kind: String, Codable, Hashable {
        case climate, charging
    }

    struct ContentState: Codable, Hashable {
        var socPercent: Int?
        var rangeText: String?
        /// "Climate on · 21.0 °C", "Charging to 80%".
        var title: String
        /// "Confirmed by the car", "7.2 kW".
        var detail: String?
        var startedAt: Date
        /// When climate stops or charging should finish.
        var endsAt: Date?
        /// When the car reported this (charging); nil for climate.
        var updatedAt: Date? = nil
    }

    var kind: Kind
}
