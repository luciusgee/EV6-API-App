import Foundation
import Observation

/// Everything the Car, Activity and Settings screens show, and the actions behind their buttons.
/// Platform-free (Observation works on Linux too), so the screens' behaviour is unit-tested.
@MainActor
@Observable
public final class CarModel {
    public enum Busy: Equatable, Sendable {
        case refreshing, starting, stopping
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
    public private(set) var hasToken = false
    public private(set) var hasPin = false
    public private(set) var vin = ""
    public private(set) var busy: Busy?
    public private(set) var fakeCar = FakeCarState()
    /// A one-line result to show after an action, e.g. "Refused: SoC 20% below minimum 25%".
    public var message: String?

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
        hasToken = !(creds?.refreshToken.isEmpty ?? true)
        hasPin = !(creds?.pin?.isEmpty ?? true)
        vin = creds?.vin ?? ""
        fakeCar = container.fakeCar.state
        await reloadState()
    }

    private func reloadState() async {
        snapshot = await container.vehicles.cached()
        budget = await container.budget.snapshot()
        automation = await container.stores.automationState.load()
        log = await container.stores.log.entries().reversed()
    }

    // MARK: - Car actions

    public func refresh() async {
        guard busy == nil else { return }
        busy = .refreshing
        let result = await container.engine.refreshVehicle()
        if let error = result.error { message = "Refresh failed: \(error.message)" }
        busy = nil
        await reloadState()
    }

    public func start(targetC: Double? = nil) async {
        guard busy == nil else { return }
        busy = .starting
        report(await container.engine.manualStart(targetC: targetC))
        busy = nil
        await reloadState()
    }

    public func stop() async {
        guard busy == nil else { return }
        busy = .stopping
        report(await container.engine.manualStop())
        busy = nil
        await reloadState()
    }

    public func resumeAutomation() async {
        await container.engine.resumeAutomation()
        await reloadState()
    }

    private func report(_ outcome: ManualOutcome) {
        switch outcome {
        case .sent(let description):
            message = "Sent: \(description). The car carries it out shortly."
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

    /// Saves what the user entered. `nil` keeps the stored value; an empty string removes it.
    public func saveCredentials(token: String? = nil, pin: String? = nil, vin newVin: String? = nil) async {
        let current = await container.credentials.credentials()
        let refreshToken = (token ?? current?.refreshToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let newPin = (pin ?? current?.pin ?? "").trimmingCharacters(in: .whitespaces)
        let wantedVin = (newVin ?? current?.vin ?? "").trimmingCharacters(in: .whitespaces).uppercased()

        let tokenChanged = refreshToken != (current?.refreshToken ?? "")
        let vinChanged = wantedVin != (current?.vin ?? "")

        if refreshToken.isEmpty {
            await container.credentials.save(nil)
        } else {
            await container.credentials.save(Credentials(refreshToken: refreshToken, vin: wantedVin, pin: newPin.isEmpty ? nil : newPin))
        }
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
        hasToken = !refreshToken.isEmpty
        hasPin = !newPin.isEmpty
        vin = refreshToken.isEmpty ? "" : wantedVin
        await reloadState()
    }

    public func updateSettings(_ change: (inout AppSettings) -> Void) async {
        var s = settings
        change(&s)
        s = s.clamped
        let fakeChanged = s.fakeMode != settings.fakeMode
        // Update at once so steppers and toggles never read a stale value; the file write follows.
        settings = s
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
        change(&s)
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
