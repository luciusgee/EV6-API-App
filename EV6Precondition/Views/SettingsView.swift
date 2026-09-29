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
                DeveloperSection()
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
            CarHeroImage(name: "CarRear", paint: paint)
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
                Button("Back to the Built-in Photos", role: .destructive) { photo.remove() }
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
            Text("2022 EV6 GT-Line AWD · Runway Red · 77.4 kWh · 325 bhp. Your photos are cut out of their backgrounds on this iPhone the first time they're shown.")
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
    @State private var token = ""
    @State private var pin = ""
    @State private var vin = ""
    @FocusState private var vinFocused: Bool

    private static let tokenGuide = URL(string: "https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/discussions/987")!

    var body: some View {
        Section {
            if let failure = model.automation.authFailure {
                Label("Problem: \(failure)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            SecureField(model.hasToken ? "Replace refresh token" : "Refresh token", text: $token)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
            if !token.isEmpty && !CarModel.tokenLooksValid(token.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Text("Kia tokens are usually 48 capital letters and digits")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Save token") {
                    let value = token
                    token = ""
                    Task { await model.saveCredentials(token: value) }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                if model.hasToken {
                    Button("Remove", role: .destructive) {
                        Task { await model.saveCredentials(token: "") }
                    }
                }
            }
            .buttonStyle(.borderless)
            Link("How to get a refresh token", destination: Self.tokenGuide)
        } header: {
            Text("Kia Connect")
        } footer: {
            Text("Kia has no public API, so this uses the Kia Connect app's own service (Europe). It can stop working whenever Kia changes it. Sign in once in a browser to get a refresh token, then paste it here. The token and PIN are kept in the iOS Keychain and never logged or exported.")
        }

        Section {
            SecureField(model.hasPin ? "Replace Kia Connect PIN" : "Kia Connect PIN", text: $pin)
                .keyboardType(.numberPad)
            HStack {
                Button("Save PIN") {
                    let value = pin
                    pin = ""
                    Task { await model.saveCredentials(pin: value) }
                }
                .disabled(pin.count < 4 || !model.hasToken)
                Spacer()
                if model.hasPin {
                    Button("Remove", role: .destructive) {
                        Task { await model.saveCredentials(pin: "") }
                    }
                }
            }
            .buttonStyle(.borderless)
        } footer: {
            Text("Needed for climate commands on 2024-on cars; older EV6s don't use it.")
        }

        Section {
            TextField("VIN (optional)", text: $vin)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($vinFocused)
                .submitLabel(.done)
                .onSubmit { vinFocused = false }
                .disabled(!model.hasToken)
                .onAppear { vin = model.vin }
                .onChange(of: vinFocused) { _, focused in
                    // Saved when the field loses focus.
                    if !focused && vin != model.vin {
                        let value = vin
                        Task { await model.saveCredentials(vin: value) }
                    }
                }
                .onChange(of: model.vin) { _, new in
                    if !vinFocused { vin = new }
                }
        } footer: {
            Text("Only if the account has more than one car; otherwise the first EV is used.")
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
            Text("Kia allows roughly 200 requests a day per account, and one read here makes about two. The app counts its own reads and commands against this daily budget and always leaves the reserve for you.")
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Int> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in Task { await model.updateSettings { $0[keyPath: keyPath] = value } } }
        )
    }
}

// MARK: - Developer

private struct DeveloperSection: View {
    @Environment(CarModel.self) private var model

    var body: some View {
        Section {
            Toggle("Fake car", isOn: Binding(
                get: { model.settings.fakeMode },
                set: { on in Task { await model.updateSettings { $0.fakeMode = on } } }
            ))
            if model.settings.fakeMode {
                Stepper(value: fake(\.socPercent), in: 0...100, step: 5) {
                    LabeledContent("Charge", value: "\(model.fakeCar.socPercent)%")
                }
                Toggle("Plugged in", isOn: fake(\.pluggedIn))
                Toggle("Charging", isOn: fake(\.charging)).disabled(!model.fakeCar.pluggedIn)
                Toggle("Climate on", isOn: fake(\.climateOn))
                Toggle("Locked", isOn: fake(\.locked))
                Toggle("Low tyre", isOn: fake(\.lowTyre))
                Toggle("Climate wakes the charger", isOn: fake(\.climateStartsCharging))
                Stepper(value: Binding(
                    get: { model.settings.fakeWeatherC },
                    set: { value in Task { await model.updateSettings { $0.fakeWeatherC = value } } }
                ), in: -30...45, step: 1) {
                    LabeledContent("Weather", value: Describe.temp(model.settings.fakeWeatherC))
                }
                Picker("Error scenario", selection: fake(\.scenario)) {
                    ForEach(FakeScenario.allCases, id: \.self) { scenario in
                        Text(Self.name(scenario)).tag(scenario)
                    }
                }
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("The fake car and fake weather answer instead of Kia and Open-Meteo, so every screen, rule and error can be tried without a car. Pull down on the Car tab to read it.")
        }
    }

    private func fake<T>(_ keyPath: WritableKeyPath<FakeCarState, T>) -> Binding<T> {
        Binding(
            get: { model.fakeCar[keyPath: keyPath] },
            set: { value in model.updateFakeCar { $0[keyPath: keyPath] = value } }
        )
    }

    private static func name(_ s: FakeScenario) -> String {
        switch s {
        case .none: return "None"
        case .refreshTokenRejected: return "Refresh token rejected"
        case .accessTokenRejected: return "Access token rejected"
        case .rateLimited: return "Daily limit reached"
        case .vehicleBusy: return "Car busy"
        case .notSupported: return "Command not supported"
        case .serverError: return "Server error"
        case .partial: return "No position"
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
