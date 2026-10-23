import CoreLocation
import Foundation
import PreconditionKit

/// GPS for the lap timer: every fix while a session runs, as fast as the phone gives them.
@MainActor
@Observable
final class LapLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var latest: CLLocation?
    private(set) var denied = false
    /// Called with every fix.
    @ObservationIgnored var onFix: ((CLLocation) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: denied = true
        default: break
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            for location in locations where location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 50 {
                latest = location
                onFix?(location)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            denied = status == .denied || status == .restricted
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.manager.startUpdatingLocation() }
        }
    }
}

extension CLLocation {
    var geoPoint: GeoPoint { GeoPoint(lat: coordinate.latitude, lon: coordinate.longitude) }
}
