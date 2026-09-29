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
                Text("You're told once, and again only if it happens again.")
            }
            Section {
                Toggle("Remind me if it's not plugged in", isOn: Binding(
                    get: { alerts.plugReminder.enabled },
                    set: { on in Task { await charging.update { $0.alerts.plugReminder.enabled = on }; await ChargingCoordinator.shared.rebookPlugReminder() } }
                ))
                if alerts.plugReminder.enabled {
                    DatePicker("At", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: alerts.plugReminder.at.hour, minute: alerts.plugReminder.at.minute, second: 0, of: Date()) ?? Date() },
                        set: { d in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                            Task {
                                await charging.update { $0.alerts.plugReminder.at = ClockTime(hour: c.hour ?? 21, minute: c.minute ?? 0) }
                                await ChargingCoordinator.shared.rebookPlugReminder()
                            }
                        }
                    ), displayedComponents: .hourAndMinute)
                    RoundStepper("Not if it's above", value: Binding(
                        get: { alerts.plugReminder.skipAbovePercent },
                        set: { v in Task { await charging.update { $0.alerts.plugReminder.skipAbovePercent = v }; await ChargingCoordinator.shared.rebookPlugReminder() } }
                    ), in: 50...100, step: 5) { "\($0)%" }
                }
            } header: {
                Text("Evening reminder")
            } footer: {
                Text("Every evening, unless the app has seen the car plugged in since the morning. Ignore it if you don't need to charge.")
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
                Text("Uses one Kia request each time. iOS decides exactly when, often less often than this.")
            }
        }
        .navigationTitle("Alerts")
    }

    private func symbol(_ kind: CarAlertKind) -> String {
        switch kind {
        case .pluggedIn: return "powerplug.fill"
        case .notCharging: return "exclamationmark.triangle"
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
