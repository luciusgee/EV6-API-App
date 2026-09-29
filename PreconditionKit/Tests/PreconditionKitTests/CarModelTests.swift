import Foundation
import XCTest
@testable import PreconditionKit

@MainActor
final class CarModelTests: XCTestCase {
    let time = MutableTime()
    let live = ScriptedTransport()
    let credentials = InMemoryCredentialsStore()
    lazy var container = AppContainer(
        directory: temporaryDirectory(),
        credentials: credentials,
        sessions: InMemoryKiaSessionStore(),
        fakeSessions: InMemoryKiaSessionStore(),
        notifier: NoopNotifier(),
        live: live,
        time: time,
        config: KiaConfig(apiBase: "https://api.test:8080", idpBase: "https://idp.test"),
        commandGap: 0
    )
    lazy var model = CarModel(container: container)

    override func setUp() async throws {
        try await super.setUp()
        live.setDefault("/oauth2/token", jsonResponse(KiaClientTests.tokenOK))
        live.setDefault("/notifications/register", okResponse(#"{"deviceId":"dev-1"}"#))
        live.setDefault("/spa/vehicles", okResponse(KiaClientTests.vehiclesLegacy))
        live.setDefault("/status/latest", okResponse(KiaClientTests.legacyStatus))
        live.setDefault("/location/park", okResponse(KiaClientTests.park))
        live.setDefault("/control/temperature", jsonResponse(#"{"retCode":"S","resCode":"0000","resMsg":{},"msgId":"m1"}"#))
    }

    func testFirstLaunchAsksForSetupAndMakesNoRequest() async {
        await model.load()
        XCTAssertEqual(model.banners, [.setupNeeded])
        XCTAssertFalse(model.hasToken)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.budget?.automationAvailable, 72)
        XCTAssertTrue(live.seen.isEmpty)
    }

    func testRefreshWithoutATokenSaysWhy() async {
        await model.load()
        await model.refresh()
        XCTAssertEqual(model.message, "Refresh failed: Kia Connect refresh token not set")
        XCTAssertNil(model.busy)
    }

    func testSavingATokenThenRefreshingShowsTheCar() async throws {
        await model.load()
        await model.saveCredentials(token: " \(KiaClientTests.refresh)\n", pin: "", vin: "")
        XCTAssertTrue(model.hasToken)
        XCTAssertFalse(model.hasPin)
        XCTAssertEqual(model.banners, [])
        let stored = await credentials.value
        XCTAssertEqual(stored?.refreshToken, KiaClientTests.refresh)

        await model.refresh()
        XCTAssertNil(model.message)
        XCTAssertEqual(model.snapshot?.socPercent, 74)
        XCTAssertEqual(model.budget?.remaining, 79)
        XCTAssertEqual(model.log.first?.decision, "first vehicle response")
    }

    func testStartAndStopReportTheOutcome() async {
        await model.load()
        await model.saveCredentials(token: KiaClientTests.refresh)
        await model.start(targetC: 20)
        XCTAssertEqual(model.message, "Sent: climatise to 20.0 °C. Waiting for the car to confirm…")
        XCTAssertEqual(model.automation.lastCommand?.description, "climatise to 20.0 °C")
        XCTAssertEqual(body(live.last("/control/temperature"))?["tempCode"], "0CH")

        live.respond("/control/temperature", jsonResponse(#"{"retCode":"F","resCode":"5031","resMsg":"busy"}"#, status: 400))
        await model.stop()
        XCTAssertEqual(model.message, "Failed: vehicle not accepting requests")
    }

    func testARejectedTokenShowsTheFixAndANewTokenClearsIt() async {
        live.respond("/oauth2/token", jsonResponse(#"{"error":"invalid_grant"}"#, status: 400))
        await model.load()
        await model.saveCredentials(token: KiaClientTests.refresh)
        await model.refresh()
        XCTAssertEqual(model.banners, [.authStopped("Kia rejected the refresh token. \(ApiMonitor.authHelp)")])

        await model.saveCredentials(token: String(repeating: "C", count: 48))
        XCTAssertEqual(model.banners, [])
        XCTAssertEqual(model.log.first?.reason, "Kia Connect refresh token replaced")
    }

    func testCredentialsKeepWhatIsNotChangedAndCanBeRemoved() async {
        await model.load()
        await model.saveCredentials(token: KiaClientTests.refresh, pin: "1234", vin: "knac381abn5000001")
        XCTAssertEqual(model.vin, "KNAC381ABN5000001")
        await model.saveCredentials(pin: "")
        var stored = await credentials.value
        XCTAssertEqual(stored, Credentials(refreshToken: KiaClientTests.refresh, vin: "KNAC381ABN5000001", pin: nil))
        await model.saveCredentials(token: "")
        stored = await credentials.value
        XCTAssertNil(stored)
        XCTAssertFalse(model.hasToken)
        XCTAssertEqual(model.vin, "")
    }

    func testFakeModeUsesTheFakeCarAndNeverTheNetwork() async {
        await model.load()
        await model.updateSettings { $0.fakeMode = true }
        XCTAssertEqual(model.banners, [.fakeMode])
        model.updateFakeCar { $0.socPercent = 33 }
        await model.refresh()
        XCTAssertEqual(model.snapshot?.socPercent, 33)
        XCTAssertTrue(live.seen.isEmpty)

        // Switching back never shows the fake car as the real one.
        await model.updateSettings { $0.fakeMode = false }
        XCTAssertNil(model.snapshot)
    }

    func testFakeModeSurvivesARestart() async {
        await model.load()
        await model.updateSettings { $0.fakeMode = true }
        let again = CarModel(container: container)
        container.transport.fakeMode = false
        await again.load()
        XCTAssertTrue(again.settings.fakeMode)
        XCTAssertTrue(container.transport.fakeMode)
    }

    func testSettingsChangesAreClampedAndApplyToTheBudget() async {
        await model.load()
        await model.updateSettings {
            $0.budgetLimit = 40
            $0.budgetReserve = 5
            $0.minSocPercent = -3
        }
        XCTAssertEqual(model.settings.minSocPercent, 0)
        XCTAssertEqual(model.budget?.limit, 40)
        XCTAssertEqual(model.budget?.automationAvailable, 35)
    }

    func testTokenShapeCheck() {
        XCTAssertTrue(CarModel.tokenLooksValid(KiaClientTests.refresh))
        XCTAssertFalse(CarModel.tokenLooksValid("abc"))
        XCTAssertFalse(CarModel.tokenLooksValid(KiaClientTests.refresh.lowercased()))
    }

    func testPausedAutomationOffersResume() async {
        await container.stores.automationState.update {
            $0.pausedAfterFailures = true
            $0.consecutiveFailures = 3
        }
        await model.load()
        XCTAssertTrue(model.banners.contains(.paused("automation paused after 3 consecutive failures")))
        await model.resumeAutomation()
        XCTAssertFalse(model.banners.contains { if case .paused = $0 { return true } else { return false } })
    }
}
