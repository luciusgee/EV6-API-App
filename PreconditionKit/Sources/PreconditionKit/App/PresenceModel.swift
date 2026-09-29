import Foundation
import Observation

/// Time spent at your places: which are tracked, every stay, and totals for timesheets.
@MainActor
@Observable
public final class PresenceModel {
    public private(set) var log = PresenceLog()
    public private(set) var movements = CarMovements()
    public private(set) var loadingTrips = false
    public var problem: String?
    /// Set by the app: fetches one day of the car's trips (one Kia request).
    @ObservationIgnored public var fetchTrips: (@MainActor (CalendarDay, RequestKind) async -> ApiResult<[CarTrip]>)?
    /// Set by the app: the places, to match where the car was parked.
    @ObservationIgnored public var places: (@MainActor () -> [Place])?
    /// Runs when the tracked places change, so the geofences can follow.
    @ObservationIgnored public var onTrackedChange: (@MainActor (Set<String>) -> Void)?

    private let store: JSONFileStore<PresenceLog>
    private let movementsStore: JSONFileStore<CarMovements>
    private let time: TimeSource
    @ObservationIgnored private var loaded = false

    public nonisolated init(directory: URL, time: TimeSource = SystemTime()) {
        store = JSONFileStore(url: directory.appendingPathComponent("presence.json"), default: PresenceLog())
        movementsStore = JSONFileStore(url: directory.appendingPathComponent("car-movements.json"), default: CarMovements())
        self.time = time
    }

    public var now: Date { time.now() }
    public var tracked: Set<String> { log.trackedPlaceIds }

    public func load() async {
        log = await store.load()
        movements = await movementsStore.load()
        loaded = true
    }

    public func setMode(_ mode: PresenceLog.Mode) async {
        await change { $0.mode = mode }
        onTrackedChange?(log.trackedPlaceIds)
    }

    /// Whether the phone's location should be watched for time tracking.
    public var watchesPhone: Bool { log.mode == .phone && !log.trackedPlaceIds.isEmpty }

    // MARK: - The car's trips

    /// Notes where the car is parked, from each read of its state.
    public func sawCar(_ snapshot: VehicleSnapshot) async {
        guard let position = snapshot.parkingPosition, snapshot.parked != false else { return }
        if !loaded { await load() }
        var m = movements
        m.record(CarSighting(at: snapshot.carCapturedAt ?? snapshot.fetchedAt, position: position))
        guard m != movements else { return }
        movements = m
        await movementsStore.save(m)
        await rebuildCarStays()
    }

    /// Fetches the car's trips for the days that need it (today, and past days not yet complete),
    /// newest first, up to `maxDays` requests.
    public func refreshCarTrips(days back: Int = 7, maxRequests: Int = 3, kind: RequestKind = .manual, calendar: Calendar = .current) async {
        guard log.mode == .car, !log.trackedPlaceIds.isEmpty, let fetchTrips else { return }
        if !loaded { await load() }
        loadingTrips = true
        defer { loadingTrips = false }
        var used = 0
        for offset in 0..<back where used < maxRequests {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let day = CalendarDay(date: date, calendar: calendar)
            guard movements.needs(day, now: now, calendar: calendar) else { continue }
            used += 1
            switch await fetchTrips(day, kind) {
            case .success(let trips, _):
                movements.store(trips, for: day, fetchedAt: now, calendar: calendar)
                problem = nil
            case .failure(let error, _):
                problem = "Couldn't get the car's trips: \(error.message)"
                used = maxRequests
            }
        }
        await movementsStore.save(movements)
        await rebuildCarStays()
    }

    private func rebuildCarStays() async {
        let stays = movements.stays(places: places?() ?? [], tracked: log.trackedPlaceIds, now: now)
        await change { $0.replaceCarStays(stays) }
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
        await rebuildCarStays()
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
