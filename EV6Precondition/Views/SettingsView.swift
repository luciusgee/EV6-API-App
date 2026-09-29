import CoreLocation
import PreconditionKit
import SwiftUI
import UIKit

/// Settings: the car, the Kia account, safety, automation and requests, alerts and the log.
struct SettingsView: View {
    @Environment(CarModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                GuideSettingsSection()
                MyCarSection()
                KiaConnectSection()
                SafetySection()
                AutomationSection()
                Section {
                    NavigationLink {
                        AlertsSettingsView()
                    } label: {
                        Label("Alerts", systemImage: "bell.badge")
                    }
                    NavigationLink {
                        ActivityView()
                    } label: {
                        Label("Activity log", systemImage: "list.bullet.clipboard")
                    }
                }
                ChargerDataSection()
                PermissionsSection()
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                } footer: {
                    Text("No analytics and no server. The app only talks to Kia.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - My car

private struct MyCarSection: View {
    @Environment(CarModel.self) private var model
    @AppStorage(CarPaint.storageKey) private var paint: CarPaint = .runwayRed

    var body: some View {
        Section {
            CarHeroImage(rest: CarSpin.rear, paint: paint)
                .padding(.vertical, 8)
            Toggle("Miles", isOn: Binding(
                get: { model.settings.useMiles },
                set: { on in Task { await model.updateSettings { $0.useMiles = on } } }
            ))
        } header: {
            Text("My EV6")
        } footer: {
            Text("2022 EV6 GT-Line AWD · Runway Red · 77.4 kWh · 325 bhp")
        }
    }
}

// MARK: - Kia Connect

private struct KiaConnectSection: View {
    @Environment(CarModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var signInError: String?


    var body: some View {
        Section {
            if let failure = model.automation.authFailure {
                Label("Problem: \(failure)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if let account = model.accountEmail {
                LabeledContent {
                    Text(account).lineLimit(1)
                } label: {
                    Label("Signed in", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                Button("Sign Out", role: .destructive) {
                    Task { await model.signOut() }
                }
            } else {
                TextField("Kia account email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit { signIn() }
                Button {
                    signIn()
                } label: {
                    HStack {
                        Text(model.signingIn ? "Signing In…" : "Sign In")
                        Spacer()
                        if model.signingIn { ProgressView() }
                    }
                }
                .disabled(model.signingIn || email.isEmpty || password.isEmpty)
                if let signInError {
                    Text(signInError).font(.footnote).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Kia account")
        } footer: {
            Text("Your Kia app login. The password stays in the iPhone Keychain and only goes to Kia.")
        }
    }
}

extension KiaConnectSection {
    private func signIn() {
        let (e, p) = (email, password)
        guard !e.isEmpty, !p.isEmpty else { return }
        signInError = nil
        Task {
            signInError = await model.signIn(email: e, password: p)
            if signInError == nil { password = "" }
        }
    }
}

// MARK: - Safety

private struct SafetySection: View {
    @Environment(CarModel.self) private var model

    var body: some View {
        Section {
            RoundStepper("Minimum charge", value: binding(\.minSocPercent), in: 0...100, step: 5) { "\($0)%" }
        } header: {
            Text("Safety")
        } footer: {
            Text("Climate won't start below this unless the car is plugged in.")
        }
    }

    private func binding<T: Sendable>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in Task { await model.updateSettings { $0[keyPath: keyPath] = value } } }
        )
    }
}

// MARK: - Charger data

/// Keys for charger details: Open Charge Map (free) and Google Places (live availability, reviews).
private struct ChargerDataSection: View {
    @State private var ocm = ChargerKeys.openChargeMap ?? ""
    @State private var google = ChargerKeys.google ?? ""

    var body: some View {
        Section {
            SecureField("Open Charge Map key", text: $ocm)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { ChargerKeys.openChargeMap = ocm.trimmingCharacters(in: .whitespacesAndNewlines) }
                .onChange(of: ocm) { _, v in ChargerKeys.openChargeMap = v.trimmingCharacters(in: .whitespacesAndNewlines) }
            Link(destination: URL(string: "https://openchargemap.org/site/loginprovider/beginlogin")!) {
                Label("Get a free key (My profile › API keys)", systemImage: "key")
            }
            SecureField("Google key (optional)", text: $google)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: google) { _, v in ChargerKeys.google = v.trimmingCharacters(in: .whitespacesAndNewlines) }
            Link(destination: URL(string: "https://console.cloud.google.com/google/maps-apis/api-list")!) {
                Label("Google key: enable Places API (New)", systemImage: "key")
            }
        } header: {
            Text("Charger data")
        } footer: {
            Text("Open Charge Map adds real charger speeds, connectors, prices and drivers' check-ins. Google adds live availability and reviews, and may charge after its free allowance. Keys stay in the iPhone Keychain.")
        }
    }
}

// MARK: - Automation and requests

private struct AutomationSection: View {
    @Environment(CarModel.self) private var model
    @Environment(RulesModel.self) private var rules

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { !model.settings.automationPaused },
                set: { on in Task { await model.updateSettings { $0.automationPaused = !on } } }
            )) {
                Label("Rules and smart charging", systemImage: "gearshape.2")
            }
            if let next = rules.nextCheck {
                LabeledContent("Next scheduled check") {
                    Text(next.at, format: .dateTime.weekday(.abbreviated).hour().minute())
                }
            }
            if let last = model.automation.lastCommand {
                LabeledContent("Last command") {
                    Text("\(last.description.capitalizingFirst), \(DisplayText.age(of: last.at, now: model.now))")
                        .multilineTextAlignment(.trailing)
                }
            }
            if let budget = model.budget {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Kia requests left", value: "\(budget.remaining) of \(budget.limit)")
                    ProgressView(value: Double(budget.remaining), total: Double(max(budget.limit, 1)))
                        .tint(budget.exhaustedUntil == nil ? Color.accentColor : .red)
                    Text(DisplayText.budget(budget)).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            RoundStepper("Requests per day", value: Binding(
                get: { model.settings.budgetLimit },
                set: { v in Task { await model.updateSettings { $0.budgetLimit = v } } }
            ), in: 10...200, step: 10) { "\($0)" }
        } header: {
            Text("Automation")
        } footer: {
            Text(model.settings.automationPaused
                 ? "Paused. Rules still log what they would do, but send nothing."
                 : "Kia allows about 200 requests a day. Automations stop \(model.settings.budgetReserve) short, so the app's buttons always work.")
        }
    }
}

// MARK: - Permissions

private struct PermissionsSection: View {
    @State private var status: CLAuthorizationStatus = .notDetermined
    @Environment(\.scenePhase) private var scenePhase

    private var statusText: String {
        switch status {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While using the app"
        case .denied: return "Not allowed"
        case .restricted: return "Restricted"
        default: return "Not asked yet"
        }
    }

    var body: some View {
        Section {
            LabeledContent("Location", value: statusText)
            if status == .notDetermined {
                Button("Allow Location") {
                    LocationAccess.shared.requestIfNeeded()
                }
            } else if status == .denied || status == .restricted, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open iOS Settings", destination: url)
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Location is used only for “phone near the car”: one reading when a rule runs, never tracked or sent anywhere.")
        }
        .onChange(of: scenePhase) { _, _ in status = LocationAccess.shared.status }
        .task {
            status = LocationAccess.shared.status
            // The permission sheet answers asynchronously; pick up the result.
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                status = LocationAccess.shared.status
            }
        }
    }
}
