import CoreLocation
import PreconditionKit
import SwiftUI
import UIKit

/// Settings (HANDOVER.md §6.5): Kia Connect credentials, safety, rate limit, developer.
struct SettingsView: View {
    @Environment(CarModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                MyCarSection()
                KiaConnectSection()
                SafetySection()
                PermissionsSection()
                RateLimitSection()
                Section {
                    NavigationLink {
                        AlertsSettingsView()
                    } label: {
                        Label("Alerts", systemImage: "bell.badge")
                    }
                    NavigationLink {
                        ActivityView()
                    } label: {
                        Label("Activity", systemImage: "clock.arrow.circlepath")
                    }
                } footer: {
                    Text("Alerts for charging, locks, windows and the 12 V battery; and the log of every command and rule decision.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                } footer: {
                    Text("No analytics and no backend. The app only talks to Kia Connect.")
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
            RoundStepper("Default temperature", value: binding(\.defaultTargetC), in: AppSettings.minTargetC...AppSettings.maxTargetC, step: 0.5, tint: .orange) { Describe.temp($0) }
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

// MARK: - Rate limit

private struct RateLimitSection: View {
    @Environment(CarModel.self) private var model

    var body: some View {
        Section {
            RoundStepper("Kia requests per day", value: binding(\.budgetLimit), in: 10...200, step: 10) { "\($0)" }
        } header: {
            Text("Rate limit")
        } footer: {
            Text("Kia allows about 200 a day. Refreshing, sending a command and confirming it each count. Automations stop \(model.settings.budgetReserve) short, so the buttons in the app always work.")
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Int> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in Task { await model.updateSettings { $0[keyPath: keyPath] = value } } }
        )
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
