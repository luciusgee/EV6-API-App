import CoreLocation
import PreconditionKit

/// Location permission. The manager lives here so its authorisation request isn't dropped.
@MainActor
final class LocationAccess {
    static let shared = LocationAccess()
    private let manager = CLLocationManager()

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    var allowed: Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    func requestIfNeeded() {
        if status == .notDetermined { manager.requestWhenInUseAuthorization() }
    }
}

/// One phone fix per rule run, for "phone near the car" (HANDOVER.md §4.3.7). Nil without permission or
/// without a fix within 10 seconds.
struct LocationPhoneLocator: PhoneLocator {
    func locate() async -> LatLon? {
        let allowed = await MainActor.run { LocationAccess.shared.allowed }
        guard allowed else { return nil }
        return await withTaskGroup(of: LatLon?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location {
                            return LatLon(lat: location.coordinate.latitude, lon: location.coordinate.longitude)
                        }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
