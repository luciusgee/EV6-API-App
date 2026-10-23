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
        XCTAssertEqual(a.checks.first { $0.title == "Cell balance" }?.status, .attention)
        XCTAssertEqual(a.grade, "D")
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
}
