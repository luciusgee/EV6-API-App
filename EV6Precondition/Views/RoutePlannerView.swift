import CoreLocation
import MapKit
import PreconditionKit
import SwiftUI

/// Trip planning for the EV6: where to charge, how long for, and what you'll arrive with.
struct RoutePlannerView: View {
    @Environment(CarModel.self) private var car
    @Environment(ChargingModel.self) private var charging
    @State private var search = DestinationSearch()
    @State private var destination: MKMapItem?
    @State private var trip = TripSettings()
    @State private var leaving = Date().addingTimeInterval(3600)
    @State private var found: RouteService.Found?
    @State private var plan: TripPlan?
    @State private var planning = false
    @State private var problem: String?
    @State private var outsideC: Double?
    @State private var chargedForTrip: String?
    @State private var camera: MapCameraPosition = .automatic
    /// Chargers you've picked to stop at.
    @State private var preferred: Set<String> = []
    @State private var minKW: Double = 50

    private var miles: Bool { car.settings.useMiles }
    @State private var here: CLLocationCoordinate2D?

    private var start: CLLocationCoordinate2D? {
        if let p = car.snapshot?.parkingPosition { return CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon) }
        return here
    }
    private var baseConsumption: Double { car.energy?.kWhPer100km ?? 18.5 }

    var body: some View {
        List {
            destinationSection
            if destination != nil {
                batterySection
                if let plan, let found {
                    resultSections(plan, found)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Plan a trip")
        .onAppear {
            if let soc = car.snapshot?.socPercent, plan == nil { trip.startPercent = Double(max(soc, 10)) }
            trip.usableKWh = charging.settings.usableKWh
        }
        .onChange(of: trip) { _, _ in replan() }
        .onChange(of: search.query) { _, _ in search.update() }
    }

    // MARK: Destination

    private var destinationSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Where to?", text: $search.query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !search.query.isEmpty {
                    Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("Clear")
                        .buttonStyle(.borderless)
                }
            }
            if destination == nil || search.query != (destination?.name ?? "") {
                ForEach(search.results, id: \.self) { result in
                    Button {
                        Task { await choose(result) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title).foregroundStyle(.primary)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if destination == nil, search.query.count >= 3, search.results.isEmpty {
                Text("No places found.").foregroundStyle(.secondary)
            }
            if let destination {
                Label(destination.name ?? "Destination", systemImage: "mappin.circle.fill").foregroundStyle(.red)
            }
        } header: {
            Text("Destination")
        } footer: {
            Text(car.snapshot?.parkingPosition != nil ? "From where your EV6 is parked." : "From where you are.")
        }
    }

    // MARK: Battery

    private var batterySection: some View {
        Section {
            RoundStepper("Leave with", value: $trip.startPercent, in: 10...100, step: 5, tint: .green) { "\(Int($0))%" }
            RoundStepper("Arrive at chargers with", value: $trip.minArrivalPercent, in: 5...30, step: 5) { "\(Int($0))%" }
            RoundStepper("Arrive at destination with", value: $trip.destinationPercent, in: 5...50, step: 5) { "\(Int($0))%" }
            RoundStepper("Charge stops up to", value: $trip.maxChargePercent, in: 60...100, step: 5, tint: .green) { "\(Int($0))%" }
            DatePicker("Leaving", selection: $leaving, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            if planning {
                HStack { ProgressView(); Text("Finding the route and chargers…").foregroundStyle(.secondary) }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } header: {
            Text("Battery")
        } footer: {
            Text(consumptionText)
        }
    }

    private var consumptionText: String {
        let model = consumptionModel
        let eff = DisplayText.efficiency(kWhPer100km: model.kWhPer100km, miles: miles) ?? ""
        var parts = ["Planning at \(eff)"]
        parts.append(car.energy?.kWhPer100km != nil ? "from your last 30 days" : "(typical EV6 AWD)")
        if model.speedFactor > 1.01 { parts.append(String(format: "+%.0f%% for motorway speed", (model.speedFactor - 1) * 100)) }
        if model.temperatureFactor > 1.01, let t = outsideC { parts.append(String(format: "+%.0f%% for %.0f °C", (model.temperatureFactor - 1) * 100, t)) }
        return parts.joined(separator: ", ") + "."
    }

    private var consumptionModel: ConsumptionModel {
        let avg: Double
        if let route = found?.route, route.expectedTravelTime > 0 {
            avg = route.distance / 1000 / (route.expectedTravelTime / 3600)
        } else {
            avg = 80
        }
        return ConsumptionModel(baseKWhPer100km: baseConsumption, averageKmh: avg, outsideC: outsideC, marginPercent: 5)
    }

    // MARK: Result

    @ViewBuilder
    private func resultSections(_ plan: TripPlan, _ found: RouteService.Found) -> some View {
        Section {
            Map(position: $camera) {
                MapPolyline(found.route.polyline).stroke(.blue, lineWidth: 5)
                if let start {
                    Annotation("EV6", coordinate: start) {
                        Image(systemName: "car.fill").padding(5).background(.red, in: Circle()).foregroundStyle(.white)
                    }
                }
                ForEach(Array(plan.stops.enumerated()), id: \.offset) { i, stop in
                    Marker("\(i + 1). \(stop.charger.name)", systemImage: "bolt.fill",
                           coordinate: CLLocationCoordinate2D(latitude: stop.charger.position.lat, longitude: stop.charger.position.lon))
                        .tint(.green)
                }
                if let d = destination {
                    Marker(d.name ?? "Destination", coordinate: d.placemark.coordinate).tint(.red)
                }
            }
            .frame(height: 260)
            .listRowInsets(EdgeInsets())

            HStack {
                summary(value: DisplayText.distance(km: plan.distanceKm, miles: miles), label: "distance")
                Divider()
                summary(value: DisplayText.duration(minutes: Int(plan.totalMinutes.rounded())), label: "total")
                Divider()
                summary(value: "\(plan.stops.count)", label: plan.stops.count == 1 ? "stop" : "stops")
                Divider()
                summary(value: "\(Int(plan.arrivePercent.rounded()))%", label: "on arrival")
            }
            .padding(.vertical, 4)
            if plan.unreachable {
                Label("Not enough fast chargers found along this route for these settings. Try leaving with more charge or allowing lower arrival charge.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Trip")
        } footer: {
            Text("Arriving \(leaving.addingTimeInterval(plan.totalMinutes * 60).formatted(date: .omitted, time: .shortened)) · \(DisplayText.duration(minutes: Int(plan.driveMinutes.rounded()))) driving, \(DisplayText.duration(minutes: Int(plan.chargeMinutes.rounded()))) charging.")
        }

        Section {
            legRow(icon: "car.fill", tint: .red, title: "Leave", detail: "with \(Int(trip.startPercent))%", trailing: leaving.formatted(date: .omitted, time: .shortened))
            ForEach(Array(plan.stops.enumerated()), id: \.offset) { i, stop in
                NavigationLink {
                    if let site = found.sites[stop.charger.id] {
                        ChargeSiteView(site: site)
                    } else {
                        GuessedChargerView(charger: stop.charger)
                    }
                } label: {
                VStack(alignment: .leading, spacing: 6) {
                    legRow(icon: "bolt.fill", tint: .green, title: "\(i + 1). \(stop.charger.name)",
                           detail: "Arrive \(Int(stop.arrivePercent.rounded()))% → charge to \(Int(stop.departPercent.rounded()))%",
                           trailing: DisplayText.duration(minutes: max(1, Int(stop.chargeMinutes.rounded()))))
                    HStack(spacing: 8) {
                        Text("\(DisplayText.distance(km: stop.charger.alongKm, miles: miles)) in")
                        Text("·")
                        Text(stop.charger.powerGuessed ? "~\(Int(stop.charger.powerKW)) kW (estimated)" : "\(Int(stop.charger.powerKW)) kW")
                        if let site = found.sites[stop.charger.id], site.rapidCount > 0 {
                            Text("·")
                            Text("\(site.rapidCount) rapid")
                        }
                        if preferred.contains(stop.charger.id) {
                            Image(systemName: "pin.fill").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                }
            }
            legRow(icon: "mappin.circle.fill", tint: .red, title: destination?.name ?? "Destination",
                   detail: "Arrive with \(Int(plan.arrivePercent.rounded()))%", trailing: "")
        } header: {
            Text("Route")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let problem = found.problem { Text(problem).foregroundStyle(.orange) }
                Text(found.sites.isEmpty
                     ? "Charger speeds are estimated. Add a free Open Charge Map key in Settings for real speeds, connectors and check-ins."
                     : "Tap a stop for its connectors, price and check-ins. Set it in the car's sat nav so the battery warms up for faster charging.")
            }
        }

        if !found.sites.isEmpty {
            allChargersSection(found)
        }

        Section {
            if let url = RouteService.googleMapsURL(from: start ?? found.route.polyline.coordinate, to: destination?.placemark.coordinate ?? found.route.polyline.coordinate, stops: plan.stops) {
                Link(destination: url) {
                    Label("Open the route in Google Maps", systemImage: "map")
                }
            }
            Button {
                if let first = plan.stops.first { directions(to: first.charger) } else { destination?.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]) }
            } label: {
                Label(plan.stops.isEmpty ? "Directions in Apple Maps" : "Directions to the first stop", systemImage: "location.fill")
            }
            chargeForTripRow(plan)
        }
    }

    /// Every charger along the route, to look at or to plan around.
    private func allChargersSection(_ found: RouteService.Found) -> some View {
        let sites = found.chargers
            .compactMap { c in found.sites[c.id].map { (c, $0) } }
            .filter { ($0.1.maxKW ?? 0) >= minKW }
        return Section {
            Picker("At least", selection: $minKW) {
                Text("50 kW").tag(50.0)
                Text("100 kW").tag(100.0)
                Text("150 kW").tag(150.0)
            }
            .pickerStyle(.segmented)
            if sites.isEmpty {
                Text("None this fast along the route.").foregroundStyle(.secondary)
            }
            ForEach(sites, id: \.0.id) { charger, site in
                NavigationLink {
                    ChargeSiteView(site: site)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.name).lineLimit(1)
                            Text([site.operatorName, "\(DisplayText.distance(km: charger.alongKm, miles: miles)) in"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(site.maxKW.map { "\(Int($0)) kW" } ?? "–").font(.subheadline.weight(.semibold)).monospacedDigit()
                            Text("\(max(site.rapidCount, 1)) \(site.rapidCount == 1 ? "charger" : "chargers")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button {
                        if preferred.contains(charger.id) { preferred.remove(charger.id) } else { preferred.insert(charger.id) }
                        replan()
                    } label: {
                        Label(preferred.contains(charger.id) ? "Don't prefer" : "Stop here", systemImage: "pin")
                    }
                    .tint(.orange)
                }
            }
        } header: {
            Text("Chargers on the route")
        } footer: {
            Text("Swipe left on one to plan a stop there. From Open Charge Map.")
        }
    }

    @ViewBuilder
    private func chargeForTripRow(_ plan: TripPlan) -> some View {
        let needed = Int((trip.startPercent / 10).rounded(.up) * 10)
        let current = car.snapshot?.socPercent ?? 0
        if needed > current {
            Button {
                Task { await chargeForTrip(to: needed) }
            } label: {
                Label("Charge to \(needed)% by \(leaving.formatted(date: .omitted, time: .shortened))", systemImage: "bolt.badge.clock")
            }
            .disabled(car.busy != nil)
            if let noStop = plan.noStopStartPercent, !plan.stops.isEmpty, noStop <= 100 {
                Text("Leave with \(Int(noStop.rounded(.up)))% and you won't need to stop.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        if let chargedForTrip {
            Text(chargedForTrip).font(.footnote).foregroundStyle(.green)
        }
    }

    private func summary(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func legRow(icon: String, tint: Color, title: String, detail: String, trailing: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(trailing).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }

    // MARK: Actions

    private func choose(_ result: MKLocalSearchCompletion) async {
        problem = nil
        guard let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: result)).start().mapItems.first else {
            problem = "Couldn't find that place."
            return
        }
        destination = item
        search.query = item.name ?? result.title
        await planRoute()
    }

    private func planRoute() async {
        if car.snapshot?.parkingPosition == nil, here == nil {
            LocationAccess.shared.requestIfNeeded()
            if let fix = await LocationPhoneLocator().locate() {
                here = CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon)
            }
        }
        guard let destination, let start else {
            problem = "Refresh the car or allow location so the trip has a start."
            return
        }
        planning = true
        defer { planning = false }
        do {
            if outsideC == nil {
                outsideC = await AppServices.shared.container.weather.current(at: LatLon(lat: start.latitude, lon: start.longitude))?.celsius
            }
            found = try await RouteService.route(from: start, to: destination)
            camera = .automatic
            replan()
        } catch {
            problem = (error as? RouteService.Failure)?.description ?? "Apple Maps couldn't plan that route."
        }
    }

    private func replan() {
        guard let found else { return }
        plan = RoutePlanner.plan(
            distanceKm: found.route.distance / 1000,
            driveMinutes: found.route.expectedTravelTime / 60,
            chargers: found.chargers,
            trip: trip,
            model: consumptionModel,
            prefer: preferred
        )
    }

    private func directions(to charger: RouteCharger) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: charger.position.lat, longitude: charger.position.lon)))
        item.name = charger.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    /// Sets smart charging to have the car at `percent` by departure, and the car's AC limit to match.
    private func chargeForTrip(to percent: Int) async {
        let ready = ClockTime(hour: Calendar.current.component(.hour, from: leaving), minute: Calendar.current.component(.minute, from: leaving))
        await charging.update {
            $0.smart.enabled = true
            $0.smart.targetPercent = percent
            $0.smart.readyBy = ready
        }
        charging.replan(soc: car.snapshot?.socPercent)
        await ChargingCoordinator.shared.remindAtWindowStart()
        ChargingCoordinator.shared.scheduleBackgroundRefresh()
        if let limit = car.snapshot?.details?.chargeLimitAC, limit < percent {
            await car.send(.setChargeLimits(ac: percent, dc: car.snapshot?.details?.chargeLimitDC ?? 80))
        }
        if let p = charging.plan {
            chargedForTrip = "Smart charging will charge \(p.start.formatted(date: .omitted, time: .shortened))–\(p.end.formatted(date: .omitted, time: .shortened)) for about \(DisplayText.money(pence: p.costPence))."
        } else {
            chargedForTrip = "Smart charging is set to \(percent)% by \(ready.text)."
        }
    }
}

/// Apple Maps' type-ahead for places.
@MainActor
@Observable
final class DestinationSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = ""
    private(set) var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Call when `query` changes.
    func update() {
        if query.count < 2 {
            results = []
        } else {
            completer.queryFragment = query
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = Array(completer.results.prefix(6))
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}

/// A charger found through Apple Maps, without Open Charge Map's details.
struct GuessedChargerView: View {
    let charger: RouteCharger

    var body: some View {
        List {
            Section {
                Text(charger.name).font(.headline)
                LabeledContent("Speed", value: "~\(Int(charger.powerKW)) kW (estimated)")
            } footer: {
                Text("Add a free Open Charge Map key in Settings for its connectors, price and drivers' check-ins.")
            }
            Section {
                Button {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: charger.position.lat, longitude: charger.position.lon)))
                    item.name = charger.name
                    item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
                } label: {
                    Label("Directions in Apple Maps", systemImage: "location.fill")
                }
            }
        }
        .navigationTitle("Charger")
    }
}
