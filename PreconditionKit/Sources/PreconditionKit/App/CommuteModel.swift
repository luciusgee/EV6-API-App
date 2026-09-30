import Foundation
import Observation

/// Commutes, their routes and the last traffic check of each.
@MainActor
@Observable
public final class CommuteModel {
    public private(set) var commutes: [Commute] = []
    public private(set) var advice: [UUID: CommuteAdvice] = [:]
    public private(set) var checking: Set<UUID> = []

    /// Runs after the commutes change, so the app can watch their starts and book reminders.
    @ObservationIgnored public var onChange: (@MainActor ([Commute]) -> Void)?

    /// Google when there's a key, Apple Maps otherwise. Set by the app.
    @ObservationIgnored public var timer: () -> DriveTimer = { NoDriveTimer() }

    private let store: JSONFileStore<[Commute]>
    private let time: TimeSource

    public nonisolated init(directory: URL, time: TimeSource = SystemTime()) {
        store = JSONFileStore(url: directory.appendingPathComponent("commutes.json"), default: [])
        self.time = time
    }

    public func load() async {
        commutes = await store.load()
        onChange?(commutes)
    }

    public func save(_ commute: Commute) async {
        if let i = commutes.firstIndex(where: { $0.id == commute.id }) {
            commutes[i] = commute
        } else {
            commutes.append(commute)
        }
        advice[commute.id] = nil
        await store.save(commutes)
        onChange?(commutes)
    }

    public func delete(_ id: UUID) async {
        commutes.removeAll { $0.id == id }
        advice[id] = nil
        await store.save(commutes)
        onChange?(commutes)
    }

    /// The commute called `name` (any case), else the first.
    public func commute(named name: String?) -> Commute? {
        guard let name, !name.isEmpty else { return commutes.first }
        return commutes.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } ?? commutes.first
    }

    @discardableResult
    public func check(_ id: UUID) async -> CommuteAdvice? {
        guard let commute = commutes.first(where: { $0.id == id }), !checking.contains(id) else { return advice[id] }
        checking.insert(id)
        defer { checking.remove(id) }
        let result = await CommuteAdvisor.check(commute, with: timer(), now: time.now())
        advice[id] = result
        return result
    }

    /// The ETA message for the last check, with the arrival formatted by `format`.
    public func message(for id: UUID, format: (Date) -> String) -> String? {
        guard let commute = commutes.first(where: { $0.id == id }),
              let a = advice[id], let pick = a.pick, let arrival = a.arrival, let t = pick.time else { return nil }
        return commute.messageText(eta: format(arrival), minutes: t.minutes, route: pick.route.name)
    }
}

struct NoDriveTimer: DriveTimer {
    func time(_ points: [LatLon]) async throws -> DriveTime {
        throw GoogleRoutesClient.Failure.noRoute
    }
}
