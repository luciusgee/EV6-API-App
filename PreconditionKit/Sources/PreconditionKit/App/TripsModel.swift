import Foundation
import Observation

/// Saved trips and the food chains you look for.
@MainActor
@Observable
public final class TripsModel {
    public private(set) var trips: [SavedTrip] = []
    /// Favourites first.
    public private(set) var chains: [FoodChain] = FoodChain.ukVegan

    private let tripsStore: JSONFileStore<[SavedTrip]>
    private let chainsStore: JSONFileStore<[FoodChain]>

    public nonisolated init(directory: URL) {
        tripsStore = JSONFileStore(url: directory.appendingPathComponent("trips.json"), default: [])
        chainsStore = JSONFileStore(url: directory.appendingPathComponent("food-chains.json"), default: FoodChain.ukVegan)
    }

    public func load() async {
        trips = await tripsStore.load()
        chains = await chainsStore.load()
    }

    public func save(_ trip: SavedTrip) async {
        if let i = trips.firstIndex(where: { $0.id == trip.id }) { trips[i] = trip } else { trips.insert(trip, at: 0) }
        await tripsStore.save(trips)
    }

    public func delete(_ id: UUID) async {
        trips.removeAll { $0.id == id }
        await tripsStore.save(trips)
    }

    public func setChains(_ new: [FoodChain]) async {
        chains = new
        await chainsStore.save(new)
    }
}
