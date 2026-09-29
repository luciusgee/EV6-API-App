import MapKit
import PreconditionKit

/// What there is to eat near each charger, from Apple Maps (within a short walk).
@MainActor
@Observable
final class FoodFinder {
    /// Charger id → names of places to eat nearby.
    private(set) var places: [String: [String]] = [:]
    private(set) var loading: Set<String> = []

    func food(at charger: RouteCharger) -> [String]? { places[charger.id] }

    func load(_ chargers: [RouteCharger]) async {
        await withTaskGroup(of: Void.self) { group in
            for c in chargers where places[c.id] == nil && !loading.contains(c.id) {
                loading.insert(c.id)
                group.addTask { @MainActor in
                    let names = await Self.search(near: c.position)
                    self.places[c.id] = names
                    self.loading.remove(c.id)
                }
            }
        }
    }

    static func search(near p: LatLon, radius: CLLocationDistance = 400) async -> [String] {
        let centre = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
        let request = MKLocalPointsOfInterestRequest(center: centre, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.restaurant, .cafe, .bakery, .foodMarket])
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        var seen = Set<String>()
        return items.compactMap(\.name).filter { seen.insert($0).inserted }
    }
}
