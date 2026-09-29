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
                    NavigationLink {
                        RoutePlannerView()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "magnifyingglass")
                                .font(.title3.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .background(Color.accentColor.opacity(0.18), in: Circle())
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Where to?").font(.title3.weight(.semibold))
                                Text("Charging stops, food and arrival times").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    NavigationLink {
                        TrafficAheadView()
                    } label: {
                        Label("Traffic ahead", systemImage: "road.lanes")
                    }
                }

                Section {
                    ForEach(commutes.commutes) { c in
                        NavigationLink {
                            CommuteDetailView(id: c.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(c.name, systemImage: c.name.localizedCaseInsensitiveContains("home") ? "house.fill" : "building.2.fill")
                                Text(commutes.advice[c.id]?.headline ?? "Tap to check the traffic")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
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
