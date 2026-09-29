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
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw Failure.noRoute }
        let chargers = await chargersAlong(route)
        return Found(route: route, chargers: chargers)
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

    /// Searches around points every ~25 km along the route (Apple Maps' EV-charger category), then
    /// places each charger at its nearest point on the route.
    static func chargersAlong(_ route: MKRoute) async -> [RouteCharger] {
        let pts = points(route)
        guard let total = pts.last?.1, total > 0 else { return [] }
        var samples: [CLLocationCoordinate2D] = []
        var next = 20.0
        for (c, km) in pts where km >= next {
            samples.append(c)
            next += 25
        }
        // Keep the number of searches sensible on very long trips.
        if samples.count > 40 {
            let stride = Double(samples.count) / 40
            samples = (0..<40).map { samples[Int(Double($0) * stride)] }
        }
        var items: [MKMapItem] = []
        await withTaskGroup(of: [MKMapItem].self) { group in
            for (i, centre) in samples.enumerated() {
                group.addTask {
                    // Apple Maps throttles bursts: spread the searches out a little.
                    try? await Task.sleep(for: .milliseconds(120 * (i % 8)))
                    return await ChargerSearch.near(centre, radius: 4000)
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
    static func googleMapsURL(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, stops: [TripStop]) -> URL? {
        var comps = URLComponents(string: "https://www.google.com/maps/dir/")!
        var items = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "origin", value: "\(from.latitude),\(from.longitude)"),
            URLQueryItem(name: "destination", value: "\(to.latitude),\(to.longitude)"),
            URLQueryItem(name: "travelmode", value: "driving"),
        ]
        if !stops.isEmpty {
            items.append(URLQueryItem(name: "waypoints", value: stops.map { "\($0.charger.position.lat),\($0.charger.position.lon)" }.joined(separator: "|")))
        }
        comps.queryItems = items
        return comps.url
    }
}
