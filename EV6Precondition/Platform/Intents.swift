import AppIntents
import PreconditionKit

/// Run by a Shortcuts "Time of Day" automation at each schedule rule's time (HANDOVER.md §5): iOS has no
/// exact background alarms, so this is how schedule rules run on time.
struct RunScheduledRulesIntent: AppIntent {
    static var title: LocalizedStringResource = "Run scheduled rules"
    static var description = IntentDescription("Runs the EV6 Precondition schedule rules that are due now. Add it to a Shortcuts Time of Day automation set to run immediately.")
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
            case .fired(let rule, let action): return "\(rule.name): \(Describe.action(action)) sent."
            case .skipped(let reason): return "Skipped: \(reason)."
            case .failed(let error, _): return "Failed: \(error.message)."
            }
        }.joined(separator: " ")
    }
}

struct StartClimateIntent: AppIntent {
    static var title: LocalizedStringResource = "Precondition now"
    static var description = IntentDescription("Starts the EV6's climate at your default temperature. The minimum-charge guard still applies.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        await services.prepare()
        await services.car.start()
        return .result(dialog: "\(services.car.message ?? "Done.")")
    }
}

struct StopClimateIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop climate"
    static var description = IntentDescription("Stops the EV6's climate.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AppServices.shared
        await services.prepare()
        await services.car.stop()
        return .result(dialog: "\(services.car.message ?? "Done.")")
    }
}

struct EV6Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartClimateIntent(),
            phrases: ["Precondition my car with \(.applicationName)", "Warm up the car with \(.applicationName)"],
            shortTitle: "Precondition now",
            systemImageName: "thermometer.sun"
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
