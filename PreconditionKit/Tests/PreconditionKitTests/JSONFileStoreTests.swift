import Foundation
import XCTest
@testable import PreconditionKit

final class JSONFileStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("JSONFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func setAsideFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".unreadable-") }
    }

    func testMissingFileGivesTheDefault() async {
        let store = JSONFileStore(url: folder.appendingPathComponent("missing.json"), default: [1, 2])
        let value = await store.load()
        XCTAssertEqual(value, [1, 2])
    }

    func testCorruptFileIsSetAsideNotOverwritten() async throws {
        let url = folder.appendingPathComponent("runs.json")
        let bad = Data("{not json".utf8)
        try bad.write(to: url)
        let store = JSONFileStore(url: url, default: [Int]())
        let first = await store.load()
        XCTAssertEqual(first, [])
        let aside = try setAsideFiles()
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: aside[0]), bad)

        await store.save([7])
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: Data(contentsOf: url)), [7])
        XCTAssertEqual(try Data(contentsOf: aside[0]), bad)
        XCTAssertEqual(try setAsideFiles().count, 1)
    }

    func testRoundTripThroughANewStore() async {
        let url = folder.appendingPathComponent("value.json")
        let session = ChargeSession(started: t0)
        await JSONFileStore(url: url, default: [ChargeSession]()).save([session])
        let back = await JSONFileStore(url: url, default: [ChargeSession]()).load()
        XCTAssertEqual(back, [session])
    }

    func testOldRunsLoadAndBadOnesAreSkipped() async throws {
        let url = folder.appendingPathComponent("runs.json")
        // An early build's runs: no rollout, motion launch, splits or trace; and a type since renamed.
        let json = """
        [{"id":"8C2F4C1E-2F5A-4B8E-9C1D-3E6F7A8B9C0D","type":"quarterMile","date":"2026-09-01T10:00:00Z",
          "seconds":12.9,"metres":402.3,"endKmh":170,"peakKmh":170,"readingsPerSecond":9,"car":"EV6"},
         {"id":"9C2F4C1E-2F5A-4B8E-9C1D-3E6F7A8B9C0D","type":"zeroTo62mph","date":"2026-09-01T10:00:00Z","seconds":3.4}]
        """
        try Data(json.utf8).write(to: url)
        let store = JSONFileStore(url: url, default: LossyArray<RunResult>([]))
        let runs = await store.load().elements
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.type, .quarterMile)
        XCTAssertEqual(runs.first?.car, "EV6")
        XCTAssertEqual(runs.first?.motionLaunch, false)
        XCTAssertTrue(try setAsideFiles().isEmpty)
    }

    func testOldChargesAndReportsDecode() throws {
        let charge = try JSONDecoder().decode(ChargeSession.self, from: Data(#"{"started":780000000,"energyKWh":12.5,"points":[{"seconds":0,"kW":50},{"bad":true}]}"#.utf8))
        XCTAssertEqual(charge.energyKWh, 12.5)
        XCTAssertEqual(charge.points.count, 1)
        let report = try JSONDecoder().decode(BatteryReport.self, from: Data(#"{"takenAt":780000000,"sohPercent":97.5}"#.utf8))
        XCTAssertEqual(report.sohPercent, 97.5)
        XCTAssertTrue(report.cellVolts.isEmpty)
    }

    /// A path that's a directory reads as "exists but unreadable" (file permissions don't stop root).
    private func blockedURL(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func unblock(_ url: URL, with value: [Int]) throws {
        try FileManager.default.removeItem(at: url)
        try JSONEncoder().encode(value).write(to: url)
    }

    func testSavesWaitForAFileThatWasUnreadable() async throws {
        let url = try blockedURL("blocked.json")
        let store = JSONFileStore(url: url, default: [Int]())
        let first = await store.load()
        XCTAssertEqual(first, [])
        try unblock(url, with: [1, 2])

        await store.save([3])
        await store.save([3])
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: Data(contentsOf: url)), [1, 2])
        let loaded = await store.load()
        XCTAssertEqual(loaded, [1, 2])
        XCTAssertTrue(try setAsideFiles().isEmpty)
    }

    func testAMergeWritesSavesMadeWhileTheFileWasUnreadable() async throws {
        let url = try blockedURL("merged.json")
        let store = JSONFileStore(url: url, default: [Int](), merge: { $0 + $1 })
        _ = await store.load()
        // Still unreadable: nothing written, nothing lost.
        let held = await store.save([3])
        XCTAssertEqual(held, [3])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)

        try unblock(url, with: [1, 2])
        let saved = await store.save([3])
        XCTAssertEqual(saved, [1, 2, 3])
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: Data(contentsOf: url)), [1, 2, 3])
        // Back to plain saves after that.
        await store.save([4])
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: Data(contentsOf: url)), [4])
    }

    func testMergingByIDKeepsTheFilesOthersAndPrefersMine() {
        let a = ChargeSession(started: t0)
        var b = ChargeSession(started: t0.addingTimeInterval(60))
        let c = ChargeSession(started: t0.addingTimeInterval(120))
        let file = LossyArray([a, b])
        b.started = t0.addingTimeInterval(90)
        let merged = LossyArray.mergingByID(file: file, mine: LossyArray([b, c]))
        XCTAssertEqual(merged.elements, [a, b, c])
        XCTAssertEqual(merged.elements[1].started, t0.addingTimeInterval(90))
    }
}
