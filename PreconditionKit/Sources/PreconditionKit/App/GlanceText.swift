import Foundation

/// The short lines the widgets and the Watch show under the charge.
public enum GlanceText {
    /// What charging will do: "Charging · 80% by 06:10", "Smart charge 01:30–05:00 to 80%",
    /// "Charges 23:00–06:00 to 80%", or "Not plugged in".
    public static func chargePlan(_ s: VehicleSnapshot, smart: SmartChargePlan?, now: Date, calendar: Calendar = .current) -> String? {
        let limit = s.details?.chargeLimitAC
        let to = limit.map { " to \($0)%" } ?? ""
        if s.chargingState == .charging {
            if let minutes = s.minutesToFullyCharged, minutes > 0 {
                let done = now.addingTimeInterval(Double(minutes) * 60)
                return "Charging · \(limit.map { "\($0)% " } ?? "full ")by \(clock(done, calendar))"
            }
            return "Charging\(to)"
        }
        guard s.pluggedIn == true else { return "Not plugged in" }
        if let smart, smart.end > now {
            return "Smart charge \(clock(smart.start, calendar))–\(clock(smart.end, calendar)) to \(smart.targetPercent)%"
        }
        if let w = s.details?.offPeak { return "Charges \(w.text)\(to)" }
        return "Plugged in\(to)"
    }

    /// "today 21:00", "tomorrow 07:30", "Thu 07:30".
    public static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = clock(date, calendar)
        if calendar.isDate(date, inSameDayAs: now) { return "today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE"
        return "\(f.string(from: date)) \(time)"
    }

    /// The next scheduled rule: "Weekday warm-up · tomorrow 07:30".
    public static func nextRule(_ rules: [Rule], now: Date, clock lc: LocalClock, calendar: Calendar = .current) -> String? {
        let next = rules.compactMap { rule -> (Rule, Date)? in
            guard rule.enabled, case .schedule(let days, let time) = rule.trigger,
                  let at = ScheduleCalculator.next(days: days, time: time, after: now, clock: lc) else { return nil }
            return (rule, at)
        }
        .min { $0.1 < $1.1 }
        guard let (rule, at) = next else { return nil }
        return "\(rule.name) · \(when(at, now: now, calendar: calendar))"
    }

    static func clock(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
