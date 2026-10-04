import PreconditionKit
import SwiftUI
import UIKit
import UserNotifications

/// Which car alerts to send, and how often to check the car in the background for them.
struct AlertsSettingsView: View {
    @Environment(ChargingModel.self) private var charging

    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationsOff = false

    private var alerts: AlertSettings { charging.settings.alerts }

    var body: some View {
        Form {
            if notificationsOff {
                Section {
                    Label("Notifications are off for this app, so alerts can't reach you.", systemImage: "bell.slash.fill")
                        .foregroundStyle(.orange)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open iOS Settings", destination: url)
                    }
                }
            }
            Section {
                ForEach(CarAlertKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { alerts.enabled.contains(kind) },
                        set: { on in Task { await charging.update { if on { $0.alerts.enabled.insert(kind) } else { $0.alerts.enabled.remove(kind) } } } }
                    )) {
                        Label(kind.title, systemImage: symbol(kind))
                    }
                    if kind == .lowCharge, alerts.enabled.contains(.lowCharge) {
                        RoundStepper("Below", value: charging.binding(\.alerts.lowChargePercent), in: 5...50, step: 5) { "\($0)%" }
                    }
                    if kind == .lowAuxBattery, alerts.enabled.contains(.lowAuxBattery) {
                        RoundStepper("Below", value: charging.binding(\.alerts.lowAuxPercent), in: 40...90, step: 5) { "\($0)%" }
                    }
                }
            } header: {
                Text("Tell me when")
            } footer: {
                Text("You'll get each alert once, and again only if it happens again.")
            }
            Section {
                Toggle("Evening check", isOn: Binding(
                    get: { alerts.plugReminder.enabled },
                    set: { on in Task { await charging.update { $0.alerts.plugReminder.enabled = on }; await ChargingCoordinator.shared.rebookPlugReminder() } }
                ))
                if alerts.plugReminder.enabled {
                    DatePicker("Time", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: alerts.plugReminder.at.hour, minute: alerts.plugReminder.at.minute, second: 0, of: Date()) ?? Date() },
                        set: { d in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                            Task {
                                await charging.update { $0.alerts.plugReminder.at = ClockTime(hour: c.hour ?? 20, minute: c.minute ?? 0) }
                                await ChargingCoordinator.shared.rebookPlugReminder()
                            }
                        }
                    ), displayedComponents: .hourAndMinute)
                    RoundStepper("Skip if charge is above", value: Binding(
                        get: { alerts.plugReminder.skipAbovePercent },
                        set: { v in Task { await charging.update { $0.alerts.plugReminder.skipAbovePercent = v }; await ChargingCoordinator.shared.rebookPlugReminder() } }
                    ), in: 50...100, step: 5) { "\($0)%" }
                }
            } header: {
                Text("Evening reminder")
            } footer: {
                Text("One note each evening: plugged in, what it should reach and when it'll be done; not plugged in, a reminder (skipped when the charge is above the level set). Plug in after it and you're told straight away.")
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
                Text("iOS decides when to check, often less often than this. Each check counts towards Kia's daily limit.")
            }
        }
        .navigationTitle("Alerts")
        .task(id: scenePhase) {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            notificationsOff = status == .denied
        }
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
