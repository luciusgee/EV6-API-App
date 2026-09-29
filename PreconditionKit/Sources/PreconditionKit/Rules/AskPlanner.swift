import Foundation

/// When "ask first" schedule rules should ask, and what the question says. The app books the
/// notifications ahead with iOS, which delivers them on time even with the app closed; the weather
/// part of a rule is checked against the forecast whenever the app gets to run before then.
public enum AskPlanner {
    public struct Slot: Equatable, Sendable {
        public var ruleId: String
        public var at: Date
        /// "ask-<rule>-<yyyy-mm-dd>", so a day's ask can be replaced or removed.
        public var id: String
    }

    /// The next `days` days of asks for enabled "ask first" schedule rules, soonest first.
    public static func upcoming(_ rules: [Rule], after now: Date, days: Int = 7, clock: LocalClock) -> [Slot] {
        var out: [Slot] = []
        for rule in rules where rule.enabled && rule.askFirst {
            guard case .schedule(let weekdays, let t) = rule.trigger else { continue }
            for offset in 0...days {
                let at = clock.date(t, sameDayAs: now, daysLater: offset)
                guard at > now, weekdays.contains(clock.weekday(at)) else { continue }
                out.append(Slot(ruleId: rule.id, at: at, id: "ask-\(rule.id)-\(clock.day(at))"))
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    /// Whether the forecast rules the ask out: a temperature condition that the forecast fails.
    /// Unknown forecasts never rule anything out.
    public static func forecastRulesOut(_ rule: Rule, forecastC: Double?) -> Bool {
        guard let t = forecastC else { return false }
        for condition in rule.conditions {
            switch condition {
            case .tempBelow(let c, _): if !(t < c) { return true }
            case .tempAbove(let c, _): if !(t > c) { return true }
            case .tempOutside(let low, let high, _): if t >= low && t <= high { return true }
            default: continue
            }
        }
        return false
    }

    public static func title(_ rule: Rule) -> String {
        switch rule.action {
        case .startClimate(let target): return "\(rule.name): start climate to \(Describe.temp(target))?"
        case .stopClimate: return "\(rule.name): stop climate?"
        }
    }

    public static func text(_ rule: Rule, outsideC: Double?) -> String {
        let weather = outsideC.map { "It's about \(Describe.temp($0)) out. " } ?? ""
        return weather + "Hold for Start, In 15 min or Not today."
    }
}
