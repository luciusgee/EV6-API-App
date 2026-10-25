import Foundation
import XCTest
@testable import PreconditionKit

final class BatteryAnalysisTests: XCTestCase {
    private func report(soh: Double? = 97, cells: [Double]) -> BatteryReport {
        var r = BatteryReport(takenAt: t0)
        r.sohPercent = soh
        r.cellVolts = cells
        r.moduleTempsC = [18, 19, 19, 20, 18, 19, 21, 19, 18, 19, 20, 19, 19, 18, 20, 19]
        r.cumulativeChargedKWh = 7740
        r.cumulativeDischargedKWh = 7200
        return r
    }

    func testHealthyPack() {
        var cells = (0..<192).map { 3.85 + Double($0 % 4) * 0.002 }
        cells[100] = 3.84
        let a = BatteryAnalysis(report(cells: cells))
        XCTAssertEqual(a.nominalKWh, 77.4)
        XCTAssertEqual(a.estimatedKWh ?? 0, 75.08, accuracy: 0.01)
        XCTAssertEqual(a.spreadMV ?? 0, 16, accuracy: 0.01)
        XCTAssertEqual(a.weakest.first?.number, 101)
        XCTAssertEqual(a.modules.count, 32)
        XCTAssertEqual(a.modules[16].cells, 97...102)
        XCTAssertEqual(a.modules.last?.temperatureC, 19)
        XCTAssertEqual(a.equivalentCycles ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(a.throughputRatio ?? 0, 0.93, accuracy: 0.01)
        XCTAssertEqual(a.checks.first?.status, .good)
        XCTAssertEqual(a.grade, "A")
    }

    func testWeakCellIsAnOutlier() {
        var cells = Array(repeating: 3.9, count: 192)
        cells[7] = 3.82
        let a = BatteryAnalysis(report(soh: 92, cells: cells))
        XCTAssertEqual(a.outliers.map(\.number), [8])
        XCTAssertEqual(a.checks.first { $0.title == "Weakest cell" }?.status, .attention)
        // 80 mV apart is four reading steps: fair, not attention.
        XCTAssertEqual(a.checks.first { $0.title == "Cell balance" }?.status, .fair)
        // B by health, one step down for the weak cell.
        XCTAssertEqual(a.grade, "C")
    }

    func testBalanceCheckAgreesWithTheFindings() {
        // (3.84 - 3.80) * 1000 is a hair over 40 in floating point: still two reading steps.
        let close = report(cells: [3.80, 3.84])
        XCTAssertEqual(BatteryAnalysis(close).checks.first { $0.title == "Cell balance" }?.status, .good)
        XCTAssertTrue(close.findings.contains("Cells balanced within 40 mV."))

        let apart = report(cells: [3.80, 3.88])
        XCTAssertEqual(BatteryAnalysis(apart).checks.first { $0.title == "Cell balance" }?.status, .fair)
        XCTAssertTrue(apart.findings.contains("Cells 80 mV apart: charge to 100% now and then to let them balance."))
    }

    func testWithoutCells() {
        var r = BatteryReport(takenAt: t0)
        r.sohPercent = 88
        r.cellMaxVolts = 3.9
        r.cellMinVolts = 3.88
        let a = BatteryAnalysis(r)
        XCTAssertNil(a.nominalKWh)
        XCTAssertEqual(a.spreadMV ?? 0, 20, accuracy: 0.01)
        XCTAssertTrue(a.modules.isEmpty)
        XCTAssertEqual(a.grade, "C")
    }

    func testOneReadingStepIsNotAWeakCell() {
        var cells = Array(repeating: 3.80, count: 192)
        cells[50] = 3.78
        let a = BatteryAnalysis(report(cells: cells))
        XCTAssertTrue(a.outliers.isEmpty)
        XCTAssertEqual(a.checks.first { $0.title == "Weakest cell" }?.status, .good)
    }

    func testTwoReadingStepsLowIsStillAnAPack() {
        var cells = Array(repeating: 3.88, count: 192)
        cells[0] = 3.84
        let a = BatteryAnalysis(report(soh: 96, cells: cells))
        XCTAssertTrue(a.outliers.isEmpty)
        XCTAssertEqual(a.checks.first { $0.title == "Weakest cell" }?.status, .good)
        XCTAssertEqual(a.checks.first { $0.title == "Cell balance" }?.status, .good)
        XCTAssertEqual(a.grade, "A")
    }

    func testPacksThatArentWholeModulesHaveNoModuleMap() {
        let a = BatteryAnalysis(report(cells: Array(repeating: 3.8, count: 160)))
        XCTAssertEqual(a.cellCount, 160)
        XCTAssertTrue(a.modules.isEmpty)
    }

    func testTemperatureSpreadIsOnlyJudgedAtRest() {
        var r = report(soh: 100, cells: (0..<192).map { 3.85 + Double($0 % 2) * 0.002 })
        r.moduleTempsC = [20, 31] + Array(repeating: 25, count: 14)
        r.packAmps = -150
        let charging = BatteryAnalysis(r)
        XCTAssertEqual(charging.checks.first { $0.title == "Temperature spread" }?.status, .unknown)
        XCTAssertEqual(charging.grade, "A")
        r.packAmps = 0
        let resting = BatteryAnalysis(r)
        XCTAssertEqual(resting.checks.first { $0.title == "Temperature spread" }?.status, .attention)
        XCTAssertEqual(resting.grade, "B")
    }
}
