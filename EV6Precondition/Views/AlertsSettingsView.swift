import PreconditionKit
import SwiftUI

/// Which car alerts to send, and how often to check the car in the background for them.
struct AlertsSettingsView: View {
    @Environment(ChargingModel.self) private var charging

    private var alerts: AlertSettings { charging.settings.alerts }

    var body: some View {
        Form {
            Section {
                ForEach(CarAlertKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { alerts.enabled.contains(kind) },
                        set: { on in Task { await charging.update { if on { $0.alerts.enabled.insert(kind) } else { $0.alerts.enabled.remove(kind) } } } }
                    )) {
                        Label(kind.title, systemImage: symbol(kind))
                    }
                }
            } footer: {
                Text("Each is sent once, then again only after it has cleared.")
            }
            Section {
                RoundStepper("Low charge below", value: charging.binding(\.alerts.lowChargePercent), in: 5...50, step: 5) { "\($0)%" }
                RoundStepper("12 V battery below", value: charging.binding(\.alerts.lowAuxPercent), in: 40...90, step: 5) { "\($0)%" }
            }
            Section {
                Toggle("Check in the background", isOn: Binding(
                    get: { alerts.backgroundChecks },
                    set: { on in Task { await charging.update { $0.alerts.backgroundChecks = on }; ChargingCoordinator.shared.scheduleBackgroundRefresh() } }
                ))
                if alerts.backgroundChecks {
                    RoundStepper("About every", value: Binding(
                        get: { alerts.backgroundEveryHours },
                        set: { v in Task { await charging.update { $0.alerts.backgroundEveryHours = v }; ChargingCoordinator.shared.scheduleBackgroundRefresh() } }
                    ), in: 1...12, step: 1) { "\($0) h" }
                }
            } footer: {
                Text("iOS decides exactly when background checks run, usually less often than asked. Each uses one Kia request from the automation budget; your own taps keep their reserve.")
            }
        }
        .navigationTitle("Alerts")
    }

    private func symbol(_ kind: CarAlertKind) -> String {
        switch kind {
        case .chargingStopped: return "bolt.slash"
        case .chargeComplete: return "battery.100percent.bolt"
        case .leftUnlocked: return "lock.open"
        case .windowOpen: return "window.vertical.open"
        case .lowAuxBattery: return "minus.plus.batteryblock"
        case .tyrePressure: return "tirepressure"
        case .lowCharge: return "battery.25percent"
        }
    }
}
