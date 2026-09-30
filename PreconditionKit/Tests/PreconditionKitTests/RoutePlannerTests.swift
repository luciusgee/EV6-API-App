import XCTest
@testable import PreconditionKit

final class RoutePlannerTests: XCTestCase {
    func charger(_ km: Double, _ kw: Double = 150, detour: Double = 1, name: String? = nil) -> RouteCharger {
        RouteCharger(id: "c\(Int(km))", name: name ?? "Hub \(Int(km))", position: LatLon(lat: 0, lon: 0), alongKm: km, detourKm: detour, powerKW: kw)
    }

    func testChargeCurveMatchesPublishedTimes() {
        // Kia quotes about 18 minutes for 10→80% on a 350 kW charger.
        let m = EV6ChargeCurve.minutes(from: 10, to: 80, chargerKW: 350, usableKWh: 74)
        XCTAssertEqual(m, 17, accuracy: 3)
        // A 50 kW charger is far slower.
        XCTAssertGreaterThan(EV6ChargeCurve.minutes(from: 10, to: 80, chargerKW: 50, usableKWh: 74), 55)
        XCTAssertEqual(EV6ChargeCurve.kW(at: 80), 100)
        XCTAssertEqual(EV6ChargeCurve.kW(at: 77.5), 125)
    }

    func testConsumptionRisesWithSpeedAndCold() {
        let town = ConsumptionModel(baseKWhPer100km: 17, averageKmh: 60, outsideC: 18, marginPercent: 0)
        XCTAssertEqual(town.kWhPer100km, 17, accuracy: 0.001)
        let winterMotorway = ConsumptionModel(baseKWhPer100km: 17, averageKmh: 110, outsideC: -2, marginPercent: 0)
        let expected: Double = 17.0 * 1.24 * 1.25
        XCTAssertEqual(winterMotorway.kWhPer100km, expected, accuracy: 0.001)
    }

    func testShortTripNeedsNoStop() {
        let plan = RoutePlanner.plan(distanceKm: 150, driveMinutes: 100, chargers: [charger(70)],
                                     trip: TripSettings(startPercent: 80), model: ConsumptionModel(baseKWhPer100km: 18, averageKmh: 90, marginPercent: 0))
        XCTAssertTrue(plan.stops.isEmpty)
        XCTAssertFalse(plan.unreachable)
        // 90 km/h average: +12% on 18 kWh/100 km.
        let used: Double = 150.0 * 18.0 * 1.12 / 74.0
        XCTAssertEqual(plan.arrivePercent, 80.0 - used, accuracy: 0.01)
    }

    func testLongTripStopsAtTheFarthestFastChargerAndOnlyChargesWhatsNeeded() throws {
        // 500 km at ~22.2 kWh/100 km is 111 kWh: at least one stop from 90%.
        let model = ConsumptionModel(baseKWhPer100km: 18, averageKmh: 110, outsideC: 20, marginPercent: 0)
        let chargers = [charger(100), charger(180, 50, name: "Rapid 180"), charger(230), charger(260, 350), charger(400)]
        let plan = RoutePlanner.plan(distanceKm: 500, driveMinutes: 300, chargers: chargers, trip: TripSettings(startPercent: 90), model: model)
        XCTAssertFalse(plan.unreachable, plan.stops.map { "\($0.charger.alongKm) \($0.arrivePercent)→\($0.departPercent)" }.description)
        let first = try XCTUnwrap(plan.stops.first)
        // 90% → 10% is 59.2 kWh ≈ 265 km at 22.3 kWh/100 km: the 350 kW hub at 260 km is just in reach.
        XCTAssertEqual(first.charger.alongKm, 260)
        XCTAssertEqual(first.departPercent, 80)
        // Then a short top-up at 400 km: only what the last 100 km needs.
        XCTAssertEqual(plan.stops.count, 2)
        XCTAssertLessThan(plan.stops[1].departPercent, 50)
        XCTAssertGreaterThanOrEqual(first.arrivePercent, 10)
        XCTAssertLessThanOrEqual(first.departPercent, 80)
        XCTAssertGreaterThanOrEqual(plan.arrivePercent, 14.9)
        XCTAssertGreaterThan(first.chargeMinutes, 5)
        XCTAssertEqual(plan.noStopStartPercent, nil)
    }

    func testAChosenChargerIsUsedWhenItsInReach() throws {
        let model = ConsumptionModel(baseKWhPer100km: 18, averageKmh: 110, outsideC: 20, marginPercent: 0)
        let chargers = [charger(100), charger(180, 50, name: "Rapid 180"), charger(230), charger(260, 350), charger(400)]
        let plan = RoutePlanner.plan(distanceKm: 500, driveMinutes: 300, chargers: chargers, trip: TripSettings(startPercent: 90), model: model, prefer: ["c180"])
        XCTAssertEqual(plan.stops.first?.charger.id, "c180")
        XCTAssertFalse(plan.unreachable)
    }

    func testNoChargerInRangeIsUnreachable() {
        let plan = RoutePlanner.plan(distanceKm: 600, driveMinutes: 360, chargers: [charger(450)],
                                     trip: TripSettings(startPercent: 80), model: ConsumptionModel())
        XCTAssertTrue(plan.unreachable)
    }

    func testPowerGuessFromTheOperator() {
        XCTAssertEqual(ChargerPower.guess(name: "IONITY Cobham"), 150)
        XCTAssertEqual(ChargerPower.guess(name: "Gridserve Electric Highway"), 150)
        XCTAssertEqual(ChargerPower.guess(name: "Premier Inn Destination Charger"), 22)
        XCTAssertEqual(ChargerPower.guess(name: "Some Charger"), 50)
    }
}

extension RoutePlannerTests {
    func testTeslaSuperchargersArePlannedAtWhatAnEV6Gets() {
        XCTAssertEqual(ChargerPower.guess(name: "Tesla Supercharger Leicester Forest East"), 60)
        XCTAssertEqual(ChargerPower.forEV6(250, name: "Tesla · Supercharger Stafford"), 60)
        XCTAssertEqual(ChargerPower.forEV6(350, name: "Ionity Stafford"), 350)
        XCTAssertEqual(ChargerPower.guess(name: "Ionity Stafford Services"), 150)
    }

    func testThereAndBackCarriesTheChargeOverAndStopsOnlyWhenNeeded() {
        let model = ConsumptionModel(baseKWhPer100km: 18, averageKmh: 90, marginPercent: 0)
        let out = TripLeg(distanceKm: 150, driveMinutes: 100, chargers: [charger(70)], model: model)
        let back = TripLeg(distanceKm: 150, driveMinutes: 100, chargers: [charger(70, 150, name: "Back 70")], model: model)
        let legs = RoutePlanner.planLegs([out, back], trip: TripSettings(startPercent: 80), stays: [180])
        XCTAssertEqual(legs.count, 2)
        XCTAssertTrue(legs[0].plan.stops.isEmpty)
        // The way back starts with what the way out arrived with, three hours after arriving.
        XCTAssertEqual(legs[1].trip.startPercent, legs[0].plan.arrivePercent, accuracy: 0.001)
        XCTAssertEqual(legs[1].startMinutes, legs[0].plan.totalMinutes + 180, accuracy: 0.001)
        // 80% less two 150 km drives doesn't leave 15%: one stop on the way back.
        XCTAssertEqual(legs[1].plan.stops.map(\.charger.name), ["Back 70"])
        XCTAssertGreaterThanOrEqual(legs[1].plan.arrivePercent, 15 - 0.01)
    }
}
