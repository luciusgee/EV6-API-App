import Foundation

/// A suggestion learned from how the car is used. Everything is worked out on the phone from the log.
public struct Suggestion: Identifiable, Equatable, Sendable {
    public enum Fix: Equatable, Sendable {
        case addRule(Rule)
        case holdCharger
    }

    public var id: String
    public var title: String
    public var detail: String
    public var systemImage: String
    public var fix: Fix?
}

public enum Insights {
    /// How far back habits are looked for.
    public static let lookback: TimeInterval = 28 * 24 * 3600
    /// Starts within this many minutes of each other count as the same habit.
    public static let habitWindowMinutes = 20
    /// Climate takes about this long to warm the cabin, so the rule fires this much earlier.
    public static let leadMinutes = 15

    public static func suggestions(
        log: [LogEntry], rules: [Rule], settings: AppSettings, energy: DrivingHistory? = nil,
        now: Date, clock: LocalClock
    ) -> [Suggestion] {
        var out: [Suggestion] = []
        out += habits(log: log, rules: rules, now: now, clock: clock)
        if !settings.holdChargerOnClimate, climateStarts(log: log, now: now) > 0 {
            out.append(Suggestion(
                id: "hold-charger",
                title: "Keep the charger off when preconditioning",
                detail: "When the car is plugged in but idle, preconditioning wakes the charger. Turning this on stops the charger first, so a finished or off-peak charge isn't restarted at peak rates.",
                systemImage: "powerplug",
                fix: .holdCharger
            ))
        }
        if let share = energy?.climateShare, share > 0.2, !rules.contains(where: { $0.enabled }) {
            out.append(Suggestion(
                id: "climate-share",
                title: "Climate used \(Int((share * 100).rounded()))% of your energy",
                detail: "Preconditioning on a schedule while plugged in warms the car from the grid instead of the battery.",
                systemImage: "leaf",
                fix: nil
            ))
        }
        return out
    }

    /// Manual climate starts at a similar time on several days become a scheduled rule.
    static func habits(log: [LogEntry], rules: [Rule], now: Date, clock: LocalClock) -> [Suggestion] {
        struct Start { let day: CalendarDay; let weekday: Weekday; let minutes: Int; let target: Double }
        let starts: [Start] = log.compactMap { e in
            guard e.kind == .manual, e.decision == "sent", now.timeIntervalSince(e.at) <= lookback, e.at <= now,
                  let target = targetC(in: e.reason)
            else { return nil }
            return Start(day: clock.day(e.at), weekday: clock.weekday(e.at), minutes: clock.timeOfDay(e.at).minutesSinceMidnight, target: target)
        }
        var out: [Suggestion] = []
        for (days, label) in [(Weekday.weekdays, "weekdays"), (Weekday.weekend, "weekends")] {
            let group = starts.filter { days.contains($0.weekday) }
            // The densest cluster: most distinct days within the window of one start.
            var best: [Start] = []
            for s in group {
                let near = group.filter { abs($0.minutes - s.minutes) <= habitWindowMinutes }
                var seen = Set<CalendarDay>()
                let distinct = near.filter { seen.insert($0.day).inserted }
                if distinct.count > best.count { best = distinct }
            }
            guard best.count >= 3 else { continue }
            let minutes = best.map(\.minutes).sorted()
            let median = minutes[minutes.count / 2]
            var fire = max(median - leadMinutes, 0)
            fire -= fire % 5
            let time = TimeOfDay(fire / 60, fire % 60)
            let covered = rules.contains { rule in
                guard rule.enabled, case .schedule(let d, let t) = rule.trigger else { return false }
                return !d.isDisjoint(with: days) && abs(t.minutesSinceMidnight - median) <= 45
            }
            if covered { continue }
            let targets = best.map(\.target).sorted()
            let target = targets[targets.count / 2]
            let medianTime = TimeOfDay(median / 60, median % 60)
            let rule = Rule(
                id: Templates.newId(),
                name: label == "weekdays" ? "Weekday routine" : "Weekend routine",
                trigger: .schedule(days: days, time: time),
                conditions: [.tempBelow(celsius: 10, source: .forecastAt(medianTime))],
                action: .startClimate(targetC: target)
            )
            out.append(Suggestion(
                id: "habit-\(label)",
                title: "You start climate around \(Describe.time(medianTime)) on \(label)",
                detail: "\(best.count) times in the last 4 weeks. Do it automatically at \(Describe.time(time)) when it's below 10 °C, so the car's ready when you are?",
                systemImage: "sparkles",
                fix: .addRule(rule)
            ))
        }
        return out
    }

    static func climateStarts(log: [LogEntry], now: Date) -> Int {
        log.filter { [.manual, .command].contains($0.kind) && now.timeIntervalSince($0.at) <= lookback && targetC(in: $0.reason) != nil }.count
    }

    /// "climatise to 21.5 °C accepted" → 21.5.
    static func targetC(in reason: String) -> Double? {
        guard reason.hasPrefix("climatise to "), let end = reason.range(of: " °C") else { return nil }
        return Double(reason[reason.index(reason.startIndex, offsetBy: 13)..<end.lowerBound])
    }
}
