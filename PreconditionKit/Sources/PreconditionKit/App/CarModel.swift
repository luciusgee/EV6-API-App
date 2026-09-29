import Foundation
import Observation

/// Everything the Car, Activity and Settings screens show, and the actions behind their buttons.
/// Platform-free (Observation works on Linux too), so the screens' behaviour is unit-tested.
@MainActor
@Observable
public final class CarModel {
    public enum Busy: Equatable, Sendable {
        case refreshing, starting, stopping
        case command(CarCommand)
        case energy
    }

    public enum Banner: Equatable, Sendable {
        /// No refresh token yet.
        case setupNeeded
        /// Kia rejected the login; shows the fix.
        case authStopped(String)
        /// Paused after repeated failures; offers Resume.
        case paused(String)
        case fakeMode
    }

    public private(set) var snapshot: VehicleSnapshot?
    public private(set) var budget: BudgetSnapshot?
    public private(set) var automation = AutomationState()
    /// Newest first.
    public private(set) var log: [LogEntry] = []
    public private(set) var settings = AppSettings()
    /// Signed in (email and password) or a refresh token entered.
    public private(set) var hasToken = false
    /// The Kia account email when signed in with it.
    public private(set) var accountEmail: String?
    public private(set) var signingIn = false
    public private(set) var hasPin = false
    public private(set) var vin = ""
    public private(set) var busy: Busy?
    /// While refreshing: when it started, and whether the car is being woken for it.
    public private(set) var refreshStartedAt: Date?
    public private(set) var waking = false
    public private(set) var fakeCar = FakeCarState()
    /// The last driving history fetched (cached on disk).
    public private(set) var energy: DrivingHistory?
    /// A one-line result to show after an action, e.g. "Refused: SoC 20% below minimum 25%".
    public var message: String?
    /// The command being confirmed with the car ("lock the car"), while it is.
    public private(set) var confirming: String?
    @ObservationIgnored private var confirmTask: Task<Void, Never>?

    private let container: AppContainer

    /// Nonisolated so the SwiftUI `App` can build it in its initialiser.
    public nonisolated init(container: AppContainer) {
        self.container = container
    }

    public var now: Date { container.time.now() }

    public var banners: [Banner] {
        var out: [Banner] = []
        if settings.fakeMode { out.append(.fakeMode) }
        if !hasToken && !settings.fakeMode { out.append(.setupNeeded) }
        if let failure = automation.authFailure {
            out.append(.authStopped("\(failure). \(ApiMonitor.authHelp)"))
        } else if automation.pausedAfterFailures, let reason = automation.automationBlockedReason {
            out.append(.paused(reason))
        }
        return out
    }

    // MARK: - Loading

    /// Reads everything from disk and the Keychain. Makes no Kia request.
    public func load() async {
        await container.start()
        settings = await container.stores.settings.load()
        let creds = await container.credentials.credentials()
        hasToken = creds?.isConfigured ?? false
        accountEmail = creds?.account?.email
        hasPin = !(creds?.pin?.isEmpty ?? true)
        vin = creds?.vin ?? ""
        fakeCar = container.fakeCar.state
        energy = await container.stores.energy.load()
        await reloadState()
    }

    private func reloadState() async {
        snapshot = await container.vehicles.cached()
        budget = await container.budget.snapshot()
        automation = await container.stores.automationState.load()
        log = await container.stores.log.entries().reversed()
    }

    // MARK: - Car actions

    /// `wake` asks the car itself to report, rather than reading what Kia last heard from it.
    public func refresh(wake: Bool = false) async {
        guard busy == nil else { return }
        busy = .refreshing
        waking = wake
        refreshStartedAt = now
        defer {
            waking = false
            refreshStartedAt = nil
        }
        let result = await container.engine.refreshVehicle(wake: wake)
        if let error = result.error {
            message = "Refresh failed: \(error.message)"
        } else if wake {
            message = "✓ Fresh from the car."
        }
        busy = nil
        await reloadState()
    }

    public func start(targetC: Double? = nil) async {
        guard busy == nil else { return }
        busy = .starting
        report(await container.engine.manualStart(targetC: targetC))
        busy = nil
        fakeCar = container.fakeCar.state
        await reloadState()
    }

    public func stop() async {
        guard busy == nil else { return }
        busy = .stopping
        report(await container.engine.manualStop())
        busy = nil
        await reloadState()
    }

    /// Charging, locks, charge limits.
    public func send(_ command: CarCommand) async {
        guard busy == nil else { return }
        if let already = alreadySet(command) {
            message = already
            return
        }
        busy = .command(command)
        let outcome = await container.engine.manualCommand(command)
        if case .sent(let description) = outcome, !command.confirmedByCar {
            // Kia accepted it and there's nothing more the car will report.
            message = "✓ \(DisplayText.confirmed(description))."
        } else {
            report(outcome)
        }
        busy = nil
        fakeCar = container.fakeCar.state
        await reloadState()
    }

    /// Fetches the driving history (one manual request).
    public func refreshEnergy() async {
        guard busy == nil else { return }
        busy = .energy
        switch await container.engine.drivingHistory() {
        case .success(let history, _):
            energy = history
            await container.stores.energy.save(history)
        case .failure(let error, _):
            message = "Energy data unavailable: \(error.message)"
        }
        busy = nil
        await reloadState()
    }

    /// A setting the car already has: nothing to send.
    private func alreadySet(_ command: CarCommand) -> String? {
        let details = snapshot?.details
        switch command {
        case .setChargeLimits(let ac, let dc):
            guard details?.chargeLimitAC == KiaClient.chargeLimit(ac), details?.chargeLimitDC == KiaClient.chargeLimit(dc) else { return nil }
            return "The car's already set to AC \(KiaClient.chargeLimit(ac))% · DC \(KiaClient.chargeLimit(dc))%."
        case .setOffPeak(let window):
            guard details?.offPeak == window else { return nil }
            return "The car's already set to \(window.text)."
        default:
            return nil
        }
    }

    /// Follows the command until the car reports back, like the Kia app does.
    private func confirm(_ description: String) {
        confirmTask?.cancel()
        confirming = description
        confirmTask = Task { [weak self] in
            guard let self else { return }
            let status = await self.container.engine.confirmLastCommand { seconds in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self.confirming = nil
            switch status {
            case .success:
                self.message = "✓ \(DisplayText.confirmed(description)): confirmed by the car."
            case .failed:
                self.message = "The car didn't \(description). It may be in use, or a door or the charge port may be open."
            case .noResponse:
                self.message = "The car didn't answer (\(description)). It may be out of mobile signal."
            case .pending, .unknown:
                self.message = "Sent: \(description). The car hasn't confirmed yet."
            }
            await self.reloadState()
        }
    }

    public func resumeAutomation() async {
        await container.engine.resumeAutomation()
        await reloadState()
    }

    private func report(_ outcome: ManualOutcome) {
        switch outcome {
        case .sent(let description):
            message = "Sent: \(description). Waiting for the car to confirm…"
            confirm(description)
        case .refused(let reason):
            message = "Not sent: \(reason)"
        case .failed(let error):
            message = "Failed: \(error.message)"
        }
    }

    // MARK: - Settings

    /// Kia tokens are usually 48 capital letters and digits. Anything else is allowed, with a warning.
    public nonisolated static func tokenLooksValid(_ token: String) -> Bool {
        token.count == 48 && token.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// Signs in with the Kia account and reads the car to prove it works. Returns an error to show, or nil.
    public func signIn(email: String, password: String) async -> String? {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, !password.isEmpty else { return "Enter your Kia account email and password." }
        signingIn = true
        defer { signingIn = false }
        let current = await container.credentials.credentials()
        await container.credentials.save(Credentials(vin: current?.vin ?? "", pin: current?.pin, email: e, password: password))
        await container.vehicles.clear()
        await container.stores.automationState.update { $0.authFailure = nil }
        await container.stores.log.append(LogEntry(at: now, kind: .info, decision: "settings", reason: "signed in to Kia as \(maskEmail(e))"))
        hasToken = true
        accountEmail = e
        let result = await container.engine.refreshVehicle()
        await reloadState()
        if let error = result.error {
            return error.isAuthFailure ? error.message.capitalizingFirstLetter : "Signed in, but reading the car failed: \(error.message)"
        }
        return nil
    }

    /// Forgets the Kia login (keeps the PIN and VIN).
    public func signOut() async {
        let current = await container.credentials.credentials()
        if let pin = current?.pin, !pin.isEmpty {
            await container.credentials.save(Credentials(vin: current?.vin ?? "", pin: pin))
        } else {
            await container.credentials.save(nil)
        }
        await container.client.reset()
        await container.vehicles.clear()
        await container.stores.log.append(LogEntry(at: now, kind: .info, decision: "settings", reason: "signed out of Kia"))
        hasToken = false
        accountEmail = nil
        await reloadState()
    }

    /// Saves what the user entered. `nil` keeps the stored value; an empty string removes it.
    public func saveCredentials(token: String? = nil, pin: String? = nil, vin newVin: String? = nil) async {
        let current = await container.credentials.credentials()
        let refreshToken = (token ?? current?.refreshToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let newPin = (pin ?? current?.pin ?? "").trimmingCharacters(in: .whitespaces)
        let wantedVin = (newVin ?? current?.vin ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        // A pasted token replaces an account sign-in; otherwise the account stays.
        let keepAccount = token == nil || refreshToken.isEmpty
        let email = keepAccount ? current?.email : nil
        let password = keepAccount ? current?.password : nil

        let tokenChanged = refreshToken != (current?.refreshToken ?? "")
        let vinChanged = wantedVin != (current?.vin ?? "")

        let next = Credentials(refreshToken: refreshToken, vin: wantedVin, pin: newPin.isEmpty ? nil : newPin, email: email, password: password)
        await container.credentials.save(next.isConfigured || !newPin.isEmpty ? next : nil)
        if tokenChanged || vinChanged {
            // A new login or another car: the cached state and the old stop reason no longer apply.
            if !settings.fakeMode { await container.vehicles.clear() }
            await container.stores.automationState.update { $0.authFailure = nil }
        }
        if tokenChanged {
            await container.stores.log.append(LogEntry(
                at: now, kind: .info, decision: "settings",
                reason: refreshToken.isEmpty ? "Kia Connect refresh token removed" : "Kia Connect refresh token replaced"
            ))
        }
        hasToken = next.isConfigured
        accountEmail = next.account?.email
        hasPin = !newPin.isEmpty
        vin = next.isConfigured ? wantedVin : ""
        await reloadState()
    }

    public func updateSettings(_ change: (inout AppSettings) -> Void) async {
        var s = settings
        change(&s)
        s = s.clamped
        let fakeChanged = s.fakeMode != settings.fakeMode
        // Update at once so steppers and toggles never read a stale value; the file write follows.
        settings = s
        container.fakeWeather.celsius = s.fakeWeatherC
        if fakeChanged { container.transport.fakeMode = s.fakeMode }
        await container.stores.settings.save(s)
        if fakeChanged {
            // Never show fake data as the real car, or the other way round.
            await container.vehicles.clear()
            await container.stores.log.append(LogEntry(
                at: now, kind: .info, decision: "settings",
                reason: s.fakeMode ? "fake car on: no requests go to Kia" : "fake car off"
            ))
        }
        await reloadState()
    }

    public func updateFakeCar(_ change: (inout FakeCarState) -> Void) {
        var s = container.fakeCar.state
        let wasPlugged = s.pluggedIn
        change(&s)
        // Plugging in again starts a new charging session.
        if s.pluggedIn != wasPlugged { s.chargerHeld = false }
        if !s.pluggedIn { s.charging = false }
        container.fakeCar.state = s
        fakeCar = s
    }

    public func clearLog() async {
        await container.stores.log.clear()
        await reloadState()
    }

    public func logCSV() -> String {
        LogRetention.csv(log.reversed())
    }
}
