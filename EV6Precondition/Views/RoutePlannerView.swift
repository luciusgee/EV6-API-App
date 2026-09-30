import CoreLocation
import MapKit
import PreconditionKit
import SwiftUI

/// Trip planning for the EV6: where to charge, how long for, and what you'll arrive with.
struct RoutePlannerView: View {
    @Environment(CarModel.self) private var car
    @Environment(ChargingModel.self) private var charging
    @Environment(TripsModel.self) private var trips
    @State private var food = FoodFinder()
    @State private var savingTrip = false
    @State private var tripName = ""
    @State private var savedNote: String?
    /// This trip has been saved, so Save doesn't make a copy.
    @State private var saved = false
    /// Something was sent to the car from here, so its reply belongs on this screen.
    @State private var sent = false
    @State private var settingCharge = false
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

    /// Where the trip starts: the car, you, or a place you pick.
    enum Origin: Hashable { case car, me, place }
    @State private var origin: Origin = .car
    @State private var fromSearch = DestinationSearch()
    @State private var fromPlace: MKMapItem?

    private var start: CLLocationCoordinate2D? {
        switch origin {
        case .car:
            if let p = car.snapshot?.parkingPosition { return CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon) }
            return here
        case .me:
            return here
        case .place:
            return fromPlace?.placemark.coordinate
        }
    }

    private var startName: String {
        switch origin {
        case .car: return car.snapshot?.parkingPosition != nil ? "EV6" : "You"
        case .me: return "You"
        case .place: return fromPlace?.name ?? "Start"
        }
    }
    private var baseConsumption: Double { car.energy?.kWhPer100km ?? 18.5 }

    var body: some View {
        List {
            tripSection
            if destination == nil {
                savedTripsSection
            } else {
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
        .onChange(of: fromSearch.query) { _, _ in fromSearch.update() }
        .onChange(of: origin) { _, _ in
            outsideC = nil
            clearResults()
            if destination != nil, origin != .place || fromPlace != nil { Task { await planRoute() } }
        }
        .task(id: plan?.stops.map(\.id)) {
            if let plan { await food.load(plan.stops.map(\.charger)) }
        }
        .alert("Save trip", isPresented: $savingTrip) {
            TextField("Name", text: $tripName)
            Button("Save") { Task { await saveTrip() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: From, to, when

    private var tripSection: some View {
        Section {
            Picker(selection: $origin) {
                Text("The car").tag(Origin.car)
                Text("Me").tag(Origin.me)
                Text("Somewhere else").tag(Origin.place)
            } label: {
                Label("From", systemImage: "circle.circle")
            }
            .pickerStyle(.menu)
            if origin == .place {
                placeSearch("Starting from?", search: $fromSearch.query, results: fromSearch.results,
                            showResults: fromPlace == nil || fromSearch.query != (fromPlace?.name ?? ""),
                            onClear: {
                                fromSearch.query = ""
                                fromPlace = nil
                                clearResults()
                            }) { r in
                    Task { await chooseStart(r) }
                }
            }
            placeSearch("Where to?", search: $search.query, results: search.results,
                        showResults: destination == nil || search.query != (destination?.name ?? ""),
                        onClear: {
                            search.query = ""
                            destination = nil
                            problem = nil
                            clearResults()
                        }) { r in
                Task { await choose(r) }
            }
            if destination == nil, search.query.count >= 3, search.results.isEmpty, !search.searching {
                Text("No places found.").foregroundStyle(.secondary)
            }
            DatePicker(selection: $leaving, in: Date()..., displayedComponents: [.date, .hourAndMinute]) {
                Label("Leaving", systemImage: "clock")
            }
            if planning {
                HStack { ProgressView(); Text("Finding the route and chargers…").foregroundStyle(.secondary) }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    /// A search field with Apple Maps suggestions under it.
    @ViewBuilder
    private func placeSearch(_ prompt: String, search: Binding<String>, results: [MKLocalSearchCompletion], showResults: Bool,
                             onClear: @escaping () -> Void,
                             pick: @escaping (MKLocalSearchCompletion) -> Void) -> some View {
        HStack {
            Image(systemName: prompt == "Where to?" ? "mappin.circle.fill" : "circle.circle.fill")
                .foregroundStyle(prompt == "Where to?" ? Color.red : .blue)
            TextField(prompt, text: search)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !search.wrappedValue.isEmpty {
                Button { onClear() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("Clear")
                    .buttonStyle(.borderless)
            }
        }
        if showResults {
            ForEach(results, id: \.self) { result in
                Button {
                    pick(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title).foregroundStyle(.primary)
                        if !result.subtitle.isEmpty { Text(result.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.leading, 30)
                }
            }
        }
    }

    // MARK: Battery

    private var batterySection: some View {
        Section {
            RoundStepper("Leave with", value: $trip.startPercent, in: 10...100, step: 5, tint: .green) { "\(Int($0))%" }
            DisclosureGroup {
                RoundStepper("Arrive at chargers with", value: $trip.minArrivalPercent, in: 5...30, step: 5) { "\(Int($0))%" }
                RoundStepper("Arrive at destination with", value: $trip.destinationPercent, in: 5...50, step: 5) { "\(Int($0))%" }
                RoundStepper("Charge stops up to", value: $trip.maxChargePercent, in: 60...100, step: 5, tint: .green) { "\(Int($0))%" }
            } label: {
                LabeledContent("Charging stops") {
                    Text("\(Int(trip.minArrivalPercent))% → \(Int(trip.maxChargePercent))% · arrive \(Int(trip.destinationPercent))%")
                        .monospacedDigit()
                }
            }
        } footer: {
            Text(consumptionText)
        }
    }

    private var consumptionText: String {
        let model = consumptionModel
        let eff = DisplayText.efficiency(kWhPer100km: model.kWhPer100km, miles: miles) ?? ""
        var parts = ["Planning at \(eff)" + (car.energy?.kWhPer100km != nil ? ", from your last 30 days" : " (a typical EV6 AWD figure)")]
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

    private func time(_ minutesIn: Double) -> String {
        leaving.addingTimeInterval(minutesIn * 60).formatted(date: .omitted, time: .shortened)
    }

    @ViewBuilder
    private func resultSections(_ plan: TripPlan, _ found: RouteService.Found) -> some View {
        Section {
            Map(position: $camera) {
                MapPolyline(found.route.polyline).stroke(.blue, lineWidth: 5)
                if let start {
                    Annotation(startName, coordinate: start) {
                        Image(systemName: origin == .place ? "circle.circle.fill" : "car.fill")
                            .padding(5).background(origin == .place ? Color.blue : .red, in: Circle()).foregroundStyle(.white)
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
            .frame(height: 240)
            .listRowInsets(EdgeInsets())

            HStack {
                summary(value: time(plan.totalMinutes), label: "arrive")
                Divider()
                summary(value: DisplayText.duration(minutes: Int(plan.totalMinutes.rounded())), label: "total")
                Divider()
                summary(value: "\(plan.stops.count)", label: plan.stops.count == 1 ? "stop" : "stops")
                Divider()
                summary(value: "\(Int(plan.arrivePercent.rounded()))%", label: "left")
            }
            .padding(.vertical, 4)
            if plan.unreachable {
                Label("Not enough fast chargers on this route for these settings. Leave with more charge, or allow a lower charge at stops.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text("\(DisplayText.distance(km: plan.distanceKm, miles: miles)) · \(DisplayText.duration(minutes: Int(plan.driveMinutes.rounded()))) driving, \(DisplayText.duration(minutes: Int(plan.chargeMinutes.rounded()))) charging.")
        }

        Section {
            legRow(icon: origin == .place ? "circle.circle.fill" : "car.fill", tint: origin == .place ? .blue : .red,
                   title: "Leave \(origin == .place ? (fromPlace?.name ?? "") : "")".trimmingCharacters(in: .whitespaces),
                   detail: "with \(Int(trip.startPercent))%", trailing: time(0))
            ForEach(Array(plan.stops.enumerated()), id: \.offset) { i, stop in
                let arrive = minutesIn(stop: i, plan, found)
                NavigationLink {
                    StopChoiceView(
                        options: stopOptions(for: i, plan, found),
                        current: stop.charger.id,
                        leaving: leaving,
                        food: food,
                        chains: trips.chains,
                        sites: found.sites,
                        miles: miles
                    ) { picked in
                        let others = Set(stopOptions(for: i, plan, found).map(\.id))
                        preferred.subtract(others)
                        preferred.insert(picked)
                        replan()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        legRow(icon: "bolt.fill", tint: .green, title: stop.charger.name,
                               detail: "\(Int(stop.arrivePercent.rounded()))% → \(Int(stop.departPercent.rounded()))% · \(DisplayText.duration(minutes: max(1, Int(stop.chargeMinutes.rounded())))) charging",
                               trailing: time(arrive))
                        Text([
                            food.area(of: stop.charger),
                            "\(DisplayText.distance(km: stop.charger.alongKm, miles: miles)) in",
                            stop.charger.powerGuessed ? "~\(Int(stop.charger.powerKW)) kW" : "\(Int(stop.charger.powerKW)) kW",
                            found.sites[stop.charger.id].flatMap { $0.rapidCount > 0 ? "\($0.rapidCount) rapid" : nil },
                            "leave \(time(arrive + stop.chargeMinutes + 5))",
                        ].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 36)
                        FoodLine(names: food.food(at: stop.charger), loading: food.loading.contains(stop.charger.id), chains: trips.chains)
                            .padding(.leading, 4)
                    }
                }
            }
            legRow(icon: "mappin.circle.fill", tint: .red, title: destination?.name ?? "Destination",
                   detail: "Arrive with \(Int(plan.arrivePercent.rounded()))%", trailing: time(plan.totalMinutes))
        } header: {
            Text("Route")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let problem = found.problem { Text(problem).foregroundStyle(.orange) }
                Text("Tap a stop to see the other chargers in reach and pick a different one. Send the trip to the car so the battery warms up before each stop.")
            }
        }

        Section {
            Button {
                Task {
                    if let t = savedTrip(name: defaultTripName) {
                        sent = true
                        await car.send(.sendToCar(t.navPoints))
                    }
                }
            } label: {
                HStack {
                    Spacer()
                    if sent, isSending {
                        ProgressView().tint(.white)
                        Text("Sending…")
                    } else {
                        Label("Send to the car", systemImage: "car.side.arrowtriangle.up.fill")
                    }
                    Spacer()
                }
                .font(.headline)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .disabled(car.busy != nil)
            HStack(spacing: 10) {
                Button {
                    tripName = defaultTripName
                    savingTrip = true
                } label: {
                    Label(saved ? "Saved" : "Save", systemImage: saved ? "bookmark.fill" : "bookmark").frame(maxWidth: .infinity)
                }
                .disabled(saved)
                Menu {
                    if let url = RouteService.googleMapsURL(from: start ?? found.route.polyline.coordinate,
                                                            to: destination?.placemark.coordinate ?? found.route.polyline.coordinate, stops: plan.stops) {
                        Link(destination: url) { Label("Open in Google Maps", systemImage: "map") }
                    }
                    Button {
                        if let first = plan.stops.first { directions(to: first.charger) } else { destination?.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]) }
                    } label: {
                        Label(plan.stops.isEmpty ? "Directions in Apple Maps" : "Apple Maps to the first stop", systemImage: "location.fill")
                    }
                } label: {
                    Label("Open in…", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let savedNote { Text(savedNote).foregroundStyle(.green) }
                if sent, let message = car.message { Text(message) }
                Text("Puts the charging stops and destination in the car's sat nav. You'll need your Kia Connect PIN.")
            }
        }

        let chargeRow = chargeForTripNeeded(plan)
        if chargeRow {
            Section { chargeForTripRow(plan) }
        }

        if !found.sites.isEmpty {
            allChargersSection(found)
        }
    }

    // MARK: Food and saved trips

    private func stopOptions(for i: Int, _ plan: TripPlan, _ found: RouteService.Found) -> [StopOption] {
        RoutePlanner.stopOptions(for: i, in: plan, distanceKm: found.route.distance / 1000, driveMinutes: found.route.expectedTravelTime / 60,
                                 chargers: found.chargers, trip: trip, model: consumptionModel)
    }

    private func minutesIn(stop i: Int, _ plan: TripPlan, _ found: RouteService.Found) -> Double {
        let perKm = found.route.distance > 0 ? (found.route.expectedTravelTime / 60) / (found.route.distance / 1000) : 1
        let earlier = plan.stops[..<i].map { $0.chargeMinutes + 5 }.reduce(0, +)
        return plan.stops[i].charger.alongKm * perKm + earlier
    }

    private var defaultTripName: String {
        let day = leaving.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(destination?.name ?? "Trip") · \(day)"
    }

    private func savedTrip(name: String) -> SavedTrip? {
        guard let plan, let destination else { return nil }
        let d = destination.placemark.coordinate
        let stops = plan.stops.map { s in
            SavedTrip.Stop(
                name: s.charger.name, position: s.charger.position, kW: s.charger.powerGuessed ? nil : s.charger.powerKW,
                chargeMinutes: s.chargeMinutes,
                food: FoodMatch.chains(at: food.food(at: s.charger) ?? [], from: trips.chains).map(\.name)
            )
        }
        return SavedTrip(name: name, destination: NavPoint(name: destination.name ?? "Destination", position: LatLon(lat: d.latitude, lon: d.longitude),
                                                           address: destination.placemark.title ?? ""),
                         stops: stops, leaving: leaving)
    }

    private func saveTrip() async {
        guard let t = savedTrip(name: tripName.isEmpty ? defaultTripName : tripName) else { return }
        await trips.save(t)
        saved = true
        savedNote = "Saved to your trips."
    }

    @ViewBuilder
    private var savedTripsSection: some View {
        Section {
            ForEach(trips.trips) { t in
                NavigationLink {
                    SavedTripView(trip: t)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name)
                        Text(t.stops.isEmpty ? "No stops" : t.stops.map { s in s.food.first.map { "\(s.name) (\($0))" } ?? s.name }.joined(separator: " → "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .onDelete { idx in
                let ids = idx.map { trips.trips[$0].id }
                Task { for id in ids { await trips.delete(id) } }
            }
            NavigationLink {
                FoodChainsView()
            } label: {
                Label("Food I look for", systemImage: "fork.knife")
            }
        } header: {
            if !trips.trips.isEmpty { Text("Saved trips") }
        } footer: {
            Text("Choose the food places to look for at each charging stop.")
        }
    }

    /// Every charger along the route, to look at or to plan around.
    private func allChargersSection(_ found: RouteService.Found) -> some View {
        let sites = found.chargers
            .compactMap { c in found.sites[c.id].map { (c, $0) } }
            .filter { ($0.1.maxKW ?? 0) >= minKW }
        return Section {
            DisclosureGroup("All chargers on the route (\(found.chargers.filter { found.sites[$0.id] != nil }.count))") {
            Picker("At least", selection: $minKW) {
                Text("50 kW+").tag(50.0)
                Text("100 kW+").tag(100.0)
                Text("150 kW+").tag(150.0)
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
                            let n = max(site.rapidCount, 1)
                            Text("\(n) \(n == 1 ? "charger" : "chargers")").font(.caption).foregroundStyle(.secondary)
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
            }
        } footer: {
            Text("Swipe left on one to plan a stop there.")
        }
    }

    private func chargeForTripNeeded(_ plan: TripPlan) -> Bool {
        guard origin == .car, let soc = car.snapshot?.socPercent else { return chargedForTrip != nil }
        return Int((trip.startPercent / 10).rounded(.up) * 10) > soc || chargedForTrip != nil
    }

    @ViewBuilder
    private func chargeForTripRow(_ plan: TripPlan) -> some View {
        let needed = Int((trip.startPercent / 10).rounded(.up) * 10)
        if let current = car.snapshot?.socPercent, needed > current {
            Button {
                Task {
                    settingCharge = true
                    await chargeForTrip(to: needed)
                    settingCharge = false
                }
            } label: {
                HStack {
                    Label("Charge to \(needed)% by \(leaving.formatted(date: .omitted, time: .shortened))", systemImage: "bolt.badge.clock")
                    if settingCharge { Spacer(); ProgressView() }
                }
            }
            .disabled(car.busy != nil || settingCharge)
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
        clearResults()
        await planRoute()
    }

    private func chooseStart(_ result: MKLocalSearchCompletion) async {
        problem = nil
        guard let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: result)).start().mapItems.first else {
            problem = "Couldn't find that place."
            return
        }
        fromPlace = item
        fromSearch.query = item.name ?? result.title
        outsideC = nil
        if destination != nil {
            clearResults()
            await planRoute()
        }
    }

    private func planRoute() async {
        let needsMe = origin == .me || (origin == .car && car.snapshot?.parkingPosition == nil)
        if needsMe, here == nil {
            LocationAccess.shared.requestIfNeeded()
            if let fix = await LocationPhoneLocator().locate() {
                here = CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon)
            }
        }
        guard let destination, let start else {
            problem = origin == .place ? "Pick where the trip starts." : "Refresh the car or allow location so the trip has a start."
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

    /// Forgets the last route and anything done with it, when where the trip starts or ends changes.
    private func clearResults() {
        found = nil
        plan = nil
        preferred = []
        savedNote = nil
        chargedForTrip = nil
        saved = false
        sent = false
    }

    /// The car is busy sending a trip to its sat nav (not refreshing or doing something else).
    private var isSending: Bool {
        if case .some(.command(.sendToCar(_))) = car.busy { return true }
        return false
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
    /// Waiting for Apple Maps to suggest places for the latest query.
    private(set) var searching = false
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
            searching = false
        } else {
            searching = true
            completer.queryFragment = query
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = Array(completer.results.prefix(6))
        Task { @MainActor in
            self.results = results
            self.searching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.searching = false }
    }
}

/// A charger found through Apple Maps, without Open Charge Map's details.
struct GuessedChargerView: View {
    let charger: RouteCharger
    var area: String?

    var body: some View {
        List {
            Section {
                Text(charger.name).font(.headline)
                if let area { LabeledContent("Where", value: area) }
                LabeledContent("Speed", value: "~\(Int(charger.powerKW)) kW (estimated)")
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
