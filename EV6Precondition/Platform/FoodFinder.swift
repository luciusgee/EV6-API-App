import MapKit
import PreconditionKit

/// What there is to eat near each charger, and where it is ("Rugby Services", "Daventry"), from
/// Apple Maps.
@MainActor
@Observable
final class FoodFinder {
    /// Charger id → names of places to eat nearby.
    private(set) var places: [String: [String]] = [:]
    /// Charger id → the services or town it's at.
    private(set) var areas: [String: String] = [:]
    /// Charger id → the motorway services or petrol station it's at; missing when it's at neither.
    private(set) var stations: [String: Station] = [:]
    /// Chargers whose services and petrol station have been looked up.
    private(set) var stationChecked: Set<String> = []

    struct Station: Equatable {
        var name: String
        var motorway: Bool
    }
    private(set) var loading: Set<String> = []
    @ObservationIgnored private var areaTried: Set<String> = []

    func food(at charger: RouteCharger) -> [String]? { places[charger.id] }

    /// Where the charger is, unless its own name already says so.
    func area(of charger: RouteCharger) -> String? {
        guard let area = areas[charger.id], !charger.name.localizedCaseInsensitiveContains(area) else { return nil }
        return area
    }

    func load(_ chargers: [RouteCharger]) async {
        let areaWanted = chargers.filter { !areaTried.contains($0.id) }
        areaTried.formUnion(areaWanted.map(\.id))
        let noServices: [String] = await withTaskGroup(of: String?.self) { group in
            for c in chargers where places[c.id] == nil && !loading.contains(c.id) {
                loading.insert(c.id)
                group.addTask { @MainActor in
                    let names = await Self.search(near: c.position)
                    self.places[c.id] = names
                    self.loading.remove(c.id)
                    return nil
                }
            }
            for c in areaWanted {
                group.addTask { @MainActor in
                    async let services = Self.services(near: c.position)
                    async let petrol = Self.petrolStation(near: c.position)
                    let (motorway, fuel) = await (services, petrol)
                    if let motorway {
                        self.stations[c.id] = Station(name: motorway, motorway: true)
                    } else if let fuel {
                        self.stations[c.id] = Station(name: fuel, motorway: false)
                    }
                    self.stationChecked.insert(c.id)
                    guard let motorway else { return c.id }
                    self.areas[c.id] = motorway
                    return nil
                }
            }
            var out: [String] = []
            for await id in group { if let id { out.append(id) } }
            return out
        }
        // Apple limits how fast places can be looked up, so one at a time.
        for c in areaWanted where noServices.contains(c.id) {
            if let town = await Self.town(at: c.position) { areas[c.id] = town }
        }
    }

    /// Motorway services the charger is at, e.g. "Rugby Services".
    static func services(near p: LatLon) async -> String? {
        let centre = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "services"
        request.region = MKCoordinateRegion(center: centre, latitudinalMeters: 1200, longitudinalMeters: 1200)
        let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
        let here = CLLocation(latitude: p.lat, longitude: p.lon)
        return items.first { item in
            guard let name = item.name, ServiceStations.isMotorwayServices(name) else { return false }
            return item.placemark.location.map { $0.distance(from: here) <= 600 } ?? false
        }?.name
    }

    /// A petrol station on the same forecourt, e.g. "Shell".
    static func petrolStation(near p: LatLon) async -> String? {
        let centre = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
        let request = MKLocalPointsOfInterestRequest(center: centre, radius: 150)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation])
        return ((try? await MKLocalSearch(request: request).start().mapItems) ?? []).first?.name
    }

    /// The town or district, when it isn't at services.
    static func town(at p: LatLon) async -> String? {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: p.lat, longitude: p.lon))
        guard let mark = marks?.first else { return nil }
        return mark.subLocality ?? mark.locality
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
