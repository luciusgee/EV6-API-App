import Foundation
import PreconditionKit

/// Every timed run and lap session, kept on the phone.
@MainActor
@Observable
final class RunStore {
    static let shared = RunStore()

    private(set) var runs: [RunResult] = []
    private(set) var sessions: [LapSession] = []
    private let store: JSONFileStore<LossyArray<RunResult>>
    private let lapStore: JSONFileStore<LossyArray<LapSession>>

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // A file unreadable at launch (still protected) is merged with, not lost, once it reads.
        store = JSONFileStore(url: support.appendingPathComponent("EV6Precondition/runs.json"), default: LossyArray([]),
                              merge: { LossyArray.mergingByID(file: $0, mine: $1) })
        lapStore = JSONFileStore(url: support.appendingPathComponent("EV6Precondition/laps.json"), default: LossyArray([]),
                                 merge: { LossyArray.mergingByID(file: $0, mine: $1) })
    }

    func load() async {
        runs = await store.load().elements
        sessions = await lapStore.load().elements
    }

    func add(_ run: RunResult) {
        runs.append(run)
        saveRuns()
    }

    func delete(_ ids: Set<UUID>) {
        runs.removeAll { ids.contains($0.id) }
        saveRuns()
    }

    /// Saves, then picks up any runs a merge with a file that was unreadable at launch brought in.
    private func saveRuns() {
        let value = LossyArray(runs)
        Task {
            let saved = await store.save(value)
            runs = Self.adding(saved.elements, sent: value.elements, to: runs)
        }
    }

    private func saveSessions() {
        let value = LossyArray(sessions)
        Task {
            let saved = await lapStore.save(value)
            sessions = Self.adding(saved.elements, sent: value.elements, to: sessions)
        }
    }

    /// `current` plus what a merge added to the save: items of `saved` that weren't `sent`, and that
    /// `current` doesn't have by id. Usually there are none and `current` comes back as it is.
    static func adding<T: Identifiable>(_ saved: [T], sent: [T], to current: [T]) -> [T] {
        guard saved.count != sent.count else { return current }
        let known = Set(sent.map(\.id)).union(current.map(\.id))
        let extra = saved.filter { !known.contains($0.id) }
        return extra.isEmpty ? current : extra + current
    }

    func best(_ type: RunType) -> RunResult? {
        runs.filter { $0.type == type }.min { $0.seconds < $1.seconds }
    }

    /// Newest first.
    func runs(_ type: RunType?) -> [RunResult] {
        runs.filter { type == nil || $0.type == type }.sorted { $0.date > $1.date }
    }

    func add(_ session: LapSession) {
        guard !session.laps.isEmpty else { return }
        sessions.append(session)
        saveSessions()
    }

    /// Replaces the session with the same id, or adds it: a session saved lap by lap.
    func upsert(_ session: LapSession) {
        guard !session.laps.isEmpty else { return }
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.append(session)
        }
        saveSessions()
    }

    func deleteSessions(_ ids: Set<UUID>) {
        sessions.removeAll { ids.contains($0.id) }
        saveSessions()
    }
}

/// One go at a circuit: its laps, best first in the summary.
struct LapSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var name: String
    var line: FinishLine
    var laps: [Lap]

    var best: Lap? { laps.min { $0.seconds < $1.seconds } }
}

extension LapSession {
    /// Lenient, so a session saved by another build still loads; a bad lap is skipped, not fatal.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decode(Date.self, forKey: .date)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? date.formatted(date: .abbreviated, time: .shortened)
        line = try c.decode(FinishLine.self, forKey: .line)
        laps = (try? c.decodeIfPresent(LossyArray<Lap>.self, forKey: .laps))??.elements ?? []
    }
}

/// Every recorded charge, newest last.
@MainActor
@Observable
final class ChargeStore {
    static let shared = ChargeStore()

    private(set) var sessions: [ChargeSession] = []
    private let store: JSONFileStore<LossyArray<ChargeSession>>

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = JSONFileStore(url: support.appendingPathComponent("EV6Precondition/charges.json"), default: LossyArray([]),
                              merge: { LossyArray.mergingByID(file: $0, mine: $1) })
    }

    func load() async {
        sessions = await store.load().elements
    }

    func add(_ session: ChargeSession) {
        sessions.append(session)
        save()
    }

    func delete(_ ids: Set<UUID>) {
        sessions.removeAll { ids.contains($0.id) }
        save()
    }

    /// Saves, then picks up any charges a merge with a file that was unreadable at launch brought in.
    private func save() {
        let value = LossyArray(sessions)
        Task {
            let saved = await store.save(value)
            sessions = RunStore.adding(saved.elements, sent: value.elements, to: sessions)
        }
    }
}
