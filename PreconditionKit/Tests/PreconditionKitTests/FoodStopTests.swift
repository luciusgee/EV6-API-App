import Foundation
import XCTest
@testable import PreconditionKit

final class FoodStopTests: XCTestCase {
    func testChainsMatchHoweverTheyreWritten() {
        let places = ["McDonald’s", "Burger King Drive Thru", "WHSmith", "Costa Coffee", "Leon", "Moto Services"]
        let found = FoodMatch.chains(at: places, from: FoodChain.ukVegan)
        XCTAssertEqual(found.map(\.name), ["Burger King", "LEON", "McDonald's", "Costa"])
        XCTAssertFalse(FoodChain(name: "Subway").matches("Waitrose"))
        XCTAssertTrue(FoodChain.ukVegan.first { $0.name == "M&S Food" }!.matches("M&S Simply Food"))
        XCTAssertFalse(FoodChain(name: "Itsu").matches(""))
    }

    func testTheOrderOfYourChainsIsKept() {
        let mine = [FoodChain(name: "Subway"), FoodChain(name: "Burger King")]
        XCTAssertEqual(FoodMatch.chains(at: ["Burger King", "Subway"], from: mine).map(\.name), ["Subway", "Burger King"])
    }

    func testStopOptionsAreTheChargersInReachForThatLeg() {
        let chargers = stride(from: 40.0, through: 300, by: 20).map {
            RouteCharger(id: "c\(Int($0))", name: "Services \(Int($0))", position: LatLon(lat: 52, lon: 0), alongKm: $0, detourKm: 0, powerKW: 150)
        }
        let trip = TripSettings(startPercent: 60, minArrivalPercent: 10, destinationPercent: 15, maxChargePercent: 80, usableKWh: 74)
        let model = ConsumptionModel(baseKWhPer100km: 20, averageKmh: 70, marginPercent: 0)
        let plan = RoutePlanner.plan(distanceKm: 320, driveMinutes: 240, chargers: chargers, trip: trip, model: model)
        XCTAssertEqual(plan.stops.count, 1)
        let options = RoutePlanner.stopOptions(for: 0, in: plan, distanceKm: 320, driveMinutes: 240, chargers: chargers, trip: trip, model: model)
        // 60% of 74 kWh at 20 kWh/100 km is 222 km; keeping 10% leaves 185 km of reach.
        XCTAssertEqual(options.first?.charger.alongKm, 40)
        XCTAssertEqual(options.last?.charger.alongKm, 180)
        XCTAssertTrue(options.contains { $0.id == plan.stops[0].id })
        let at100: Double = 100
        let expectedMinutes: Double = at100 * 240 / 320
        XCTAssertEqual(options.first { $0.charger.alongKm == at100 }?.minutesIn ?? 0, expectedMinutes, accuracy: 0.01)
        XCTAssertTrue(options.allSatisfy { $0.arrivePercent >= 10 })
        XCTAssertEqual(RoutePlanner.stopOptions(for: 3, in: plan, distanceKm: 320, driveMinutes: 240, chargers: chargers, trip: trip, model: model), [])
    }

    func testASavedTripSendsItsStopsThenTheDestination() throws {
        let trip = SavedTrip(name: "Manchester", destination: NavPoint(name: "Manchester", position: LatLon(lat: 53.48, lon: -2.24)),
                             stops: [SavedTrip.Stop(name: "Stafford Services", position: LatLon(lat: 52.87, lon: -2.17), kW: 150, food: ["Burger King"])])
        XCTAssertEqual(trip.navPoints.map(\.name), ["Stafford Services", "Manchester"])
        let data = try JSONEncoder().encode(trip)
        XCTAssertEqual(try JSONDecoder().decode(SavedTrip.self, from: data), trip)
    }
}
