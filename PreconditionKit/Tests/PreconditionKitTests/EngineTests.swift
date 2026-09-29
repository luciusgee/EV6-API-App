import Foundation
import XCTest
@testable import PreconditionKit

actor RecordingNotifier: Notifier {
    private(set) var sent: [String] = []
    private(set) var problems: [String] = []
    func commandSent(title: String, text: String, canStop: Bool) { sent.append(title) }
    func problem(title: String, text: String, openSettings: Bool) { problems.append("\(title): \(text)") }
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("PreconditionKitTests-\(UUID().uuidString)")
}

/// The manual path of the Android `PreconditionEngineTest` and `KiaEngineTest`, against the fake car.
final class EngineTests: XCTestCase {
    let time = MutableTime()
    let live = ScriptedTransport()
    let notifier = RecordingNotifier()
    let credentials = InMemoryCredentialsStore(Credentials(refreshToken: KiaClientTests.refresh))
    lazy var container = AppContainer(
        directory: temporaryDirectory(),
        credentials: credentials,
        sessions: InMemoryKiaSessionStore(),
        fakeSessions: InMemoryKiaSessionStore(),
        notifier: notifier,
        live: live,
        time: time,
        commandGap: 0
    )
    var engine: PreconditionEngine { container.engine }
    var fake: FakeKia { container.fakeCar }

    override func setUp() async throws {
        try await super.setUp()
        await container.stores.settings.save(AppSettings(fakeMode: true))
        await container.start()
    }

    override func tearDown() {
        XCTAssertTrue(live.seen.isEmpty, "fake-car mode must never reach Kia")
        super.tearDown()
    }

    func entries() async -> [LogEntry] { await container.stores.log.entries() }

    func testManualStartReadsTheCarChecksSocAndSends() async {
        let outcome = await engine.manualStart(targetC: 22)
        XCTAssertEqual(outcome, .sent("climatise to 22.0 °C"))
        XCTAssertTrue(fake.state.climateOn)
        XCTAssertEqual(fake.state.targetTempC, 22)
        let state = await container.stores.automationState.load()
        XCTAssertEqual(state.lastCommand?.at, t0)
        XCTAssertEqual(state.lastCommand?.description, "climatise to 22.0 °C")
        XCTAssertNotNil(state.lastCommand?.messageId, "kept to confirm with the car")
        XCTAssertEqual(state.lastCommand?.automated, false)
        let sent = await notifier.sent
        XCTAssertEqual(sent, ["Preconditioning to 22.0 °C"])
        let manual = await entries().filter { $0.kind == .manual }
        XCTAssertEqual(manual.map(\.decision), ["sent"])
        XCTAssertEqual(manual.first?.requestsUsed, 2) // a read, then the command
    }

    func testManualStartUsesTheDefaultTarget() async {
        await container.stores.settings.save(AppSettings(defaultTargetC: 19.5, fakeMode: true))
        let outcome = await engine.manualStart()
        XCTAssertEqual(outcome, .sent("climatise to 19.5 °C"))
    }

    func testManualStartIgnoresCooldownsButNotTheSocGuard() async {
        await container.stores.automationState.update { $0.lastAutomatedCommandAt = t0 }
        do { let got = await engine.manualStart(targetC: 22); XCTAssertEqual(got, .sent("climatise to 22.0 °C")) }

        fake.state.socPercent = 10
        await container.vehicles.clear()
        let refusal = await engine.manualStart()
        guard case .refused(let reason) = refusal else { return XCTFail("expected a refusal") }
        XCTAssertEqual(reason, "SoC 10% below minimum 25%")
        let last = await entries().last
        XCTAssertEqual(last?.decision, "refused")
        XCTAssertEqual(last?.reason, "climatise to 21.0 °C: SoC 10% below minimum 25%")
    }

    func testPluggedInPassesTheSocGuard() async {
        fake.state.socPercent = 10
        fake.state.pluggedIn = true
        do { let got = await engine.manualStart(); XCTAssertEqual(got, .sent("climatise to 21.0 °C")) }
    }

    func testAFreshCachedStateSavesARead() async {
        _ = await engine.refreshVehicle()
        time.advance(5 * 60)
        _ = await engine.manualStart()
        let last = await entries().last
        XCTAssertEqual(last?.requestsUsed, 1)
    }

    func testManualCommandsRespectTheRateBudget() async {
        await container.stores.settings.save(AppSettings(budgetLimit: 10, budgetReserve: 0, fakeMode: true))
        // Use nine of the ten slots: a start then needs two (read + command), a stop only one.
        for _ in 0..<9 { _ = await container.budget.tryAcquire(.manual) }
        do { let got = await engine.manualStart(); XCTAssertEqual(got, .refused("rate budget exhausted")) }
        do { let got = await engine.manualStop(); XCTAssertEqual(got, .sent("stop climatisation")) }
        do { let got = await engine.manualStop(); XCTAssertEqual(got, .refused("rate budget exhausted")) }
    }

    func testManualStopReachesTheCar() async {
        fake.state.climateOn = true
        do { let got = await engine.manualStop(); XCTAssertEqual(got, .sent("stop climatisation")) }
        XCTAssertFalse(fake.state.climateOn)
        let sent = await notifier.sent
        XCTAssertTrue(sent.isEmpty) // only starts notify
    }

    func testManualFailuresAreReported() async {
        fake.state.scenario = .vehicleBusy
        do { let got = await engine.manualStop(); XCTAssertEqual(got, .failed(.vehicleNotAcceptingRequests(retryAfter: 120))) }
        let refusal = await engine.manualStart()
        guard case .refused(let reason) = refusal else { return XCTFail("expected a refusal") }
        XCTAssertTrue(reason.hasPrefix("vehicle state unavailable"))
    }

    func testTheFirstVehicleResponseIsLoggedOnce() async {
        _ = await engine.refreshVehicle()
        time.advance(3600)
        _ = await engine.refreshVehicle()
        let dumps = await entries().filter { $0.decision == "first vehicle response" }
        XCTAssertEqual(dumps.count, 1)
        XCTAssertFalse(dumps[0].details!.contains(FakeKia.vin))
        // Kia's status carries no VIN; redactVin (VinTests) masks one if a future response does.
        XCTAssertTrue(dumps[0].details!.contains("vehicleStatusInfo"))
    }

    func testARefreshFailureIsLogged() async {
        fake.state.scenario = .serverError
        do { let got = await engine.refreshVehicle(); XCTAssertNotNil(got.error) }
        let last = await entries().last
        XCTAssertEqual(last?.decision, "refresh failed")
        XCTAssertEqual(last?.httpCode, 503)
    }

    func testARejectedLoginStopsAutomationOnceAndTheNextSuccessResumesIt() async {
        fake.state.scenario = .refreshTokenRejected
        _ = await engine.refreshVehicle()
        _ = await engine.refreshVehicle()
        var state = await container.stores.automationState.load()
        XCTAssertEqual(state.authFailure, "Kia rejected the refresh token")
        XCTAssertEqual(state.automationBlockedReason, "automation stopped: Kia rejected the refresh token")
        let problems = await notifier.problems
        XCTAssertEqual(problems, ["Automation stopped: Kia rejected the refresh token. \(ApiMonitor.authHelp)"])
        let stops = await entries().filter { $0.decision == "stopped" }
        XCTAssertEqual(stops.count, 1)

        fake.state.scenario = .none
        do { let got = await engine.refreshVehicle(); XCTAssertNotNil(got.value) }
        state = await container.stores.automationState.load()
        XCTAssertNil(state.authFailure)
        let last = await entries().last { $0.decision == "resumed" }
        XCTAssertNotNil(last)
    }

    func testResumeClearsAPause() async {
        await container.stores.automationState.update {
            $0.pausedAfterFailures = true
            $0.consecutiveFailures = 3
        }
        await engine.resumeAutomation()
        let state = await container.stores.automationState.load()
        XCTAssertFalse(state.pausedAfterFailures)
        XCTAssertEqual(state.consecutiveFailures, 0)
    }
}

final class StoreTests: XCTestCase {
    func testFileStoresSurviveARestart() async throws {
        let dir = temporaryDirectory()
        let time = MutableTime()
        let first = FileStores(directory: dir, time: time)
        await first.settings.save(AppSettings(minSocPercent: 30, fakeMode: true))
        await first.automationState.update { $0.lastCommand = LastCommand(at: t0, description: "x", automated: false) }
        await first.vehicleCache.save(VehicleSnapshot(socPercent: 55, fetchedAt: t0))
        await first.log.append(LogEntry(at: t0, kind: .info, decision: "d", reason: "r"))
        _ = await first.budget.load()
        await first.budget.save(RateBudgetState(sent: [SentRequest(id: 1, at: t0, kind: .manual)], nextId: 2))

        let second = FileStores(directory: dir, time: time)
        let settings = await second.settings.load()
        XCTAssertEqual(settings.minSocPercent, 30)
        XCTAssertTrue(settings.fakeMode)
        let state = await second.automationState.load()
        XCTAssertEqual(state.lastCommand?.description, "x")
        let cached = await second.vehicleCache.load()
        XCTAssertEqual(cached?.socPercent, 55)
        XCTAssertEqual(cached?.fetchedAt, t0)
        let log = await second.log.entries()
        XCTAssertEqual(log.map(\.decision), ["d"])
        let budget = await second.budget.load()
        XCTAssertEqual(budget.nextId, 2)
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingOrOldFilesFallBackToDefaults() async throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"minSocPercent":40}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("automation.json"))
        let stores = FileStores(directory: dir)
        let settings = await stores.settings.load()
        XCTAssertEqual(settings, AppSettings(minSocPercent: 40))
        let state = await stores.automationState.load()
        XCTAssertEqual(state, AutomationState())
        let cached = await stores.vehicleCache.load()
        XCTAssertNil(cached)
        try? FileManager.default.removeItem(at: dir)
    }

    func testLogRetentionKeeps30DaysOr2000Entries() {
        let old = LogEntry(at: t0.addingTimeInterval(-31 * 24 * 3600), kind: .info, decision: "old", reason: "")
        let recent = (0..<2100).map { LogEntry(at: t0.addingTimeInterval(Double($0)), kind: .info, decision: "\($0)", reason: "") }
        let kept = LogRetention.trim([old] + recent, now: t0.addingTimeInterval(3000))
        XCTAssertEqual(kept.count, 2000)
        XCTAssertEqual(kept.first?.decision, "100")
        XCTAssertEqual(kept.last?.decision, "2099")
    }

    func testLogCSVEscapes() {
        let entry = LogEntry(at: t0, kind: .manual, decision: "sent", reason: "climatise, now", httpCode: 200, requestsUsed: 2, details: "a \"b\"\nc")
        XCTAssertEqual(
            LogRetention.csv([entry]),
            "time,kind,decision,reason,trigger,rule,http,requests,details\n2026-09-23T15:00:00Z,MANUAL,sent,\"climatise, now\",,,200,2,\"a \"\"b\"\"\nc\"\n"
        )
    }

    func testSettingsAreClamped() {
        let s = AppSettings(minSocPercent: 150, defaultTargetC: 40.3, budgetLimit: 1000, budgetReserve: 900).clamped
        XCTAssertEqual(s.minSocPercent, 100)
        XCTAssertEqual(s.defaultTargetC, 30)
        XCTAssertEqual(s.budgetLimit, 200)
        XCTAssertEqual(s.budgetReserve, 100)
        XCTAssertEqual(AppSettings(defaultTargetC: 21.3).clamped.defaultTargetC, 21.5)
    }

    func testRuleActionJSONMatchesTheAndroidBackup() throws {
        let backup = try Fixtures.json("rules-backup.json")
        for rule in backup["rules"]?.array ?? [] {
            let json = try XCTUnwrap(rule["action"])
            let action = try JSONDecoder().decode(RuleAction.self, from: json.data)
            XCTAssertEqual(JSONValue.parse(try JSONEncoder().encode(action)), json)
        }
        XCTAssertEqual(Describe.action(.startClimate(targetC: 21)), "climatise to 21.0 °C")
        XCTAssertEqual(Describe.action(.stopClimate), "stop climatisation")
    }

    func testUntouchedOldBudgetMovesToTheNewDefault() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"budgetLimit":80,"budgetReserve":8}"#.utf8))
        XCTAssertEqual(old.budgetLimit, 150)
        XCTAssertEqual(old.budgetReserve, 15)
        let chosen = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"budgetLimit":100,"budgetReserve":8}"#.utf8))
        XCTAssertEqual(chosen.budgetLimit, 100, "a limit the user picked stays")
    }
}
