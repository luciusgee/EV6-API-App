import MapKit
import PreconditionKit
import SwiftUI

/// "Burger King · Subway" under a charging stop, your chains first.
struct FoodLine: View {
    let names: [String]?
    let loading: Bool
    let chains: [FoodChain]
    var arrive: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "fork.knife").foregroundStyle(matched.isEmpty ? Color.secondary : .green).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                if loading && names == nil {
                    Text("Looking for food…").foregroundStyle(.secondary)
                } else if !matched.isEmpty {
                    Text(matched.map(\.name).joined(separator: " · ")).foregroundStyle(.primary)
                } else if let names, !names.isEmpty {
                    Text("Other food: \(names.prefix(3).joined(separator: ", "))").foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("No food nearby").foregroundStyle(.secondary)
                }
                Text([arrive.map { "Around \($0)" }, "Tap to see or change"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    private var matched: [FoodChain] { FoodMatch.chains(at: names ?? [], from: chains) }
}

/// One stop: the charger chosen, and every other one in reach with what there is to eat, to pick instead.
struct StopChoiceView: View {
    let options: [StopOption]
    let current: String
    let leaving: Date
    let food: FoodFinder
    let chains: [FoodChain]
    let sites: [String: ChargeSite]
    let miles: Bool
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var onlyWithFood = true
    /// The charger whose details are open, by id.
    @State private var details: String?

    private var shown: [StopOption] {
        // The chosen one first.
        let ordered = options.filter { $0.id == current } + options.filter { $0.id != current }
        guard onlyWithFood else { return ordered }
        return ordered.filter { o in
            // Keep ones still loading, and the current stop.
            o.id == current || food.food(at: o.charger) == nil || !FoodMatch.chains(at: food.food(at: o.charger) ?? [], from: chains).isEmpty
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("Only chargers with my food", isOn: $onlyWithFood)
            }
            Section {
                if shown.isEmpty {
                    Text("None of the chargers in reach have your food places. Turn off the filter to see them all.").foregroundStyle(.secondary)
                }
                ForEach(shown) { o in
                    HStack(spacing: 8) {
                        Button {
                            if o.id != current { onPick(o.id) }
                            dismiss()
                        } label: {
                            row(o).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        Button {
                            details = o.id
                        } label: {
                            Image(systemName: "info.circle").font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Details for \(o.charger.name)")
                    }
                }
            } header: {
                Text("Chargers in reach for this stop")
            } footer: {
                Text("Tap a charger to stop there, or ⓘ for its details and directions. Food within a short walk, from Apple Maps. Times assume you leave at \(leaving.formatted(date: .omitted, time: .shortened)).")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Choose a charger")
        .navigationDestination(item: $details) { id in
            if let site = sites[id] {
                ChargeSiteView(site: site)
            } else if let o = options.first(where: { $0.id == id }) {
                GuessedChargerView(charger: o.charger, area: food.area(of: o.charger))
            }
        }
        .task { await food.load(options.prefix(30).map(\.charger)) }
    }

    private func row(_ o: StopOption) -> some View {
        let names = food.food(at: o.charger)
        let matched = FoodMatch.chains(at: names ?? [], from: chains)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: o.id == current ? "checkmark.circle.fill" : "bolt.circle")
                    .foregroundStyle(o.id == current ? .green : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.charger.name).foregroundStyle(.primary).lineLimit(1)
                    if let area = food.area(of: o.charger) {
                        Label(area, systemImage: "mappin.and.ellipse").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(leaving.addingTimeInterval(o.minutesIn * 60).formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
            }
            Text([
                "\(DisplayText.distance(km: o.charger.alongKm, miles: miles)) in",
                "arrive \(Int(o.arrivePercent.rounded()))%",
                o.charger.powerGuessed ? "~\(Int(o.charger.powerKW)) kW" : "\(Int(o.charger.powerKW)) kW",
                sites[o.id].flatMap { $0.rapidCount > 0 ? "\($0.rapidCount) rapid" : nil },
            ].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if names == nil {
                Text("Looking for food…").font(.caption).foregroundStyle(.secondary)
            } else if matched.isEmpty {
                Text(names!.isEmpty ? "No food nearby" : "Other food: \(names!.prefix(3).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                ForEach(matched) { chain in
                    Label {
                        Text(chain.name).font(.caption.weight(.semibold)) + Text(chain.vegan.isEmpty ? "" : " · \(chain.vegan)").font(.caption)
                    } icon: {
                        Image(systemName: chain.vegan.isEmpty ? "fork.knife" : "leaf.fill").foregroundStyle(.green)
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A saved trip: its stops and food, ready to send to the car.
struct SavedTripView: View {
    let trip: SavedTrip
    @Environment(CarModel.self) private var car
    @Environment(TripsModel.self) private var trips
    @Environment(\.dismiss) private var dismiss
    /// Something was sent to the car from here, so its reply belongs on this screen.
    @State private var sent = false
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                if let leaving = trip.leaving {
                    LabeledContent("Leaving", value: leaving.formatted(date: .abbreviated, time: .shortened))
                }
                ForEach(Array(trip.stops.enumerated()), id: \.offset) { i, stop in
                    VStack(alignment: .leading, spacing: 4) {
                        if stop.isPlace == true {
                            Label(stop.name, systemImage: "mappin.circle.fill").font(.body.weight(.medium)).foregroundStyle(.orange)
                        } else {
                            Text("\(i + 1). \(stop.name)").font(.body.weight(.medium))
                        }
                        let detail = [stop.kW.map { "\(Int($0)) kW" }, stop.chargeMinutes.map { "about \(max(1, Int($0.rounded()))) min charging" }]
                            .compactMap { $0 }.joined(separator: " · ")
                        if !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                        if !stop.food.isEmpty {
                            Label(stop.food.joined(separator: " · "), systemImage: "leaf.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                }
                Label(trip.destination.name, systemImage: "mappin.circle.fill").foregroundStyle(.red)
            }
            Section {
                Button {
                    sent = true
                    Task { await car.send(.sendToCar(trip.navPoints)) }
                } label: {
                    HStack {
                        Label(sent && isSending ? "Sending…" : "Send to the car", systemImage: "car.side.arrowtriangle.up.fill")
                        if sent && isSending { Spacer(); ProgressView() }
                    }
                }
                .disabled(car.busy != nil)
                if let url = googleMapsURL {
                    Link(destination: url) { Label("Open in Google Maps", systemImage: "map") }
                }
                if sent, let message = car.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Puts the charging stops and destination in the car's sat nav. You'll need your Kia Connect PIN.")
            }
            Section {
                Button("Delete trip", role: .destructive) { confirmDelete = true }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this trip?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await trips.delete(trip.id)
                    dismiss()
                }
            }
        }
    }

    /// The car is busy sending this trip to its sat nav (not refreshing or doing something else).
    private var isSending: Bool {
        if case .some(.command(.sendToCar(_))) = car.busy { return true }
        return false
    }

    private var googleMapsURL: URL? {
        var c = URLComponents(string: "https://www.google.com/maps/dir/")!
        var items = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: "\(trip.destination.position.lat),\(trip.destination.position.lon)"),
            URLQueryItem(name: "travelmode", value: "driving"),
        ]
        if !trip.stops.isEmpty {
            items.append(URLQueryItem(name: "waypoints", value: trip.stops.map { "\($0.position.lat),\($0.position.lon)" }.joined(separator: "|")))
        }
        c.queryItems = items
        return c.url
    }
}

/// The food places you look for, favourites first.
struct FoodChainsView: View {
    @Environment(TripsModel.self) private var trips
    @State private var newName = ""
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                if trips.chains.isEmpty {
                    Text("No places yet. Add one below, or start from the vegan list.").foregroundStyle(.secondary)
                }
                ForEach(trips.chains) { chain in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chain.name)
                        if !chain.vegan.isEmpty { Text(chain.vegan).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .onMove { from, to in
                    var list = trips.chains
                    list.move(fromOffsets: from, toOffset: to)
                    Task { await trips.setChains(list) }
                }
                .onDelete { idx in
                    var list = trips.chains
                    list.remove(atOffsets: idx)
                    Task { await trips.setChains(list) }
                }
            } footer: {
                Text("Tap Edit to reorder; your favourites are listed first at each stop. Swipe to remove one.")
            }
            Section {
                HStack {
                    TextField("Add a place, e.g. Five Guys", text: $newName)
                        .submitLabel(.done)
                        .onSubmit { add() }
                    Button("Add") { add() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Reset to the vegan list") { confirmReset = true }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Food I look for")
        .toolbar { EditButton() }
        .confirmationDialog("Replace your list with the vegan list?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { Task { await trips.setChains(FoodChain.ukVegan) } }
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newName = ""
        guard !trips.chains.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return }
        Task { await trips.setChains(trips.chains + [FoodChain(name: name)]) }
    }
}
