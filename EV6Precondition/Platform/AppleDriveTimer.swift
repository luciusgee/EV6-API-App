import MapKit
import PreconditionKit

/// Times a route with Apple Maps' current traffic, leg by leg between the via points.
/// Apple doesn't say how long it takes without traffic, so there's no delay figure.
struct AppleDriveTimer: DriveTimer {
    enum Failure: Error, CustomStringConvertible {
        case noRoute
        var description: String { "Apple Maps couldn't time that route." }
    }

    func time(_ points: [LatLon]) async throws -> DriveTime {
        var seconds = 0.0
        var meters = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon)))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon)))
            request.transportType = .automobile
            request.departureDate = Date().addingTimeInterval(seconds)
            guard let route = try await MKDirections(request: request).calculate().routes.first else { throw Failure.noRoute }
            seconds += route.expectedTravelTime
            meters += route.distance
        }
        return DriveTime(seconds: seconds, meters: meters)
    }
}

/// Turns a shared maps.app.goo.gl link into the full Google Maps link it points to.
enum MapsLinkExpander {
    static func expand(_ link: String) async throws -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GoogleMapsLink.isShort(trimmed), let url = URL(string: trimmed) else { return trimmed }
        // Take the short link's own redirect and stop: following on can end at a cookie-consent page.
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, let location = http.value(forHTTPHeaderField: "Location") {
            return location
        }
        return response.url?.absoluteString ?? trimmed
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    /// The route's points from any Google Maps directions link.
    static func points(from link: String) async throws -> [LatLon] {
        try GoogleMapsLink.points(from: try await expand(link))
    }
}
