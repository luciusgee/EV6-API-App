import CoreLocation
import MapKit
import PreconditionKit
import SwiftUI

/// EV chargers near the car (or you), from Apple Maps. Tap one for directions.
struct ChargersView: View {
    let near: LatLon?
    @Environment(CarModel.self) private var car
    @State private var results: [MKMapItem] = []
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: MKMapItem?
    @State private var searching = false
    @State private var problem: String?

    private var centre: CLLocationCoordinate2D? {
        if let near { return CLLocationCoordinate2D(latitude: near.lat, longitude: near.lon) }
        return CLLocationManager().location?.coordinate
    }

    var body: some View {
        List {
            Section {
                Map(position: $position, selection: $selected) {
                    if let near {
                        Annotation("EV6", coordinate: CLLocationCoordinate2D(latitude: near.lat, longitude: near.lon)) {
                            Image(systemName: "car.fill")
                                .padding(6)
                                .background(.red, in: Circle())
                                .foregroundStyle(.white)
                        }
                    }
                    ForEach(results, id: \.self) { item in
                        Marker(item.name ?? "Charger", systemImage: "ev.charger", coordinate: item.placemark.coordinate)
                            .tint(.green)
                            .tag(item)
                    }
                }
                .frame(height: 300)
                .listRowInsets(EdgeInsets())
            }
            Section {
                if searching { ProgressView() }
                if let problem { Text(problem).foregroundStyle(.secondary) }
                ForEach(results, id: \.self) { item in
                    Button {
                        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
                    } label: {
                        HStack {
                            Image(systemName: "ev.charger.fill").foregroundStyle(.green).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "Charger").foregroundStyle(.primary)
                                if let address = item.placemark.title {
                                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if let d = distance(item) {
                                Text(DisplayText.distance(km: d / 1000, miles: car.settings.useMiles))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            } footer: {
                Text("From Apple Maps. Tap a charger for directions. Speeds and live availability depend on the network's own app.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chargers Nearby")
        .task { await search() }
        .onChange(of: selected) { _, item in
            item?.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        }
    }

    private func distance(_ item: MKMapItem) -> Double? {
        guard let centre else { return nil }
        let a = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        let c = item.placemark.coordinate
        return a.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    private func search() async {
        guard let centre else {
            problem = "Refresh the car or allow location to find chargers nearby."
            return
        }
        searching = true
        defer { searching = false }
        let request = MKLocalPointsOfInterestRequest(center: centre, radius: 8000)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.evCharger])
        do {
            let response = try await MKLocalSearch(request: request).start()
            results = response.mapItems.sorted { (distance($0) ?? 0) < (distance($1) ?? 0) }
            problem = results.isEmpty ? "No chargers found within 5 miles." : nil
            position = .region(MKCoordinateRegion(center: centre, latitudinalMeters: 6000, longitudinalMeters: 6000))
        } catch {
            problem = "Apple Maps didn't answer. Try again in a moment."
        }
    }
}
