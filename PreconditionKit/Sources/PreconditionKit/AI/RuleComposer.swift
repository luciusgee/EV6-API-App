import Foundation

/// Turns a sentence into a rule, on the device: "weekdays at 7:30 heat to 22 if it's below 5",
/// "when I leave work after 5pm and it's freezing, warm the car", "cool to 19 when I get home if it's
/// over 25". Apple Intelligence (where available) first rewrites looser wording into this form.
public enum RuleComposer {
    public struct Result: Equatable, Sendable {
        /// Nil when the sentence doesn't say when.
        public var rule: Rule?
        /// What was understood, one short line each, for the confirmation screen.
        public var understood: [String]
        /// Place names in the sentence that don't match a saved place.
        public var unknownPlaces: [String]
        public var problems: [String]
    }

    /// Words people use for their places, beyond the names they gave them.
    static let placeAliases: [String: [String]] = [
        "work": ["office", "work", "job", "workplace"],
        "office": ["office", "work"],
        "home": ["home", "house"],
        "gym": ["gym"],
        "school": ["school"],
    ]

    public static func compose(_ sentence: String, places: [Place], defaultTargetC: Double = 21) -> Result {
        var text = " " + sentence.lowercased()
            .replacingOccurrences(of: "°c", with: "°")
            .replacingOccurrences(of: "º", with: "°")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\n", with: " ") + " "
        var understood: [String] = []
        var conditions: [Condition] = []
        var problems: [String] = []
        var unknownPlaces: [String] = []

        // Time windows first, so their times aren't read as the trigger's.
        var window: (TimeOfDay, TimeOfDay)?
        if let m = first(#"between\s+(\S+(?:\s*[ap]\.?m\.?)?)\s+and\s+(\S+(?:\s*[ap]\.?m\.?)?)"#, in: text),
           let a = time(m[1]), let b = time(m[2]) {
            window = (a, b)
            text = remove(m[0], from: text)
        } else if let m = first(#"\bafter\s+(\d{1,2}(?:[:.]\d{2})?\s*(?:[ap]\.?m\.?)?)"#, in: text), let a = time(m[1]) {
            window = (a, TimeOfDay(23, 59))
            text = remove(m[0], from: text)
        } else if let m = first(#"\bbefore\s+(\d{1,2}(?:[:.]\d{2})?\s*(?:[ap]\.?m\.?)?)"#, in: text), let b = time(m[1]) {
            window = (TimeOfDay(0, 0), b)
            text = remove(m[0], from: text)
        }

        // Charge level: "battery above 40%", "at least 50% charge".
        if let m = first(#"(\d{1,3})\s*%"#, in: text), let p = Int(m[1]), (0...100).contains(p) {
            conditions.append(.socAtLeast(percent: p))
            understood.append("battery at least \(p)%")
            text = remove(m[0], from: text)
        }

        // Temperature conditions, before the target so "below 5" isn't read as "5 degrees".
        var coldOrHot: Condition?
        let belowWords = #"(?:below|under|colder than|less than|lower than|<)"#
        let aboveWords = #"(?:above|over|warmer than|hotter than|more than|higher than|>)"#
        if let m = first(#"\b\#(belowWords)\s*(-?\d{1,2}(?:\.\d)?)\s*(?:°|degrees?|deg)?"#, in: text), let t = Double(m[1]) {
            coldOrHot = .tempBelow(celsius: t, source: .bestAvailable)
            text = remove(m[0], from: text)
        } else if let m = first(#"\b\#(aboveWords)\s*(-?\d{1,2}(?:\.\d)?)\s*(?:°|degrees?|deg)?"#, in: text), let t = Double(m[1]) {
            coldOrHot = .tempAbove(celsius: t, source: .bestAvailable)
            text = remove(m[0], from: text)
        } else if contains(#"\b(freezing|frosty|icy|frost)\b"#, in: text) {
            coldOrHot = .tempBelow(celsius: 3, source: .bestAvailable)
        } else if contains(#"\b(cold|chilly|cool outside)\b"#, in: text) {
            coldOrHot = .tempBelow(celsius: 8, source: .bestAvailable)
        } else if contains(#"\b(hot|heatwave|boiling|scorching)\b"#, in: text) {
            coldOrHot = .tempAbove(celsius: 24, source: .bestAvailable)
        }

        // Action.
        let action: RuleAction
        let cooling = contains(#"\b(cool|cooling|air ?con|a/?c)\b"#, in: text) || { if case .tempAbove? = coldOrHot { return true }; return false }()
        if contains(#"\b(stop|turn off|switch off|cancel)\b"#, in: text) {
            action = .stopClimate
        } else if let m = first(#"(?:\bto\b|\bat\b)?\s*(\d{2}(?:\.[05])?)\s*(?:°|degrees?|deg)"#, in: text) ?? first(#"\b(?:heat|warm|cool|climatise|climatize|precondition|set)\w*(?:\s+\w+){0,3}?\s+to\s+(\d{2}(?:\.[05])?)\b"#, in: text),
                  let t = Double(m[1]), (14...32).contains(t) {
            action = .startClimate(targetC: t)
            text = remove(m[0], from: text)
        } else {
            action = .startClimate(targetC: cooling ? 20 : defaultTargetC)
        }

        // Days.
        var days: Set<Weekday>?
        if contains(#"\b(weekdays?|work ?days?|mon(day)?\s*(-|–|to|through)\s*fri(day)?)\b"#, in: text) {
            days = Weekday.weekdays
        } else if contains(#"\b(weekends?|sat(urday)?\s*(and|&)\s*sun(day)?)\b"#, in: text) {
            days = Weekday.weekend
        } else if contains(#"\b(every ?day|daily|each day|every morning|every evening|every night)\b"#, in: text) {
            days = Weekday.everyDay
        } else {
            let names: [(String, Weekday)] = [
                ("mon", .monday), ("tue", .tuesday), ("wed", .wednesday), ("thu", .thursday), ("fri", .friday), ("sat", .saturday), ("sun", .sunday),
            ]
            var found = Set<Weekday>()
            for (prefix, day) in names where contains(#"\b\#(prefix)[a-z]*\b"#, in: text) { found.insert(day) }
            if !found.isEmpty { days = found }
        }
        if let m = first(#"\bexcept\s+(?:on\s+)?([a-z]+)"#, in: text), let d = Weekday.allCases.first(where: { m[1].hasPrefix($0.rawValue.lowercased()) }) {
            days = (days ?? Weekday.everyDay).subtracting([d])
        }

        // Trigger: a place, the car, or a time.
        var trigger: Trigger?
        var placeName: String?
        func resolve(_ word: String) -> Place? {
            let aliases = placeAliases[word] ?? [word]
            return places.first { p in
                let name = p.name.lowercased()
                return name == word || aliases.contains(name) || aliases.contains { name.contains($0) }
            }
        }
        let placeWord = #"(?:the\s+|my\s+)?([a-z][a-z'-]+)"#
        if let m = first(#"\b(?:leave|leaving|leaves|left|finish(?:ing)? at|head(?:ing)? out of)\s+\#(placeWord)"#, in: text) {
            placeName = m[1]
            if let p = resolve(m[1]) { trigger = .geofenceExit(placeId: p.id); placeName = p.name } else { unknownPlaces.append(m[1]) }
        } else if let m = first(#"\b(?:on (?:my|the) way|heading|driving|going)\s+(?:to\s+)?\#(placeWord)"#, in: text) {
            placeName = m[1]
            if let p = resolve(m[1]) { trigger = .approaching(placeId: p.id, km: 5); placeName = p.name } else { unknownPlaces.append(m[1]) }
        } else if let m = first(#"\b(?:arrive|arriving|arrives|get|getting|reach|reaching)\s+(?:at\s+|to\s+|back\s+)?\#(placeWord)"#, in: text) {
            placeName = m[1]
            if let p = resolve(m[1]) { trigger = .geofenceEnter(placeId: p.id); placeName = p.name } else { unknownPlaces.append(m[1]) }
        }
        let nearCar = contains(#"\b(near|approach\w*|walk\w* (to|towards)|close to|next to)\s+(the\s+|my\s+)?car\b"#, in: text)
        var scheduleTime: TimeOfDay?
        if trigger == nil && unknownPlaces.isEmpty {
            if nearCar {
                trigger = .nearCar(meters: 300)
            } else if let t = firstTime(in: text) {
                scheduleTime = t
                trigger = .schedule(days: days ?? Weekday.everyDay, time: t)
            }
        }

        switch trigger {
        case .schedule(let d, let t)?:
            understood.append("\(Describe.days(d).capitalizingFirstLetter) at \(Describe.time(t))")
        case let t?:
            understood.append(Describe.trigger(t) { _ in placeName ?? "?" }.capitalizingFirstLetter)
            if let days, days != Weekday.everyDay {
                conditions.insert(.daysOfWeek(days), at: 0)
                understood.append(Describe.days(days))
            }
        case nil:
            if unknownPlaces.isEmpty {
                problems.append("Say when: a time (\"at 7:30\"), leaving or arriving somewhere (\"when I leave work\"), or walking to the car.")
            } else {
                problems.append("No saved place called \(unknownPlaces.map { "“\($0)”" }.joined(separator: ", ")). Add it under Places first.")
            }
        }
        if let window {
            conditions.append(.timeWindow(start: window.0, end: window.1))
            understood.append("between \(Describe.time(window.0)) and \(Describe.time(window.1))")
        }
        if var c = coldOrHot {
            // For a schedule, the forecast for shortly after it fires is what matters.
            if let t = scheduleTime {
                let m = min(t.minutesSinceMidnight + 20, 23 * 60 + 59)
                let at = TimeOfDay(m / 60, m % 60)
                switch c {
                case .tempBelow(let v, _): c = .tempBelow(celsius: v, source: .forecastAt(at))
                case .tempAbove(let v, _): c = .tempAbove(celsius: v, source: .forecastAt(at))
                default: break
                }
            }
            conditions.append(c)
            understood.append(Describe.condition(c) { $0 })
        }
        if contains(#"\b(plugged in|on charge|charging|connected)\b"#, in: text) && !contains(#"\b(not|isn't|unplugged)\b"#, in: text) {
            conditions.append(.pluggedIn(expected: true))
            understood.append("plugged in")
        }
        if nearCar, trigger.map({ if case .nearCar = $0 { return false }; return true }) == true {
            conditions.append(.phoneNearCar(meters: 1500))
            understood.append("you're near the car")
        }
        understood.append(Describe.action(action))

        guard let trigger else {
            return Result(rule: nil, understood: understood, unknownPlaces: unknownPlaces, problems: problems)
        }
        let rule = Rule(
            id: Templates.newId(),
            name: name(trigger: trigger, place: placeName, action: action),
            trigger: trigger,
            conditions: conditions,
            action: action
        )
        return Result(rule: rule, understood: understood, unknownPlaces: unknownPlaces, problems: problems)
    }

    static func name(trigger: Trigger, place: String?, action: RuleAction) -> String {
        let verb: String
        switch action {
        case .stopClimate: verb = "Stop climate"
        case .startClimate(let t): verb = t <= 20 ? "Cool" : "Warm up"
        }
        switch trigger {
        case .schedule(let days, let time):
            let when = time.hour < 12 ? "morning" : (time.hour < 17 ? "afternoon" : "evening")
            let d = days == Weekday.weekdays ? "Weekday" : (days == Weekday.weekend ? "Weekend" : "Daily")
            return days == Weekday.everyDay || days == Weekday.weekdays || days == Weekday.weekend ? "\(d) \(when)" : "\(verb) at \(time)"
        case .geofenceExit: return "Leaving \(place ?? "")".trimmingCharacters(in: .whitespaces)
        case .geofenceEnter: return "\(verb) at \(place ?? "")".trimmingCharacters(in: .whitespaces)
        case .approaching: return "Heading to \(place ?? "")".trimmingCharacters(in: .whitespaces)
        case .nearCar: return "\(verb) as I walk up"
        }
    }

    // MARK: Times

    static func firstTime(in text: String) -> TimeOfDay? {
        if contains(#"\bnoon\b|\bmidday\b"#, in: text) { return .noon }
        if let m = first(#"\b(\d{1,2})[:.](\d{2})\s*([ap])\.?m\.?\b"#, in: text) ?? first(#"\b(\d{1,2})[:.](\d{2})\b"#, in: text) ?? first(#"\b(\d{1,2})()\s*([ap])\.?m\.?\b"#, in: text) {
            return time(parts: m)
        }
        if let m = first(#"\bhalf\s+(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d{1,2})\b"#, in: text) {
            let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
            let h = words.firstIndex(of: m[1]).map { $0 + 1 } ?? Int(m[1]) ?? 0
            // "Half seven" is 7:30; before 6 it's probably the evening.
            let hour = h < 6 ? h + 12 : h
            return (0...23).contains(hour) ? TimeOfDay(hour, 30) : nil
        }
        return nil
    }

    static func time(_ text: String) -> TimeOfDay? {
        let t = " " + text.trimmingCharacters(in: .whitespaces) + " "
        if let m = first(#"(\d{1,2})[:.](\d{2})\s*([ap])?"#, in: t) ?? first(#"(\d{1,2})()\s*([ap])?"#, in: t) {
            return time(parts: m)
        }
        return nil
    }

    private static func time(parts m: [String]) -> TimeOfDay? {
        guard var h = Int(m[1]) else { return nil }
        let minute = Int(m[2]) ?? 0
        let meridiem = m.count > 3 ? m[3] : ""
        if meridiem == "p" && h < 12 { h += 12 }
        if meridiem == "a" && h == 12 { h = 0 }
        guard (0...23).contains(h), (0...59).contains(minute) else { return nil }
        return TimeOfDay(h, minute)
    }

    // MARK: Regex helpers

    static func first(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            let r = match.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    static func contains(_ pattern: String, in text: String) -> Bool { first(pattern, in: text) != nil }

    static func remove(_ fragment: String, from text: String) -> String {
        guard let r = text.range(of: fragment) else { return text }
        return text.replacingCharacters(in: r, with: " ")
    }

    /// For Apple Intelligence: how to rewrite a request so `compose` understands it.
    public static let rewriteInstructions = """
    You turn a driver's request about their electric car's climate into one short instruction. \
    Use only these parts, in this order, and leave out anything the driver didn't say:
    - when: "weekdays at 7:30", "every day at 18:00", "when I leave <place>", "when I arrive at <place>", "when I walk to the car"
    - optional time window: "between 16:00 and 19:00"
    - optional temperature condition: "if below 5 degrees" or "if above 24 degrees"
    - optional: "if plugged in", "if battery above 40%"
    - action: "heat to 21 degrees", "cool to 19 degrees" or "stop climate"
    Use 24-hour times. Use the driver's place names exactly. Answer with the instruction only.
    Example: "warm it up for my commute when it's frosty, I leave at half 7 on workdays" → \
    "weekdays at 7:15 if below 3 degrees heat to 21 degrees"
    """
}

extension String {
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
