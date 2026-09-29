import CoreLocation
import MapKit
import PreconditionKit
import SwiftUI

/// EV chargers near the car (or you): from Open Charge Map with details when there's a key, else Apple Maps.
struct ChargersView: View {
    let near: LatLon?
    @Environment(CarModel.self) private var car
    @State private var results: [MKMapItem] = []
    @State private var sites: [ChargeSite] = []
    @State private var minKW: Double = 0
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

    @State private var here: CLLocationCoordinate2D?

    private var centre: CLLocationCoordinate2D? {
        if let near { return CLLocationCoordinate2D(latitude: near.lat, longitude: near.lon) }
        return here
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
                    ForEach(shownSites.prefix(40)) { site in
                        Marker(site.name, systemImage: "ev.charger", coordinate: CLLocationCoordinate2D(latitude: site.position.lat, longitude: site.position.lon))
                            .tint((site.maxKW ?? 0) >= 100 ? .green : .teal)
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
            if !sites.isEmpty {
                Section {
                    Picker("Speed", selection: $minKW) {
                        Text("Any").tag(0.0)
                        Text("50 kW+").tag(50.0)
                        Text("100 kW+").tag(100.0)
                        Text("150 kW+").tag(150.0)
                    }
                    .pickerStyle(.segmented)
                    if shownSites.isEmpty {
                        Text("None this fast nearby. Try Any.").foregroundStyle(.secondary)
                    }
                    ForEach(shownSites) { site in
                        NavigationLink {
                            ChargeSiteView(site: site)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: site.operational == false ? "exclamationmark.triangle.fill" : "ev.charger.fill")
                                    .foregroundStyle(site.operational == false ? .red : ((site.maxKW ?? 0) >= 100 ? .green : .teal))
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(site.name).lineLimit(1)
                                    Text([site.operatorName, distanceText(site.position)].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(site.maxKW.map { "\(Int($0)) kW" } ?? "–").font(.subheadline.weight(.semibold)).monospacedDigit()
                                    let n = site.connectors.map(\.count).reduce(0, +)
                                    if n > 0 {
                                        Text("\(n) connector\(n == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } footer: {
                    Text("From Open Charge Map. Tap one for connectors, price, check-ins and directions.")
                }
            }
            Section {
                if searching {
                    HStack {
                        ProgressView()
                        Text("Finding chargers…").foregroundStyle(.secondary)
                    }
                }
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
                if sites.isEmpty && !results.isEmpty {
                    Text("From Apple Maps. Tap one for directions.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chargers nearby")
        .task {
            // Runs again on coming back from a charger; keep what's already found.
            if sites.isEmpty && results.isEmpty { await search() }
        }
        .refreshable { await search() }
        .onChange(of: selected) { _, item in
            guard let item else { return }
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            // So tapping the same marker again works.
            selected = nil
        }
    }

    private var shownSites: [ChargeSite] {
        sites.filter { ($0.maxKW ?? 0) >= minKW }
    }

    private func distanceText(_ p: LatLon) -> String? {
        guard let centre else { return nil }
        return DisplayText.distance(km: p.distance(to: LatLon(lat: centre.latitude, lon: centre.longitude)) / 1000, miles: car.settings.useMiles)
    }

    private func distance(_ item: MKMapItem) -> Double? {
        guard let centre else { return nil }
        let a = CLLocation(latitude: centre.latitude, longitude: centre.longitude)
        let c = item.placemark.coordinate
        return a.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    }

    private func search() async {
        if near == nil, here == nil {
            LocationAccess.shared.requestIfNeeded()
            if let fix = await LocationPhoneLocator().locate() {
                here = CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon)
            }
        }
        guard let centre else {
            problem = "Refresh the car, or allow location in Settings, to find chargers."
            return
        }
        searching = true
        defer { searching = false }
        // Frame the area first, so the map never sits zoomed right in on the car.
        position = .region(MKCoordinateRegion(center: centre, latitudinalMeters: 8000, longitudinalMeters: 8000))
        if let key = ChargerKeys.openChargeMap {
            let here = LatLon(lat: centre.latitude, lon: centre.longitude)
            do {
                let found = try await OpenChargeMapClient(transport: URLSessionTransport(), key: key).near(here, radiusKm: 8)
                sites = found.sorted { $0.position.distance(to: here) < $1.position.distance(to: here) }
                results = []
                problem = sites.isEmpty ? "No chargers found nearby. Pull down to try again." : nil
                return
            } catch {
                problem = (error as? OpenChargeMapClient.Failure)?.description
            }
        }
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
