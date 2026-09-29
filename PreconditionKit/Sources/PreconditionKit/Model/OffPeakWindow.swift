import Foundation

/// The car's off-peak charging window, as set in the Kia app (e.g. 23:00–06:00).
public struct OffPeakWindow: Codable, Equatable, Sendable {
    public var start: ClockTime
    public var end: ClockTime
    /// Charge only inside the window. Otherwise the car prefers it but still charges outside it
    /// when that's needed for a departure.
    public var onlyOffPeak: Bool

    public init(start: ClockTime, end: ClockTime, onlyOffPeak: Bool = false) {
        self.start = start
        self.end = end
        self.onlyOffPeak = onlyOffPeak
    }

    public var text: String { "\(start.text)–\(end.text)" }

    /// Kia writes times as 12-hour "hhmm" plus a section: 0 for AM, 1 for PM. "1100", 1 is 23:00.
    static func kiaTime(_ t: ClockTime) -> JSONValue {
        let h12 = t.hour % 12 == 0 ? 12 : t.hour % 12
        return ["time": .string(String(format: "%02d%02d", h12, t.minute)), "timeSection": .number(t.hour >= 12 ? 1 : 0)]
    }

    static func clockTime(_ json: JSONValue?) -> ClockTime? {
        guard let raw = json?["time"]?.str, raw.count == 4, let hhmm = Int(raw) else { return nil }
        let h = hhmm / 100, m = hhmm % 100
        guard h <= 23, m <= 59 else { return nil }
        let pm = json?["timeSection"]?.int == 1
        // Some cars send 24-hour times; only shift when it reads as 12-hour.
        let hour = h > 12 ? h : (h % 12) + (pm ? 12 : 0)
        return ClockTime(hour: hour, minute: m)
    }

    /// From `evStatus.reservChargeInfos` (older cars).
    static func parse(_ reservations: JSONValue?) -> OffPeakWindow? {
        guard let info = reservations?["offpeakPowerInfo"] ?? reservations?["offPeakPowerInfo"],
              let start = clockTime(info.path("offPeakPowerTime1.starttime")),
              let end = clockTime(info.path("offPeakPowerTime1.endtime"))
        else { return nil }
        return OffPeakWindow(start: start, end: end, onlyOffPeak: info["offPeakPowerFlag"]?.int == 2)
    }

    /// The body for `reservation/chargehvac`. Kia replaces the whole schedule, so the departures the car
    /// already has are sent back unchanged.
    static func requestBody(_ window: OffPeakWindow, current reservations: JSONValue?) -> JSONValue {
        let offPeak: JSONValue = [
            "offPeakPowerTime1": ["starttime": kiaTime(window.start), "endtime": kiaTime(window.end)],
            "offPeakPowerFlag": .number(window.onlyOffPeak ? 2 : 1),
        ]
        return [
            "reservChargeInfo1": reservations?["reservChargeInfo"] ?? reservations?["reservChargeInfo1"] ?? emptyDeparture,
            "reservChargeInfo2": reservations?["reserveChargeInfo2"] ?? reservations?["reservChargeInfo2"] ?? emptyDeparture,
            "reservFlag": .number(reservations?["reservFlag"]?.num ?? 0),
            "offPeakPowerInfo": offPeak,
        ]
    }

    /// A switched-off departure, for when the car didn't report one.
    static let emptyDeparture: JSONValue = [
        "reservChargeInfoDetail": [
            "reservInfo": ["day": [0], "time": ["time": "1200", "timeSection": 0]],
            "reservChargeSet": false,
            "reservFatcSet": [
                "defrost": false,
                "airTemp": ["value": "21.0", "unit": 0, "hvacTempType": 1],
                "airCtrl": 0,
                "heating1": 0,
            ],
        ],
    ]
}
