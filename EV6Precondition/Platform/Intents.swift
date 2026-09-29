import AppIntents
import PreconditionKit

/// Run by a Shortcuts "Time of Day" automation at each schedule rule's time (HANDOVER.md §5): iOS has no
/// exact background alarms, so this is how schedule rules run on time.
struct RunScheduledRulesIntent: AppIntent {
    static var title: LocalizedStringResource = "Run scheduled rules"
    static var description = IntentDescription("Runs the schedule rules in My EV6 that are due now. Add it to a Shortcuts Time of Day automation set to run immediately.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        await services.prepare()
        let outcomes = await services.rules.runDueSchedules()
        return .result(dialog: "\(Self.summary(outcomes))")
    }

    static func summary(_ outcomes: [EngineOutcome]) -> String {
        guard !outcomes.isEmpty else { return "No schedule rules are due right now." }
        return outcomes.map { outcome in
            switch outcome {
            case .fired(let rule, let action): return "\(rule.name): \(DisplayText.request(Describe.action(action))) sent."
            case .skipped(let reason): return "Skipped: \(reason)."
            case .failed(let error, _): return "Failed: \(error.message)."
            }
        }.joined(separator: " ")
    }
}

struct StartClimateIntent: AppIntent {
    static var title: LocalizedStringResource = "Start climate"
    static var description = IntentDescription("Starts your car's climate. If the car is plugged in but not charging, the charger is stopped first (when Keep charger off is on). The minimum-charge guard still applies.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Temperature (°C)")
    var temperature: Double?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        await services.prepare()
        await services.car.start(targetC: temperature)
        return .result(dialog: "\(Self.said(services.car.message))")
    }
}

struct CarStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Check my EV6"
    static var description = IntentDescription("Reads the car's latest state: charge, range, charging, locks, climate and any warnings. Uses one request.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        await services.prepare()
        await services.car.refresh()
        let failed = services.car.message?.hasPrefix("Couldn't refresh") == true
        guard let snapshot = services.car.snapshot else {
            return .result(dialog: "\(services.car.message.map(DisplayText.plain) ?? "No data from the car yet.")")
        }
        let status = DisplayText.spokenStatus(snapshot, miles: services.car.settings.useMiles)
        guard !failed else {
            let at = (snapshot.carCapturedAt ?? snapshot.fetchedAt).formatted(date: .omitted, time: .shortened)
            let text = "Couldn't reach the car. At \(at) it was: \(status)"
            return .result(dialog: "\(text)")
        }
        return .result(dialog: "\(status)")
    }
}

enum LockAction: String, AppEnum {
    case lock, unlock
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Lock action"
    static var caseDisplayRepresentations: [LockAction: DisplayRepresentation] = [.lock: "Lock", .unlock: "Unlock"]
}

struct LockCarIntent: AppIntent {
    static var title: LocalizedStringResource = "Lock or unlock my EV6"
    static var description = IntentDescription("Locks or unlocks the car's doors remotely.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Action", default: .lock)
    var action: LockAction

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if action == .unlock {
            try await requestConfirmation(result: .result(dialog: "Unlock the car?"))
        }
        let services = AppServices.shared
        await services.prepare()
        await services.car.send(action == .lock ? .lock : .unlock)
        return .result(dialog: "\(Self.said(services.car.message))")
    }
}

enum ChargeAction: String, AppEnum {
    case start, stop
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Charging action"
    static var caseDisplayRepresentations: [ChargeAction: DisplayRepresentation] = [.start: "Start", .stop: "Stop"]
}

struct ChargingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start or stop charging"
    static var description = IntentDescription("Starts or stops charging while the car is plugged in.")
    static var openAppWhenRun: Bool = false

    // No default: "Start charging" and "Stop charging" set it, and Siri asks otherwise.
    @Parameter(title: "Action")
    var action: ChargeAction

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        await services.prepare()
        await services.car.send(action == .start ? .startCharging : .stopCharging)
        return .result(dialog: "\(Self.said(services.car.message))")
    }
}

struct ChargeLimitIntent: AppIntent {
    static var title: LocalizedStringResource = "Set charge limit"
    static var description = IntentDescription("Sets where AC and DC charging stop, 50–100% in steps of 10.")
    static var openAppWhenRun: Bool = false

    // No default, so Siri asks rather than quietly setting 80%.
    @Parameter(title: "Limit (%)", inclusiveRange: (50, 100))
    var percent: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        await services.prepare()
        // The car takes steps of 10.
        let limit = min(100, max(50, Int((Double(percent) / 10).rounded()) * 10))
        await services.car.send(.setChargeLimits(ac: limit, dc: limit))
        return .result(dialog: "\(Self.said(services.car.message))")
    }
}

struct StopClimateIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop climate"
    static var description = IntentDescription("Stops your car's climate.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        await services.prepare()
        await services.car.stop()
        return .result(dialog: "\(Self.said(services.car.message))")
    }
}

extension AppIntent {
    /// The app's last message as Siri should say it.
    static func said(_ message: String?) -> String {
        message.map(DisplayText.plain) ?? "Done."
    }
}

struct EV6Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckCommuteIntent(),
            phrases: ["Check my commute with \(.applicationName)", "Which way home in \(.applicationName)"],
            shortTitle: "Check commute",
            systemImageName: "car.rear.road.lane"
        )
        AppShortcut(
            intent: StartClimateIntent(),
            phrases: ["Start climate with \(.applicationName)", "Warm up the car with \(.applicationName)", "Precondition my car with \(.applicationName)"],
            shortTitle: "Start climate",
            systemImageName: "thermometer.sun"
        )
        AppShortcut(
            intent: CarStatusIntent(),
            phrases: ["Check my car with \(.applicationName)", "How's my car in \(.applicationName)"],
            shortTitle: "Check my EV6",
            systemImageName: "car.side"
        )
        AppShortcut(
            intent: LockCarIntent(),
            phrases: ["\(\.$action) my car with \(.applicationName)", "Lock my car with \(.applicationName)"],
            shortTitle: "Lock or unlock",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: ChargingIntent(),
            phrases: ["\(\.$action) charging with \(.applicationName)"],
            shortTitle: "Start or stop charging",
            systemImageName: "bolt.car"
        )
        AppShortcut(
            intent: ChargeLimitIntent(),
            phrases: ["Set my charge limit with \(.applicationName)"],
            shortTitle: "Charge limit",
            systemImageName: "gauge.with.dots.needle.67percent"
        )
        AppShortcut(
            intent: StopClimateIntent(),
            phrases: ["Stop the car's climate with \(.applicationName)"],
            shortTitle: "Stop climate",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: RunScheduledRulesIntent(),
            phrases: ["Run scheduled rules with \(.applicationName)"],
            shortTitle: "Run scheduled rules",
            systemImageName: "calendar.badge.clock"
        )
    }
}

/// Checks traffic on a commute's routes and gives back the ETA message, for a Shortcuts automation to
/// send with Send Message.
struct CheckCommuteIntent: AppIntent {
    static var title: LocalizedStringResource = "Check my commute"
    static var description = IntentDescription("Checks traffic on your commute's routes, picks the way to go, notifies you, and gives back your ETA message. Follow it with Send Message to text it.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Commute", description: "Its name in the app, e.g. Home. Leave empty for the first one.")
    var commute: String?

    @Parameter(title: "Notify me", default: true)
    var notify: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let services = AppServices.shared
        await services.prepare()
        guard let chosen = services.commute.commute(named: commute) else {
            return .result(value: "", dialog: "Add a commute in My EV6 first: Trips, then Set up a commute.")
        }
        let advice = await services.commute.check(chosen.id)
        let text = services.commute.message(for: chosen.id) { $0.formatted(date: .omitted, time: .shortened) } ?? ""
        let headline = advice?.headline ?? "Couldn't check the traffic."
        let arrival = advice?.arrival.map { "Arrive \($0.formatted(date: .omitted, time: .shortened))" }
        if notify {
            await services.notifier.note(title: [chosen.name, arrival].compactMap { $0 }.joined(separator: " · "), text: headline)
        }
        return .result(value: text, dialog: "\([headline, arrival.map { $0 + "." }].compactMap { $0 }.joined(separator: " "))")
    }
}
