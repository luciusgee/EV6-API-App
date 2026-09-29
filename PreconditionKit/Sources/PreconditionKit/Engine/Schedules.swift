import Foundation

extension PreconditionEngine {
    /// A Shortcuts run may start a little early or late: rules due up to 2 min from now, or up to 10 min
    /// ago, count as due (HANDOVER.md §5).
    public static let scheduleEarly: TimeInterval = 2 * 60
    public static let scheduleLate: TimeInterval = 10 * 60

    /// Runs the schedule rules that are due now. iOS has no exact background alarms, so a Shortcuts
    /// personal automation ("Time of Day", run immediately) calls this through an App Intent at each
    /// rule's time. Each rule runs at most once per day, however often the automation fires.
    @discardableResult
    public func runDueSchedules() async -> [EngineOutcome] {
        let now = time.now()
        let clock = localClock()
        let allRules = await rulesStore.rules()

        var dueTimes: [TimeOfDay] = []
        var keys: [String] = []
        let st = await state.load()
        // "Ask first" schedule rules ask from notifications booked in advance, not from here.
        for rule in allRules where rule.enabled && !rule.askFirst {
            guard case .schedule(let days, let t) = rule.trigger else { continue }
            let at = clock.date(t, sameDayAs: now)
            guard at >= now.addingTimeInterval(-Self.scheduleLate), at <= now.addingTimeInterval(Self.scheduleEarly),
                  days.contains(clock.weekday(at)) else { continue }
            let key = "schedule:\(rule.id):\(clock.day(at))"
            if st.lastTriggerAt[key] != nil { continue }
            keys.append(key)
            if !dueTimes.contains(t) { dueTimes.append(t) }
        }

        let cutoff = now.addingTimeInterval(-2 * 86400)
        let recorded = keys
        await state.update { s in
            for key in recorded { s.lastTriggerAt[key] = now }
            s.lastTriggerAt = s.lastTriggerAt.filter { $0.value >= cutoff }
        }

        if dueTimes.isEmpty {
            await log.append(LogEntry(at: now, kind: .info, decision: "schedule check", reason: "no schedule rules due at \(Describe.time(clock.timeOfDay(now)))"))
            return []
        }
        var outcomes: [EngineOutcome] = []
        for t in dueTimes.sorted() {
            outcomes.append(await onTrigger(.scheduleFired(time: t), triggeredAt: now))
        }
        return outcomes
    }

    /// When the dashboard's "Next scheduled check" is.
    public func nextScheduledCheck() async -> ScheduledCheck? {
        ScheduleCalculator.nextCheck(await rulesStore.rules(), after: time.now(), clock: localClock())
    }
}
