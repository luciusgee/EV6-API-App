import Foundation
import XCTest
@testable import PreconditionKit

/// The Rules screens' model and the Shortcuts schedule check, against the fake car.
@MainActor
final class RulesModelTests: XCTestCase {
    let time = MutableTime(wednesdayAt(7, 20))
    let live = ScriptedTransport()
    lazy var container = AppContainer(
        directory: temporaryDirectory(),
        credentials: InMemoryCredentialsStore(),
        sessions: InMemoryKiaSessionStore(),
        fakeSessions: InMemoryKiaSessionStore(),
        notifier: NoopNotifier(),
        phone: MutablePhone(home.centre),
        live: live,
        time: time,
        timeZone: { prague }
    )
    lazy var model = RulesModel(container: container)

    override func setUp() async throws {
        try await super.setUp()
        await container.stores.settings.save(AppSettings(fakeMode: true, fakeWeatherC: -2))
        await container.start()
        container.fakeCar.state.latitude = home.centre.lat
        container.fakeCar.state.longitude = home.centre.lon
        await container.rules.save(office)
        await container.rules.save(home)
        await model.load()
    }

    override func tearDown() {
        XCTAssertTrue(live.seen.isEmpty, "fake-car mode must never reach the network")
        super.tearDown()
    }

    func testTemplatesPickTheMatchingPlaceAndSaveValidRulesOnly() async {
        let morning = model.newRule(from: Templates.all[1])
        XCTAssertEqual(morning.conditions.first, .carAtPlace(placeId: "home"))
        let leaving = model.newRule(from: Templates.all[0])
        XCTAssertEqual(leaving.trigger, .geofenceExit(placeId: "office"))

        var bad = model.blankRule()
        XCTAssertEqual(bad.trigger, .geofenceExit(placeId: "home")) // first place by name
        let problems = await model.save(bad)
        XCTAssertTrue(problems.contains("name is empty"))
        XCTAssertTrue(model.rules.isEmpty)

        bad.name = "  Warm up "
        let none = await model.save(bad)
        XCTAssertEqual(none, [])
        XCTAssertEqual(model.rules.map(\.name), ["Warm up"])
        XCTAssertEqual(model.describe(model.rules[0]), "leave Home · climatise to 21.0 °C")

        await model.setEnabled(bad.id, false)
        XCTAssertFalse(model.rules[0].enabled)
        await model.delete(id: bad.id)
        XCTAssertTrue(model.rules.isEmpty)
    }

    func testTestNowShowsTheChecksAndTheLastResult() async {
        let morning = model.newRule(from: Templates.all[1])
        await model.save(morning)
        let evaluation = await model.testNow(morning)
        XCTAssertEqual(evaluation.winner?.id, morning.id, evaluation.verdicts.first?.reason ?? "")
        XCTAssertFalse(container.fakeCar.state.climateOn)
        XCTAssertEqual(model.lastResults[morning.id]?.decision, "would fire")
        XCTAssertFalse(model.testing)
    }

    func testTheScheduleCheckRunsDueRulesOncePerDay() async {
        let morning = model.newRule(from: Templates.all[1]) // Mon–Fri 07:20
        await model.save(morning)
        XCTAssertEqual(model.nextCheck?.time, TimeOfDay(7, 20))

        // The Shortcut ran three minutes late.
        time.advance(3 * 60)
        let outcomes = await model.runDueSchedules()
        XCTAssertEqual(outcomes.count, 1)
        guard case .fired(let r, _) = outcomes.first else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(r.id, morning.id)
        XCTAssertTrue(container.fakeCar.state.climateOn)
        XCTAssertEqual(model.lastResults[morning.id]?.decision, "sent")

        // A second run the same morning does nothing.
        time.advance(60)
        let again = await model.runDueSchedules()
        XCTAssertEqual(again, [])
        let log = await container.stores.log.entries()
        XCTAssertEqual(log.last?.reason, "no schedule rules due at 07:24")
    }

    func testTheScheduleCheckIgnoresRulesOutsideTheWindowOrDay() async {
        await model.save(rule("later", trigger: .schedule(days: Weekday.weekdays, time: TimeOfDay(7, 40))))
        await model.save(rule("weekend", trigger: .schedule(days: Weekday.weekend, time: TimeOfDay(7, 20))))
        await model.save(rule("long-ago", trigger: .schedule(days: Weekday.weekdays, time: TimeOfDay(7, 0))))
        let outcomes = await model.runDueSchedules()
        XCTAssertEqual(outcomes, [])
        // 2 minutes early still counts.
        time.advance(18 * 60)
        let early = await model.runDueSchedules()
        XCTAssertEqual(early.count, 1)
    }

    func testImportMergesAndReportsProblems() async {
        let text = RuleJSON.export(places: [], rules: [Templates.hotDay(officeId: "office", id: "hot"), Templates.hotDay(officeId: "gym", id: "gym")])
        let result = await model.importText(text)
        XCTAssertEqual(result.rules.map(\.id), ["hot"])
        XCTAssertEqual(model.rules.map(\.id), ["hot"])
        XCTAssertTrue(model.message!.hasPrefix("Imported 1 rule and 0 places. Skipped 1: rule #2"), model.message!)
        XCTAssertTrue(RuleJSON.import(model.exportText()).ok)
    }
}
