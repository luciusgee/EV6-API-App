import Foundation
import Observation

/// Time spent at your places: which are tracked, every stay, and totals for timesheets.
@MainActor
@Observable
public final class PresenceModel {
    public private(set) var log = PresenceLog()
    /// Runs when the tracked places change, so the geofences can follow.
    @ObservationIgnored public var onTrackedChange: (@MainActor (Set<String>) -> Void)?

    private let store: JSONFileStore<PresenceLog>
    private let time: TimeSource
    @ObservationIgnored private var loaded = false

    public nonisolated init(directory: URL, time: TimeSource = SystemTime()) {
        store = JSONFileStore(url: directory.appendingPathComponent("presence.json"), default: PresenceLog())
        self.time = time
    }

    public var now: Date { time.now() }
    public var tracked: Set<String> { log.trackedPlaceIds }

    public func load() async {
        log = await store.load()
        loaded = true
    }

    private func change(_ edit: (inout PresenceLog) -> Void) async {
        if !loaded { await load() }
        var copy = log
        edit(&copy)
        guard copy != log else { return }
        log = copy
        await store.save(copy)
    }

    public func setTracked(_ placeId: String, _ on: Bool) async {
        await change { if on { $0.trackedPlaceIds.insert(placeId) } else { $0.trackedPlaceIds.remove(placeId) } }
        onTrackedChange?(log.trackedPlaceIds)
    }

    public func arrived(_ placeId: String, at: Date, source: Visit.Source) async {
        await change { $0.arrive(placeId, at: at, source: source) }
    }

    public func left(_ placeId: String, at: Date, arrivedAt: Date? = nil, source: Visit.Source) async {
        await change { $0.leave(placeId, at: at, arrivedAt: arrivedAt, source: source) }
    }

    /// Adds or replaces a stay by hand.
    public func save(_ visit: Visit) async {
        await change { log in
            var v = visit
            v.source = .manual
            if let i = log.visits.firstIndex(where: { $0.id == v.id }) { log.visits[i] = v } else { log.visits.append(v) }
            log.visits.sort { $0.arrived < $1.arrived }
        }
    }

    public func delete(_ id: String) async {
        await change { $0.visits.removeAll { $0.id == id } }
    }

    /// Forgets a place's stays (and stops tracking it), e.g. when the place is deleted.
    public func forget(_ placeId: String) async {
        await change {
            $0.visits.removeAll { $0.placeId == placeId }
            $0.trackedPlaceIds.remove(placeId)
        }
        onTrackedChange?(log.trackedPlaceIds)
    }
}
