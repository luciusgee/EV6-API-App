import Foundation
import PreconditionKit

/// Every timed run and lap session, kept on the phone.
@MainActor
@Observable
final class RunStore {
    static let shared = RunStore()

    private(set) var runs: [RunResult] = []
    private(set) var sessions: [LapSession] = []
    private let store: JSONFileStore<[RunResult]>
    private let lapStore: JSONFileStore<[LapSession]>

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = JSONFileStore(url: support.appendingPathComponent("EV6Precondition/runs.json"), default: [])
        lapStore = JSONFileStore(url: support.appendingPathComponent("EV6Precondition/laps.json"), default: [])
    }

    func load() async {
        runs = await store.load()
        sessions = await lapStore.load()
    }

    func add(_ run: RunResult) {
        runs.append(run)
        Task { await store.save(runs) }
    }

    func delete(_ ids: Set<UUID>) {
        runs.removeAll { ids.contains($0.id) }
        Task { await store.save(runs) }
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
        Task { await lapStore.save(sessions) }
    }

    func deleteSessions(_ ids: Set<UUID>) {
        sessions.removeAll { ids.contains($0.id) }
        Task { await lapStore.save(sessions) }
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
