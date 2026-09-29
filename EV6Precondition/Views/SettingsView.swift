import CoreLocation
import PhotosUI
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
                        ActivityView()
                    } label: {
                        Label("Activity", systemImage: "clock.arrow.circlepath")
                    }
                } footer: {
                    Text("Every command, rule decision and problem, newest first.")
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
    @State private var photo = CarPhoto.shared
    @State private var picked: PhotosPickerItem?
    @State private var keepBackground = false

    var body: some View {
        Section {
            CarHeroImage(rest: CarSpin.rear, interactive: false, paint: paint)
                .padding(.vertical, 8)
                .overlay {
                    if photo.working {
                        ProgressView("Cutting out your car…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            PhotosPicker(selection: $picked, matching: .images) {
                Label("Use a Different Photo", systemImage: "photo.badge.plus")
            }
            if photo.image != nil {
                Button("Back to Kia's Render", role: .destructive) { photo.remove() }
            }
            if let problem = photo.problem {
                Text(problem).font(.footnote).foregroundStyle(.orange)
                Button("Use the Whole Photo Instead") {
                    keepBackground = true
                    if let item = picked { Task { await load(item) } }
                }
            }
            Toggle("Miles", isOn: Binding(
                get: { model.settings.useMiles },
                set: { on in Task { await model.updateSettings { $0.useMiles = on } } }
            ))
        } header: {
            Text("My EV6")
        } footer: {
            Text("2022 EV6 GT-Line AWD · Runway Red · 77.4 kWh · 325 bhp. On the Car tab, drag the car to turn it round; double-tap to put it back. A photo of your own is cut out of its background on this iPhone.")
        }
        .onChange(of: picked) { _, item in
            keepBackground = false
            if let item { Task { await load(item) } }
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        await photo.use(data, cutOut: !keepBackground)
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
            Text("The same email and password as the Kia app (Europe). The password is encrypted with Kia's key on this iPhone and only ever sent to Kia; it's kept in the iOS Keychain so the app can sign back in by itself if Kia ends the session. Kia has no public API, so this can stop working whenever Kia changes theirs.")
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
            Stepper(value: binding(\.minSocPercent), in: 0...100, step: 5) {
                LabeledContent("Minimum charge", value: "\(model.settings.minSocPercent)%")
            }
            Stepper(value: binding(\.defaultTargetC), in: AppSettings.minTargetC...AppSettings.maxTargetC, step: 0.5) {
                LabeledContent("Default temperature", value: Describe.temp(model.settings.defaultTargetC))
            }
        } header: {
            Text("Safety")
        } footer: {
            Text("Climate never starts below the minimum charge unless the car is plugged in. This applies to manual starts too.")
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
            Stepper(value: binding(\.budgetLimit), in: 10...200, step: 10) {
                LabeledContent("Requests per 24 hours", value: "\(model.settings.budgetLimit)")
            }
            Stepper(value: binding(\.budgetReserve), in: 0...(model.settings.budgetLimit / 2)) {
                LabeledContent("Kept for you", value: "\(model.settings.budgetReserve)")
            }
        } header: {
            Text("Rate limit")
        } footer: {
            Text("Kia allows roughly 200 requests a day per account; the app keeps itself to this budget so it never gets near that. A read, a command, and each check that the car carried a command out all count. Automation stops before the reserve, so it's always there for you.")
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
