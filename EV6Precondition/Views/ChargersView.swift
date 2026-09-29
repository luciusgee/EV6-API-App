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
    /// Starts framed around the car rather than zoomed in on it.
    init(near: LatLon?) {
        self.near = near
        if let near {
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: near.lat, longitude: near.lon), latitudinalMeters: 8000, longitudinalMeters: 8000)))
        }
    }
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
                    ForEach(results.prefix(25), id: \.self) { item in
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
        .refreshable { await search() }
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
        // Frame the area first, so the map never sits zoomed right in on the car.
        position = .region(MKCoordinateRegion(center: centre, latitudinalMeters: 8000, longitudinalMeters: 8000))
        var found = await ChargerSearch.near(centre, radius: 8000)
        if found.isEmpty {
            found = await ChargerSearch.near(centre, radius: 25000)
        }
        results = found.sorted { (distance($0) ?? 0) < (distance($1) ?? 0) }
        problem = results.isEmpty ? "No chargers found nearby. Pull down to try again." : nil
        if !results.isEmpty {
            // Fit the car and the nearest few.
            position = .automatic
        }
    }
}
