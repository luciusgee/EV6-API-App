import AppIntents

/// What a widget button or Control Center control can ask the car to do.
enum CarAction: String, AppEnum {
    case refresh, climateStart, climateStop, lock, chargeStart, chargeStop

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Car action"
    static var caseDisplayRepresentations: [CarAction: DisplayRepresentation] = [
        .refresh: "Refresh",
        .climateStart: "Start climate",
        .climateStop: "Stop climate",
        .lock: "Lock",
        .chargeStart: "Start charging",
        .chargeStop: "Stop charging",
    ]

    var command: GlanceCommand { GlanceCommand(rawValue: rawValue) ?? .refresh }
}

/// Sends a command from a widget button or a Control Center control. Compiled into the app and the
/// widget extension; in the app it's a `ForegroundContinuableIntent`, so iOS runs it in the app's
/// process (in the background) where the Kia sign-in lives. The extension's copy never runs.
struct CarCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Send to EV6"
    static var isDiscoverable = false
    static var openAppWhenRun = false

    @Parameter(title: "Action")
    var action: CarAction

    init() {}

    init(_ action: CarAction) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        _ = await GlanceSync.shared.perform(action.command)
        #endif
        return .result()
    }
}

#if !WIDGET_EXTENSION
@available(iOSApplicationExtension, unavailable)
extension CarCommandIntent: ForegroundContinuableIntent {}
#endif
