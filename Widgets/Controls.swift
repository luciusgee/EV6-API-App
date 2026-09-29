import AppIntents
import SwiftUI
import WidgetKit

// Control Center, Lock Screen and Action button controls (iOS 18). Each runs a command in the app's
// process through `CarCommandIntent`.

@available(iOSApplicationExtension 18.0, *)
struct PreconditionControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.luciusgee.ev6precondition.control.precondition") {
            ControlWidgetButton(action: CarCommandIntent(.climateStart)) {
                Label("Start climate", systemImage: "fan.fill")
            }
        }
        .displayName("Start climate")
        .description("Starts the car's climate.")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct StopClimateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.luciusgee.ev6precondition.control.stopclimate") {
            ControlWidgetButton(action: CarCommandIntent(.climateStop)) {
                Label("Stop climate", systemImage: "fan.slash")
            }
        }
        .displayName("Stop climate")
        .description("Stops the car's climate.")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct LockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.luciusgee.ev6precondition.control.lock") {
            ControlWidgetButton(action: CarCommandIntent(.lock)) {
                Label("Lock car", systemImage: "lock.fill")
            }
        }
        .displayName("Lock car")
        .description("Locks the car.")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct RefreshControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.luciusgee.ev6precondition.control.refresh") {
            ControlWidgetButton(action: CarCommandIntent(.refresh)) {
                Label("Refresh car", systemImage: "arrow.clockwise")
            }
        }
        .displayName("Refresh car")
        .description("Reads the car's latest state. Uses one Kia request.")
    }
}
