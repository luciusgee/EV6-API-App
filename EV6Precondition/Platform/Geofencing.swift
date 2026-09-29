import CoreLocation
import PreconditionKit
import UIKit

/// Watches the places the rules need (HANDOVER.md §4.2) with iOS region monitoring. iOS wakes or
/// relaunches the app when a boundary is crossed, even after it was closed, so this must exist from launch.
@MainActor
final class GeofenceMonitor: NSObject {
    static let shared = GeofenceMonitor()

    private let manager = CLLocationManager()
    /// Set by `AppServices`: runs the engine for a crossed boundary.
    var onEvent: ((TriggerEvent, Date) async -> Void)?
    private(set) var watching: [String] = []

    override private init() {
        super.init()
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    /// Registers exactly the regions the enabled rules need (up to iOS's 20).
    func sync(rules: [Rule], places: [Place], carPosition: LatLon?) {
        let specs = Array(Geofences.required(rules, places: places, carPosition: carPosition).prefix(Geofences.iosRegionLimit))
        if !specs.isEmpty {
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            // Leaving and arriving happen with the app closed, which needs "Always".
            case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
            default: break
            }
        }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }

        let wanted = Dictionary(specs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for region in manager.monitoredRegions {
            guard let circle = region as? CLCircularRegion, let spec = wanted[region.identifier], Self.same(circle, spec) else {
                manager.stopMonitoring(for: region)
                continue
            }
        }
        let current = Set(manager.monitoredRegions.map(\.identifier))
        for spec in specs where !current.contains(spec.id) {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: spec.centre.lat, longitude: spec.centre.lon),
                radius: min(spec.radiusM, manager.maximumRegionMonitoringDistance),
                identifier: spec.id
            )
            region.notifyOnEntry = spec.enter
            region.notifyOnExit = spec.exit
            manager.startMonitoring(for: region)
        }
        watching = specs.map(\.id)
    }

    private static func same(_ r: CLCircularRegion, _ s: GeofenceSpec) -> Bool {
        abs(r.center.latitude - s.centre.lat) < 1e-6 && abs(r.center.longitude - s.centre.lon) < 1e-6
            && abs(r.radius - s.radiusM) < 1 && r.notifyOnEntry == s.enter && r.notifyOnExit == s.exit
    }

    private func crossed(_ id: String, _ transition: Transition) {
        guard let event = Geofences.event(for: id, transition: transition), let onEvent else { return }
        let at = Date()
        Task { await onEvent(event, at) }
    }
}

extension GeofenceMonitor: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.crossed(id, .enter) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let id = region.identifier
        Task { @MainActor in self.crossed(id, .exit) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in NotificationCenter.default.post(name: .locationAuthorisationChanged, object: nil) }
    }
}

extension Notification.Name {
    static let locationAuthorisationChanged = Notification.Name("locationAuthorisationChanged")
}

/// Runs a boundary crossing through the engine inside the few seconds iOS gives a background wake.
enum BackgroundTrigger {
    @MainActor
    static func run(_ event: TriggerEvent, at: Date, engine: PreconditionEngine) async {
        let app = UIApplication.shared
        var task: UIBackgroundTaskIdentifier = .invalid
        task = app.beginBackgroundTask(withName: "precondition") {
            app.endBackgroundTask(task)
            task = .invalid
        }
        let sleep: @Sendable (TimeInterval) async throws -> Void = { delay in
            // Give up on a wait that wouldn't finish before iOS suspends the app.
            let remaining = await MainActor.run { app.applicationState == .active ? Double.infinity : app.backgroundTimeRemaining }
            guard remaining > delay + 8 else { throw CancellationError() }
            try await Task.sleep(for: .seconds(delay))
        }
        let outcome = await engine.onTriggerWithRetries(event, triggeredAt: at, backoff: [8, 15], busyDelay: 20, sleep: sleep)
        if case .fired = outcome {
            // Confirm with the car in whatever time is left, as for manual commands.
            await engine.confirmLastCommand(kind: .automation, sleep: sleep)
        }
        if task != .invalid { app.endBackgroundTask(task) }
    }
}
