import Foundation

/// Roughly what the charge will be when the off-peak window ends.
public enum OffPeakForecast {
    /// Wall energy that reaches the battery on a home charger.
    static let efficiency = 0.9

    /// The window you're in, or the next one: its start and end.
    public static func window(_ w: OffPeakWindow, now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        func at(_ t: ClockTime, dayOffset: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day) ?? day
        }
        let crossesMidnight = w.end.minutes <= w.start.minutes
        if crossesMidnight {
            // 23:00–06:00: before 06:00 we're in last night's window.
            let endToday = at(w.end, dayOffset: 0)
            if now < endToday { return (at(w.start, dayOffset: -1), endToday) }
            return (at(w.start, dayOffset: 0), at(w.end, dayOffset: 1))
        }
        let endToday = at(w.end, dayOffset: 0)
        if now < endToday { return (at(w.start, dayOffset: 0), endToday) }
        return (at(w.start, dayOffset: 1), at(w.end, dayOffset: 1))
    }

    public struct Estimate: Equatable, Sendable {
        public var at: Date
        public var percent: Int
        /// It reaches the car's charge limit before then.
        public var reachesLimit: Bool
        /// Roughly when it gets to the limit, when it does.
        public var doneAt: Date?
    }

    /// The charge at the end of the window, for a car that's plugged in. Charging now: from the car's
    /// own time-to-full when it gives one, else its charging speed. Waiting for the window: from
    /// `chargerKW` starting when the window opens.
    public static func estimate(_ s: VehicleSnapshot, window w: OffPeakWindow, now: Date, chargerKW: Double, usableKWh: Double,
                                calendar: Calendar = .current) -> Estimate? {
        guard s.pluggedIn == true, let soc = s.socPercent, usableKWh > 0 else { return nil }
        let limit = s.details?.chargeLimitAC ?? 100
        let (start, end) = window(w, now: now, calendar: calendar)
        guard soc < limit else { return Estimate(at: end, percent: soc, reachesLimit: true, doneAt: nil) }
        let reported = s.carCapturedAt ?? s.fetchedAt
        let charging = s.chargingState == .charging

        if charging, let minutes = s.minutesToFullyCharged, minutes > 0 {
            let done = reported.addingTimeInterval(Double(minutes) * 60)
            if done <= end { return Estimate(at: end, percent: limit, reachesLimit: true, doneAt: done) }
            let share = end.timeIntervalSince(reported) / done.timeIntervalSince(reported)
            return Estimate(at: end, percent: soc + Int((Double(limit - soc) * share).rounded(.down)), reachesLimit: false, doneAt: nil)
        }

        let kW = charging ? (s.chargePowerKw ?? chargerKW) : chargerKW
        let from = charging ? max(reported, now) : max(start, now)
        let hours = max(0, end.timeIntervalSince(from) / 3600)
        let added = kW * hours * efficiency / usableKWh * 100
        let percent = min(limit, soc + Int(added.rounded(.down)))
        let neededHours = Double(limit - soc) / 100 * usableKWh / efficiency / max(kW, 0.1)
        let doneAt = from.addingTimeInterval(neededHours * 3600)
        return Estimate(at: end, percent: percent, reachesLimit: percent >= limit, doneAt: doneAt <= end ? doneAt : nil)
    }
}
