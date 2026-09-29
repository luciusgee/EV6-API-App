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
                Label("Precondition", systemImage: "fan.fill")
            }
        }
        .displayName("Precondition EV6")
        .description("Starts the car's climate (stopping an idle charger first, if you've set that).")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct StopClimateControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.luciusgee.ev6precondition.control.stopclimate") {
            ControlWidgetButton(action: CarCommandIntent(.climateStop)) {
                Label("Stop Climate", systemImage: "fan.slash")
            }
        }
        .displayName("Stop EV6 Climate")
        .description("Stops the car's climate.")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct LockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.luciusgee.ev6precondition.control.lock") {
            ControlWidgetButton(action: CarCommandIntent(.lock)) {
                Label("Lock EV6", systemImage: "lock.fill")
            }
        }
        .displayName("Lock EV6")
        .description("Locks the car.")
    }
}

@available(iOSApplicationExtension 18.0, *)
struct RefreshControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.luciusgee.ev6precondition.control.refresh") {
            ControlWidgetButton(action: CarCommandIntent(.refresh)) {
                Label("Update EV6", systemImage: "arrow.clockwise")
            }
        }
        .displayName("Update EV6")
        .description("Reads the car's latest state (one Kia request).")
    }
}
