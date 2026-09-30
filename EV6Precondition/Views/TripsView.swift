import PreconditionKit
import SwiftUI

/// The Trips tab: planning a drive, your commutes, traffic on the way, saved trips and time at places.
struct TripsView: View {
    @Environment(CommuteModel.self) private var commutes
    @Environment(TripsModel.self) private var trips

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // The big way in: a card with a little road drawn across it.
                    ZStack {
                        WhereToCard()
                        NavigationLink { RoutePlannerView() } label: { EmptyView() }.opacity(0)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    NavigationLink {
                        TrafficAheadView()
                    } label: {
                        Label("Traffic ahead", systemImage: "road.lanes")
                    }
                }

                Section {
                    if !commutes.commutes.isEmpty { QuickCommuteButton() }
                    ForEach(commutes.commutes) { c in
                        NavigationLink {
                            CommuteDetailView(id: c.id)
                        } label: {
                            // The line under the name sits beside the icon, not under it.
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name)
                                    Text(commutes.advice[c.id]?.headline ?? "Tap to check the traffic")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            } icon: {
                                Image(systemName: c.name.localizedCaseInsensitiveContains("home") ? "house.fill" : "building.2.fill")
                            }
                        }
                    }
                    NavigationLink {
                        CommuteView()
                    } label: {
                        Label(commutes.commutes.isEmpty ? "Set up a commute" : "Manage commutes", systemImage: "car.rear.road.lane")
                    }
                } header: {
                    Text("Commute")
                }

                if !trips.trips.isEmpty {
                    Section {
                        ForEach(trips.trips.prefix(5)) { t in
                            NavigationLink {
                                SavedTripView(trip: t)
                            } label: {
                                SavedTripRow(trip: t)
                            }
                        }
                        .onDelete { idx in
                            let ids = idx.map { trips.trips[$0].id }
                            Task { for id in ids { await trips.delete(id) } }
                        }
                        if trips.trips.count > 5 {
                            NavigationLink("All saved trips (\(trips.trips.count))") {
                                SavedTripsList()
                            }
                        }
                    } header: {
                        Text("Saved trips")
                    }
                }

                Section {
                    NavigationLink {
                        TimeAtPlacesView()
                    } label: {
                        Label("Time at places", systemImage: "clock.badge.checkmark")
                    }
                    NavigationLink {
                        FoodChainsView()
                    } label: {
                        Label("Food I look for", systemImage: "fork.knife")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Trips")
        }
    }
}

/// A saved trip's name, with its stops under it.
private struct SavedTripRow: View {
    let trip: SavedTrip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(trip.name)
            Text(trip.stops.isEmpty ? "No stops" : trip.stops.map(\.name).joined(separator: " → "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// Every saved trip.
private struct SavedTripsList: View {
    @Environment(TripsModel.self) private var trips

    var body: some View {
        List {
            ForEach(trips.trips) { t in
                NavigationLink {
                    SavedTripView(trip: t)
                } label: {
                    SavedTripRow(trip: t)
                }
            }
            .onDelete { idx in
                let ids = idx.map { trips.trips[$0].id }
                Task { for id in ids { await trips.delete(id) } }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Saved trips")
    }
}

/// "Where to?" on a dark teal card, with a stylised route: start, a charging stop, the destination.
private struct WhereToCard: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(red: 0.03, green: 0.28, blue: 0.3), Color(red: 0.05, green: 0.09, blue: 0.12)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                // Kept to the right, clear of the words.
                let start = CGPoint(x: w * 0.7, y: h * 0.84)
                let stop = CGPoint(x: w * 0.81, y: h * 0.48)
                let end = CGPoint(x: w * 0.92, y: h * 0.17)
                Path { p in
                    p.move(to: start)
                    p.addQuadCurve(to: stop, control: CGPoint(x: w * 0.84, y: h * 0.8))
                    p.addQuadCurve(to: end, control: CGPoint(x: w * 0.83, y: h * 0.2))
                }
                .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 7]))
                Circle().fill(.white).frame(width: 9, height: 9).position(start)
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.black, .green)
                    .shadow(color: .green.opacity(0.7), radius: 6)
                    .position(stop)
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, .red)
                    .position(end)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("Where to?", systemImage: "magnifyingglass")
                    .font(.title2.weight(.bold))
                Text("Charging stops, food and\narrival times, planned for you")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)
            .padding(18)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
