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
                KiaConnectSection()
                MyCarSection()
                GuideSettingsSection()
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
                PermissionsSection()
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                } footer: {
                    Text("No analytics and no account with us. The app talks to Kia, and only for the features you use to Apple Maps, OpenStreetMap (charger details), a weather service and Google Maps (to read commute links).")
                }
            }
            .scrollDismissesKeyboard(.interactively)
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
            Picker("Colour", selection: $paint) {
                ForEach(CarPaint.allCases) { Text($0.name).tag($0) }
            }
            Toggle("Show distances in miles", isOn: Binding(
                get: { model.settings.useMiles },
                set: { on in Task { await model.updateSettings { $0.useMiles = on } } }
            ))
        } header: {
            Text("My EV6")
        } footer: {
            Text("2022 EV6 GT-Line AWD · \(paint.name) · 77.4 kWh · 325 bhp")
        }
    }
}

// MARK: - Kia Connect

private struct KiaConnectSection: View {
    @Environment(CarModel.self) private var model
    @State private var email = ""
    @State private var password = ""
    @State private var signInError: String?
    @State private var confirmSignOut = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        Section {
            if let failure = model.automation.authFailure {
                VStack(alignment: .leading, spacing: 2) {
                    Label(failure.capitalizingFirst, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(model.accountEmail == nil ? "Sign in again below." : "Sign out, then sign in again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let account = model.accountEmail {
                LabeledContent {
                    Text(account).lineLimit(1)
                } label: {
                    Label("Signed in", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                Button("Sign out", role: .destructive) {
                    confirmSignOut = true
                }
                .confirmationDialog("Sign out of Kia?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                    Button("Sign out", role: .destructive) {
                        Task { await model.signOut() }
                    }
                } message: {
                    Text("Rules and alerts stop until you sign in again.")
                }
            } else {
                TextField("Kia account email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .onSubmit { passwordFocused = true }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($passwordFocused)
                    .submitLabel(.go)
                    .onSubmit { signIn() }
                Button {
                    signIn()
                } label: {
                    HStack {
                        Text(model.signingIn ? "Signing in…" : "Sign in")
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

// MARK: - Automation

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
                LabeledContent("Last sent") {
                    Text("\(DisplayText.confirmed(last.description)), \(DisplayText.age(of: last.at, now: model.now))")
                        .multilineTextAlignment(.trailing)
                }
            }
            NavigationLink {
                KiaLimitsView()
            } label: {
                LabeledContent {
                    Text(model.budget.map { "\($0.remaining) left" } ?? "")
                } label: {
                    Label("Kia limits", systemImage: "gauge.with.dots.needle.33percent")
                }
            }
        } header: {
            Text("Automation")
        } footer: {
            Text(model.settings.automationPaused
                 ? "Paused. Rules still log what they would do, but send nothing."
                 : "Rules and smart charging run by themselves while this is on.")
        }
    }
}

/// How many times the app may contact the car, and how many rules may use.
private struct KiaLimitsView: View {
    @Environment(CarModel.self) private var model

    var body: some View {
        Form {
            Section {
                if let budget = model.budget {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Left today", value: "\(budget.remaining) of \(budget.limit)")
                        ProgressView(value: Double(budget.remaining), total: Double(max(budget.limit, 1)))
                            .tint(budget.exhaustedUntil == nil ? Color.accentColor : Color.red)
                        Text(DisplayText.budget(budget)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                RoundStepper("Daily limit", value: Binding(
                    get: { model.settings.budgetLimit },
                    set: { v in Task { await model.updateSettings { $0.budgetLimit = v } } }
                ), in: 10...200, step: 10) { "\($0)" }
            } footer: {
                Text("Kia lets an app contact your car about 200 times a day. Rules stop \(model.settings.budgetReserve) short, so the buttons in the app always work.")
            }
        }
        .navigationTitle("Kia limits")
    }
}

// MARK: - Permissions

private struct PermissionsSection: View {
    @Environment(RulesModel.self) private var rules
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

    /// Leave and arrive rules need Always to work with the app closed.
    private var needsAlways: Bool {
        status == .authorizedWhenInUse && !rules.places.isEmpty
    }

    var body: some View {
        Section {
            LabeledContent("Location", value: statusText)
            if needsAlways {
                Label("Leave and arrive rules need Always", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if status == .notDetermined {
                Button("Allow location") {
                    LocationAccess.shared.requestIfNeeded()
                }
            } else if status == .denied || status == .restricted || needsAlways, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open iOS Settings", destination: url)
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Used for Places (leave and arrive rules) and “phone near the car”. Choose Always so leave and arrive rules work with the app closed. Your location never leaves your iPhone.")
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
