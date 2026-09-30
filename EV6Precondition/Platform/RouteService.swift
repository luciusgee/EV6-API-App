import CoreLocation
import MapKit
import PreconditionKit

/// Apple Maps' EV chargers around a point. The charger category search throws when it finds nothing
/// (and sometimes when it shouldn't), so a plain "EV charging" search backs it up.
enum ChargerSearch {
    static func near(_ centre: CLLocationCoordinate2D, radius: CLLocationDistance) async -> [MKMapItem] {
        let poi = MKLocalPointsOfInterestRequest(center: centre, radius: radius)
        poi.pointOfInterestFilter = MKPointOfInterestFilter(including: [.evCharger])
        if let items = try? await MKLocalSearch(request: poi).start().mapItems, !items.isEmpty {
            return items
        }
        let text = MKLocalSearch.Request()
        text.naturalLanguageQuery = "EV charging"
        text.resultTypes = .pointOfInterest
        text.region = MKCoordinateRegion(center: centre, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        let items = (try? await MKLocalSearch(request: text).start().mapItems) ?? []
        // The text search can wander outside the region; keep what's actually near.
        let here = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        return items.filter {
            let c = $0.placemark.coordinate
            return here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) <= radius * 1.5
        }
    }
}

/// Finds the driving route with Apple Maps and the EV chargers along it.
enum RouteService {
    struct Found {
        var route: MKRoute
        var chargers: [RouteCharger]
        /// Full details for chargers from Open Charge Map, by id.
        var sites: [String: ChargeSite] = [:]
        /// Where the chargers came from.
        var source: String = "Apple Maps"
        var problem: String?
        /// Other ways Apple Maps suggests, fastest first, including `route`.
        var alternatives: [MKRoute] = []
    }

    enum Failure: Error, CustomStringConvertible {
        case noRoute
        var description: String { "Apple Maps couldn't find a driving route." }
    }

    static func route(from: CLLocationCoordinate2D, to destination: MKMapItem) async throws -> Found {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        let response = try await MKDirections(request: request).calculate()
        let routes = response.routes.sorted { $0.expectedTravelTime < $1.expectedTravelTime }
        guard let route = routes.first else { throw Failure.noRoute }
        var found = await chargers(on: route)
        found.alternatives = routes
        return found
    }

    /// The chargers along one route (after picking another way to go).
    static func chargers(on route: MKRoute) async -> Found {
        if let key = ChargerKeys.openChargeMap {
            do {
                return try await openChargeMap(route, key: key)
            } catch {
                var found = Found(route: route, chargers: await chargersAlong(route))
                found.problem = (error as? OpenChargeMapClient.Failure)?.description ?? "Couldn't reach Open Charge Map."
                return found
            }
        }
        return Found(route: route, chargers: await chargersAlong(route))
    }

    /// Chargers along the route from Open Charge Map, with their real speeds and details.
    static func openChargeMap(_ route: MKRoute, key: String) async throws -> Found {
        let pts = points(route)
        let client = OpenChargeMapClient(transport: URLSessionTransport(), key: key)
        let sites = try await client.along(pts.map { LatLon(lat: $0.0.latitude, lon: $0.0.longitude) }, radiusKm: 3, minKW: 40)
        var chargers: [RouteCharger] = []
        var byId: [String: ChargeSite] = [:]
        for site in sites where site.operational != false {
            let (km, off) = place(site.position, on: pts)
            guard off < 5000 else { continue }
            chargers.append(RouteCharger(site: site, alongKm: km, detourKm: off / 1000 * 2 * 1.3))
            byId[site.id] = site
        }
        return Found(route: route, chargers: chargers.sorted { $0.alongKm < $1.alongKm }, sites: byId, source: "Open Charge Map")
    }

    /// Distance along the route of the nearest route point, and how far off the route it is (m).
    static func place(_ p: LatLon, on pts: [(CLLocationCoordinate2D, Double)]) -> (km: Double, offM: Double) {
        let here = CLLocation(latitude: p.lat, longitude: p.lon)
        var best = (off: Double.infinity, km: 0.0)
        for (c, km) in pts {
            let d = here.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if d < best.off { best = (d, km) }
        }
        return (best.km, best.off)
    }

    /// Route points with the distance from the start to each, in km.
    static func points(_ route: MKRoute) -> [(CLLocationCoordinate2D, Double)] {
        let polyline = route.polyline
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        var out: [(CLLocationCoordinate2D, Double)] = []
        var km = 0.0
        for (i, c) in coords.enumerated() {
            if i > 0 {
                let p = coords[i - 1]
                km += CLLocation(latitude: p.latitude, longitude: p.longitude).distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) / 1000
            }
            out.append((c, km))
        }
        return out
    }

    /// Searches in overlapping circles all the way along the route (Apple Maps' EV-charger category),
    /// then places each charger at its nearest point on the route. The circles overlap so nothing on
    /// the road, like motorway services, falls in a gap between them.
    static func chargersAlong(_ route: MKRoute) async -> [RouteCharger] {
        let pts = points(route)
        guard let total = pts.last?.1, total > 0 else { return [] }
        // Every 7 km, or further apart on long trips to stay near 50 searches, with circles wide
        // enough to overlap.
        let spacing = max(7.0, total / 50)
        let radius = spacing * 1000 * 0.75
        var samples: [CLLocationCoordinate2D] = []
        var next = min(5.0, total / 2)
        for (c, km) in pts where km >= next {
            samples.append(c)
            next += spacing
        }
        var items: [MKMapItem] = []
        await withTaskGroup(of: [MKMapItem].self) { group in
            for (i, centre) in samples.enumerated() {
                group.addTask {
                    // Apple Maps throttles bursts: spread the searches out a little.
                    try? await Task.sleep(for: .milliseconds(120 * (i % 8)))
                    return await ChargerSearch.near(centre, radius: radius)
                }
            }
            for await found in group { items.append(contentsOf: found) }
        }
        var seen = Set<String>()
        var out: [RouteCharger] = []
        for item in items {
            let c = item.placemark.coordinate
            let key = String(format: "%.4f,%.4f", c.latitude, c.longitude)
            guard seen.insert(key).inserted else { continue }
            // Nearest route point.
            var best = (distance: Double.infinity, km: 0.0)
            let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
            for (p, km) in pts {
                let d = here.distance(from: CLLocation(latitude: p.latitude, longitude: p.longitude))
                if d < best.distance { best = (d, km) }
            }
            guard best.distance < 5000 else { continue }
            let name = item.name ?? "Charger"
            out.append(RouteCharger(
                id: key, name: name, position: LatLon(lat: c.latitude, lon: c.longitude),
                alongKm: best.km, detourKm: best.distance / 1000 * 2 * 1.3,
                powerKW: ChargerPower.guess(name: name), powerGuessed: true
            ))
        }
        return out.sorted { $0.alongKm < $1.alongKm }
    }

    /// Google Maps directions through every stop (Apple Maps can't take waypoints from another app).
    static func googleMapsURL(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, via: [LatLon]) -> URL? {
        var comps = URLComponents(string: "https://www.google.com/maps/dir/")!
        var items = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "origin", value: "\(from.latitude),\(from.longitude)"),
            URLQueryItem(name: "destination", value: "\(to.latitude),\(to.longitude)"),
            URLQueryItem(name: "travelmode", value: "driving"),
        ]
        if !via.isEmpty {
            items.append(URLQueryItem(name: "waypoints", value: via.map { "\($0.lat),\($0.lon)" }.joined(separator: "|")))
        }
        comps.queryItems = items
        return comps.url
    }
}
