import MapKit
import PreconditionKit
import SwiftUI

/// Traffic for the rest of the drive, the other ways to go, and sending the one you pick to the car's nav.
/// Kia doesn't share where the car's nav is heading, so the destination is chosen here (or remembered
/// from the last one sent to the car).
struct TrafficAheadView: View {
    @Environment(CarModel.self) private var car
    @Environment(CommuteModel.self) private var commutes
    @Environment(\.openURL) private var openURL
    @AppStorage("lastNavDestination") private var lastSentData: Data = Data()
    @State private var search = DestinationSearch()
    @State private var destination: NavPoint?
    @State private var from: LatLon?
    @State private var options: [DriveOption] = []
    @State private var selected: Int?
    @State private var loading = false
    @State private var problem: String?
    @State private var checkedAt: Date?
    @State private var camera: MapCameraPosition = .automatic

    private var lastSent: NavPoint? { try? JSONDecoder().decode(NavPoint.self, from: lastSentData) }
    private var fastest: DriveOption? { options.min { $0.time.seconds < $1.time.seconds } }
    private var chosen: DriveOption? { options.first { $0.id == selected } ?? fastest }

    var body: some View {
        List {
            destinationSection
            if !options.isEmpty {
                mapSection
                optionsSection
                actionsSection
            } else if loading {
                Section { HStack { ProgressView(); Text("Checking traffic…").foregroundStyle(.secondary) } }
            }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Traffic ahead")
        .refreshable { await check() }
        .onChange(of: search.query) { _, _ in search.update() }
        .task {
            if destination == nil, let lastSent {
                destination = lastSent
                await check()
            }
        }
    }

    // MARK: Destination

    private var quickPicks: [NavPoint] {
        var out: [NavPoint] = []
        if let lastSent { out.append(lastSent) }
        for c in commutes.commutes {
            if let end = c.routes.first?.points.last, !out.contains(where: { $0.position.distance(to: end) < 200 }) {
                out.append(NavPoint(name: c.name, position: end))
            }
        }
        return out
    }

    private var destinationSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Where are you heading?", text: $search.query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                if !search.query.isEmpty {
                    Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                }
            }
            if !search.query.isEmpty && search.query != destination?.name {
                ForEach(search.results, id: \.self) { result in
                    Button {
                        Task { await choose(result) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title).foregroundStyle(.primary)
                            if !result.subtitle.isEmpty { Text(result.subtitle).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            } else {
                ForEach(quickPicks, id: \.name) { pick in
                    Button {
                        destination = pick
                        search.query = ""
                        Task { await check() }
                    } label: {
                        Label(pick.name, systemImage: pick == lastSent ? "car.fill" : "house.fill")
                            .foregroundStyle(pick == destination ? Color.accentColor : .primary)
                    }
                }
            }
            if let destination {
                Label(destination.name, systemImage: "mappin.circle.fill").foregroundStyle(.red)
            }
        } header: {
            Text("Destination")
        } footer: {
            Text("Kia doesn't share where the car's nav is going, so pick it here. The last place sent to the car from this app is remembered.")
        }
    }

    // MARK: Results

    private var mapSection: some View {
        Section {
            Map(position: $camera) {
                ForEach(options.filter { $0.id != chosen?.id } + options.filter { $0.id == chosen?.id }) { option in
                    MapPolyline(coordinates: option.path.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                        .stroke(option.id == chosen?.id ? Color.blue : Color.gray.opacity(0.6), lineWidth: option.id == chosen?.id ? 6 : 4)
                }
                if let from {
                    Annotation("You", coordinate: CLLocationCoordinate2D(latitude: from.lat, longitude: from.lon)) {
                        Image(systemName: "car.fill").padding(5).background(.red, in: Circle()).foregroundStyle(.white)
                    }
                }
                if let destination {
                    Marker(destination.name, coordinate: CLLocationCoordinate2D(latitude: destination.position.lat, longitude: destination.position.lon))
                }
            }
            .frame(height: 260)
            .listRowInsets(EdgeInsets())
        } footer: {
            Text(TrafficAhead.summary(options))
        }
    }

    private var optionsSection: some View {
        Section {
            ForEach(options) { option in
                Button {
                    selected = option.id
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: option.id == chosen?.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(option.id == chosen?.id ? Color.blue : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.name).foregroundStyle(.primary)
                            Text(detail(option)).font(.caption).foregroundStyle(delayColour(option))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(TrafficAhead.duration(option.time.seconds)).font(.headline).monospacedDigit().foregroundStyle(.primary)
                            Text("arrive \(Date().addingTimeInterval(option.time.seconds).formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Ways to go")
        } footer: {
            if let checkedAt {
                Text("From where you are, checked \(checkedAt.formatted(date: .omitted, time: .shortened)). Pull down to check again.\(ChargerKeys.google == nil ? " Apple Maps traffic; a Google key in Settings adds how much is delay." : "")")
            }
        }
    }

    private func detail(_ option: DriveOption) -> String {
        var parts: [String] = []
        if let delay = option.time.delayMinutes { parts.append(delay < 5 ? "Clear" : "\(delay) min of traffic") }
        if let fastest, option.id != fastest.id {
            parts.append("\(Int(((option.time.seconds - fastest.time.seconds) / 60).rounded())) min slower")
        } else if options.count > 1 {
            parts.append("Quickest")
        }
        if let m = option.time.meters { parts.append(DisplayText.distance(km: m / 1000, miles: car.settings.useMiles)) }
        return parts.joined(separator: " · ")
    }

    private func delayColour(_ option: DriveOption) -> Color {
        guard let delay = option.time.delayMinutes else { return .secondary }
        return delay < 5 ? .green : (delay < 15 ? .orange : .red)
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await sendToCar() }
            } label: {
                HStack {
                    Label("Send this way to the car", systemImage: "car.side.arrowtriangle.up.fill")
                    if car.busy != nil { Spacer(); ProgressView() }
                }
            }
            .disabled(car.busy != nil)
            Button {
                if let url = googleMapsURL() { openURL(url) }
            } label: {
                Label("Open in Google Maps", systemImage: "map")
            }
            if let message = car.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Sends the destination, and a point on this way so the car's nav follows it, to the car. It asks on the car's screen before starting. Needs your Kia Connect PIN.")
        }
    }

    // MARK: Actions

    private func choose(_ result: MKLocalSearchCompletion) async {
        problem = nil
        guard let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: result)).start().mapItems.first else {
            problem = "Couldn't find that place."
            return
        }
        let c = item.placemark.coordinate
        destination = NavPoint(name: item.name ?? result.title, position: LatLon(lat: c.latitude, lon: c.longitude), address: item.placemark.title ?? "")
        search.query = ""
        await check()
    }

    private func check() async {
        guard let destination else { return }
        problem = nil
        loading = true
        defer { loading = false }
        LocationAccess.shared.requestIfNeeded()
        let here = await LocationPhoneLocator().locate() ?? car.snapshot?.parkingPosition
        guard let here else {
            problem = "Allow location so traffic can be checked from where you are."
            return
        }
        from = here
        do {
            if let key = ChargerKeys.google {
                options = try await GoogleRoutesClient(transport: URLSessionTransport(), key: key).alternatives(from: here, to: destination.position)
            } else {
                options = try await Self.appleOptions(from: here, to: destination.position)
            }
            selected = nil
            checkedAt = Date()
            camera = .automatic
        } catch {
            options = []
            problem = (error as? GoogleRoutesClient.Failure)?.description ?? "Couldn't get routes: \(error.localizedDescription)"
        }
    }

    static func appleOptions(from: LatLon, to: LatLon) async throws -> [DriveOption] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: from.lat, longitude: from.lon)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: to.lat, longitude: to.lon)))
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        request.departureDate = Date()
        let routes = try await MKDirections(request: request).calculate().routes
        return routes.enumerated().map { i, r -> DriveOption in
            let n = r.polyline.pointCount
            let pts = r.polyline.points()
            let path = (0..<n).map { k in
                let c = pts[k].coordinate
                return LatLon(lat: c.latitude, lon: c.longitude)
            }
            return DriveOption(id: i, name: r.name.isEmpty ? "Route \(i + 1)" : r.name,
                               time: DriveTime(seconds: r.expectedTravelTime, meters: r.distance), path: path)
        }
    }

    /// The destination, after a point that keeps the nav on the chosen way when it isn't the quickest.
    private var navPoints: [NavPoint] {
        guard let destination else { return [] }
        guard let chosen, chosen.id != fastest?.id,
              let via = TrafficAhead.distinctivePoint(of: chosen.path, avoiding: options.filter { $0.id != chosen.id }.map(\.path))
        else { return [destination] }
        return [NavPoint(name: "Via \(chosen.name)", position: via), destination]
    }

    private func sendToCar() async {
        let points = navPoints
        guard let destination, !points.isEmpty else { return }
        await car.send(.sendToCar(points))
        if let data = try? JSONEncoder().encode(destination) { lastSentData = data }
    }

    private func googleMapsURL() -> URL? {
        guard let destination else { return nil }
        var c = URLComponents(string: "https://www.google.com/maps/dir/")!
        var items = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: "\(destination.position.lat),\(destination.position.lon)"),
            URLQueryItem(name: "travelmode", value: "driving"),
        ]
        let vias = navPoints.dropLast()
        if !vias.isEmpty {
            items.append(URLQueryItem(name: "waypoints", value: vias.map { "\($0.position.lat),\($0.position.lon)" }.joined(separator: "|")))
        }
        c.queryItems = items
        return c.url
    }
}
