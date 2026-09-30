import Foundation
import XCTest
@testable import PreconditionKit

final class ChargingTests: XCTestCase {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func snap(_ at: String, soc: Int, plugged: Bool = false, charging: Bool = false, kw: Double? = nil,
              odo: Double? = nil, locked: Bool? = true, limit: Int? = 80, parked: Bool? = true, aux: Int? = 90,
              windows: [String] = [], position: LatLon? = nil) -> VehicleSnapshot {
        VehicleSnapshot(
            socPercent: soc, rangeKm: soc * 4, pluggedIn: plugged, chargePowerKw: kw,
            chargingState: charging ? .charging : (plugged ? .pluggedIn : .unplugged),
            parkingPosition: position, parked: parked, carCapturedAt: date(at), fetchedAt: date(at),
            details: VehicleDetails(odometerKm: odo, locked: locked, auxBatteryPercent: aux, openWindows: windows, chargeLimitAC: limit)
        )
    }

    // MARK: Tariffs

    func testOffPeakWindowWrapsMidnight() {
        let tariff = Tariff.offPeak(peakPence: 28, offPeakPence: 7, from: ClockTime(hour: 23, minute: 30), to: ClockTime(hour: 5, minute: 30))
        let slots = tariff.slots(from: date("2026-09-29T22:10:00Z"), to: date("2026-09-30T06:00:00Z"), calendar: utc)
        XCTAssertEqual(slots.first?.start, date("2026-09-29T22:00:00Z"))
        XCTAssertEqual(slots.count, 16)
        XCTAssertEqual(slots.map(\.pencePerKWh), [28, 28, 28, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 28])
        XCTAssertEqual(tariff.averagePence(from: date("2026-09-30T00:00:00Z"), to: date("2026-09-30T02:00:00Z"), calendar: utc), 7)
    }

    func testAnOvernightChargeIsCostedInTheCheapHours() throws {
        // Seen charging at 23:00, next seen finished at 07:15: the peak hour after 06:00 shouldn't count.
        let tariff = Tariff.offPeak(peakPence: 32.875, offPeakPence: 6.66, from: ClockTime(hour: 23), to: ClockTime(hour: 6))
        let cost = tariff.chargeCost(kWh: 40, powerKW: 7, from: date("2026-09-29T23:00:00Z"), to: date("2026-09-30T07:15:00Z"), calendar: utc)
        XCTAssertEqual(cost, 40 * 6.66, accuracy: 0.001)
        // More than the window can hold: the rest at the peak price.
        let over = tariff.chargeCost(kWh: 52, powerKW: 7, from: date("2026-09-29T23:00:00Z"), to: date("2026-09-30T07:15:00Z"), calendar: utc)
        XCTAssertEqual(over, 49 * 6.66 + 3 * 32.875, accuracy: 0.001)

        // Old charges are costed again this way, once.
        var settings = ChargingSettings(tariff: tariff)
        settings.smart.chargerKW = 7
        var data = try JSONDecoder().decode(ChargingData.self, from: Data(#"{"sessions":[]}"#.utf8))
        data.sessions = [ChargeSession(id: "a", start: date("2026-09-29T23:00:00Z"), end: date("2026-09-30T07:15:00Z"), startPercent: 35, endPercent: 90,
                                       batteryKWh: 36, paidKWh: 40, costPence: 493, atHome: true)]
        ChargeLedger.recostOldHomeCharges(&data, settings: settings, agileSlots: [], calendar: utc)
        XCTAssertEqual(data.sessions[0].costPence, (40 * 6.66).rounded())
        data.sessions[0].costPence = 1
        ChargeLedger.recostOldHomeCharges(&data, settings: settings, agileSlots: [], calendar: utc)
        XCTAssertEqual(data.sessions[0].costPence, 1)
    }

    func testAgileUsesPublishedSlotsAndFallsBack() {
        let slots = [PriceSlot(start: date("2026-09-29T23:00:00Z"), end: date("2026-09-29T23:30:00Z"), pencePerKWh: 4.2)]
        let tariff = Tariff.agile(region: "C", fallbackPence: 25)
        let out = tariff.slots(from: date("2026-09-29T23:00:00Z"), to: date("2026-09-30T00:00:00Z"), agileSlots: slots, calendar: utc)
        XCTAssertEqual(out.map(\.pencePerKWh), [4.2, 25])
    }

    // MARK: Smart charging

    func testPicksTheCheapestUnbrokenWindowBeforeReadyBy() throws {
        // 40% → 80% of 74 kWh with 10% losses = 32.56 kWh; 7 kW → 10 half-hours (the last part-used).
        let now = date("2026-09-29T20:00:00Z")
        let readyBy = date("2026-09-30T07:00:00Z")
        let prices: [Double] = [30, 30, 28, 25, 20, 18, 15, 12, 9, 6, 5, 4, 4, 5, 8, 12, 15, 18, 20, 22, 25, 28]
        let slots = prices.enumerated().map { i, p in
            PriceSlot(start: now.addingTimeInterval(Double(i) * 1800), end: now.addingTimeInterval(Double(i + 1) * 1800), pencePerKWh: p)
        }
        let settings = SmartChargeSettings(enabled: true, targetPercent: 80, readyBy: ClockTime(hour: 7), chargerKW: 7)
        let plan = try XCTUnwrap(SmartCharging.plan(slots: slots, now: now, readyBy: readyBy, socPercent: 40, settings: settings, usableKWh: 74, lossFactor: 1.1))
        XCTAssertEqual(plan.kWh, 32.56, accuracy: 0.01)
        // Slots 7…16: 12, 9, 6, 5, 4, 4, 5, 8, 12 and part of 15p.
        XCTAssertEqual(plan.start, now.addingTimeInterval(7 * 1800))
        XCTAssertEqual(plan.end, now.addingTimeInterval(17 * 1800))
        XCTAssertEqual(plan.averagePence, 7.48, accuracy: 0.01)
        XCTAssertEqual(plan.savingPence, 417.46, accuracy: 0.01)

        XCTAssertNil(SmartCharging.plan(slots: slots, now: now, readyBy: readyBy, socPercent: 85, settings: settings, usableKWh: 74, lossFactor: 1.1))
    }

    func testDecisionHoldsBeforeTheWindowAndStartsInIt() {
        let plan = SmartChargePlan(start: date("2026-09-30T01:00:00Z"), end: date("2026-09-30T03:30:00Z"), targetPercent: 80,
                                   kWh: 30, averagePence: 5, costPence: 150, nowCostPence: 800)
        let early = snap("2026-09-29T22:00:00Z", soc: 40, plugged: true, charging: true)
        XCTAssertEqual(SmartCharging.decide(plan: plan, now: date("2026-09-29T22:00:00Z"), snapshot: early), .stopCharging)
        let waiting = snap("2026-09-30T01:05:00Z", soc: 40, plugged: true)
        XCTAssertEqual(SmartCharging.decide(plan: plan, now: date("2026-09-30T01:05:00Z"), snapshot: waiting), .startCharging)
        let unplugged = snap("2026-09-30T01:05:00Z", soc: 40)
        XCTAssertEqual(SmartCharging.decide(plan: plan, now: date("2026-09-30T01:05:00Z"), snapshot: unplugged), .nothing)
        XCTAssertEqual(SmartCharging.nextReadyBy(ClockTime(hour: 7, minute: 30), after: date("2026-09-29T08:00:00Z"), calendar: utc),
                       date("2026-09-30T07:30:00Z"))
    }

    // MARK: Ledger

    func testAChargeSeenRunningIsCostedAtHome() throws {
        var data = ChargingData()
        let settings = ChargingSettings(tariff: .flat(pencePerKWh: 25))
        let home = LatLon(lat: 51.5, lon: -0.1)
        XCTAssertNil(ChargeLedger.ingest(&data, snapshot: snap("2026-09-29T18:00:00Z", soc: 30, plugged: true, odo: 96_000, position: home), settings: settings, home: home))
        XCTAssertNil(ChargeLedger.ingest(&data, snapshot: snap("2026-09-29T19:00:00Z", soc: 35, plugged: true, charging: true, kw: 7, position: home), settings: settings, home: home))
        XCTAssertEqual(data.open?.soc, 30, "started at the earlier plugged-in reading")
        let done = try XCTUnwrap(ChargeLedger.ingest(&data, snapshot: snap("2026-09-30T02:00:00Z", soc: 80, plugged: true, odo: 96_000, position: home), settings: settings, home: home))
        XCTAssertEqual(done.addedPercent, 50)
        XCTAssertEqual(done.batteryKWh, 37, accuracy: 0.01)
        XCTAssertEqual(done.paidKWh, 40.7, accuracy: 0.01)
        XCTAssertEqual(done.costPence, 1018)
        XCTAssertTrue(done.atHome)
        // The same report again changes nothing.
        XCTAssertNil(ChargeLedger.ingest(&data, snapshot: snap("2026-09-30T02:00:00Z", soc: 80, plugged: true), settings: settings, home: home))
        XCTAssertEqual(data.sessions.count, 1)
    }

    func testAChargeMissedInBetweenIsStillCountedAndAwayUsesThePublicPrice() throws {
        var data = ChargingData()
        let settings = ChargingSettings(publicPencePerKWh: 79)
        let home = LatLon(lat: 51.5, lon: -0.1)
        let services = LatLon(lat: 52.2, lon: -1.2)
        ChargeLedger.ingest(&data, snapshot: snap("2026-09-29T10:00:00Z", soc: 20, odo: 96_000, position: home), settings: settings, home: home)
        let s = try XCTUnwrap(ChargeLedger.ingest(&data, snapshot: snap("2026-09-29T11:00:00Z", soc: 70, odo: 96_100, position: services), settings: settings, home: home))
        XCTAssertFalse(s.atHome)
        XCTAssertEqual(s.paidKWh, 37, accuracy: 0.01)
        XCTAssertEqual(s.costPence, 2923)
        // Driving down doesn't count.
        XCTAssertNil(ChargeLedger.ingest(&data, snapshot: snap("2026-09-29T12:00:00Z", soc: 60, odo: 96_140), settings: settings, home: home))
        let perMile = try XCTUnwrap(ChargingTotals.perMile(data, settings: settings))
        XCTAssertEqual(perMile.electric, 2923 / (140 / 1.609344), accuracy: 0.01)
        XCTAssertEqual(perMile.petrol, 140 / (45 / 4.54609), accuracy: 0.01)
    }

    func testMonthlyTotals() {
        let sessions = [
            ChargeSession(start: date("2026-09-02T00:00:00Z"), end: date("2026-09-02T05:00:00Z"), startPercent: 20, endPercent: 80, batteryKWh: 44, paidKWh: 48, costPence: 350, atHome: true),
            ChargeSession(start: date("2026-09-20T00:00:00Z"), end: date("2026-09-20T01:00:00Z"), startPercent: 10, endPercent: 80, batteryKWh: 52, paidKWh: 52, costPence: 4100, atHome: false),
            ChargeSession(start: date("2026-08-15T00:00:00Z"), end: date("2026-08-15T05:00:00Z"), startPercent: 30, endPercent: 80, batteryKWh: 37, paidKWh: 40, costPence: 300, atHome: true),
        ]
        let months = ChargingTotals.byMonth(sessions, calendar: utc)
        XCTAssertEqual(months.count, 2)
        XCTAssertEqual(months[0].totals.costPence, 4450)
        XCTAssertEqual(months[0].totals.publicCostPence, 4100)
        XCTAssertEqual(months[1].totals.sessions, 1)
        XCTAssertEqual(DisplayText.money(pence: 4450), "£44.50")
        XCTAssertEqual(DisplayText.money(pence: 86.4), "86p")
    }

    // MARK: Alerts

    func testAlertsAreSaidOnceUntilTheyClear() {
        var state = AlertState()
        let settings = AlertSettings()
        let now = date("2026-09-29T20:00:00Z")
        let unlocked = snap("2026-09-29T19:30:00Z", soc: 60, locked: false, aux: 65, windows: ["front left"])
        let first = AlertEngine.evaluate(previous: nil, current: unlocked, state: &state, settings: settings, now: now)
        XCTAssertEqual(Set(first.map(\.kind)), [.leftUnlocked, .windowOpen, .lowAuxBattery])
        XCTAssertTrue(first.contains { $0.body.contains("Front left is open") })

        let again = snap("2026-09-29T19:45:00Z", soc: 60, locked: false, aux: 65, windows: ["front left"])
        XCTAssertEqual(AlertEngine.evaluate(previous: unlocked, current: again, state: &state, settings: settings, now: now), [])

        let fixed = snap("2026-09-29T19:50:00Z", soc: 60, locked: true, aux: 85)
        XCTAssertEqual(AlertEngine.evaluate(previous: again, current: fixed, state: &state, settings: settings, now: now), [])
        let unlockedAgain = snap("2026-09-29T19:55:00Z", soc: 60, locked: false, aux: 85)
        XCTAssertEqual(AlertEngine.evaluate(previous: fixed, current: unlockedAgain, state: &state, settings: settings, now: date("2026-09-29T20:30:00Z")).map(\.kind), [.leftUnlocked])
    }

    func testChargingEndsAreReported() {
        var state = AlertState()
        let settings = AlertSettings(enabled: [.chargeComplete, .chargingStopped])
        let charging = snap("2026-09-29T20:00:00Z", soc: 50, plugged: true, charging: true)
        let stopped = snap("2026-09-29T21:00:00Z", soc: 55, plugged: true)
        let alerts = AlertEngine.evaluate(previous: charging, current: stopped, state: &state, settings: settings, now: date("2026-09-29T21:00:00Z"))
        XCTAssertEqual(alerts.map(\.kind), [.chargingStopped])
        XCTAssertEqual(alerts.first?.title, "EV6 stopped charging at 55%")

        var state2 = AlertState()
        let full = snap("2026-09-29T23:00:00Z", soc: 80, plugged: true)
        XCTAssertEqual(AlertEngine.evaluate(previous: charging, current: full, state: &state2, settings: settings, now: date("2026-09-29T23:00:00Z")).map(\.kind), [.chargeComplete])
    }

    // MARK: Octopus

    func testOctopusRegionProductAndRates() async throws {
        let server = ScriptedTransport()
        server.setDefault("/industry/grid-supply-points", jsonResponse(#"{"count":1,"results":[{"group_id":"_C"}]}"#))
        server.setDefault("/products", jsonResponse(#"{"results":[{"code":"AGILE-FLEX-22-11-25","direction":"IMPORT"},{"code":"AGILE-24-10-01","direction":"IMPORT"},{"code":"AGILE-OUTGOING-19-05-13","direction":"EXPORT"},{"code":"VAR-22-11-01","direction":"IMPORT"}]}"#))
        server.setDefault("/standard-unit-rates", jsonResponse(#"{"results":[{"value_exc_vat":10,"value_inc_vat":10.5,"valid_from":"2026-09-29T23:30:00Z","valid_to":"2026-09-30T00:00:00Z"},{"value_exc_vat":4,"value_inc_vat":4.2,"valid_from":"2026-09-29T23:00:00Z","valid_to":"2026-09-29T23:30:00Z"}]}"#))
        let octopus = OctopusClient(transport: server)
        let region = try await octopus.region(postcode: "sw1a 1aa")
        XCTAssertEqual(region, "C")
        XCTAssertEqual(server.last("/grid-supply-points")?.url.query, "postcode=SW1A1AA")
        let product = try await octopus.agileProduct()
        XCTAssertEqual(product, "AGILE-24-10-01")
        let rates = try await octopus.agileRates(product: "AGILE-24-10-01", region: "C", from: date("2026-09-29T23:00:00Z"), to: date("2026-09-30T00:00:00Z"))
        XCTAssertEqual(rates.map(\.pencePerKWh), [4.2, 10.5])
        XCTAssertEqual(server.last("/standard-unit-rates")?.url.path, "/v1/products/AGILE-24-10-01/electricity-tariffs/E-1R-AGILE-24-10-01-C/standard-unit-rates")

        server.setDefault("/industry/grid-supply-points", jsonResponse(#"{"count":0,"results":[]}"#))
        do {
            _ = try await octopus.region(postcode: "XX1")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? OctopusClient.Failure, .unknownPostcode)
        }
    }
}
