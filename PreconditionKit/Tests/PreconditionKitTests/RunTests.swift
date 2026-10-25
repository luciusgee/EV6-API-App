import Foundation
import XCTest
@testable import PreconditionKit

final class RunTests: XCTestCase {
    /// Feeds a run at constant acceleration (km/h per second) from `fromKmh`, a reading every `dt`.
    private func drive(_ timer: inout RunTimer, from fromKmh: Double, accel: Double, dt: Double = 0.2, seconds: Double, start: Date = t0, power: Double? = 200) {
        var t = 0.0
        while t <= seconds + 1e-9 {
            timer.add(at: start.addingTimeInterval(t), kmh: max(0, fromKmh + accel * t), powerKW: power)
            t += dt
        }
    }

    func testZeroToSixtyInterpolatesTheCrossing() {
        var timer = RunTimer(type: .zeroTo60mph)
        timer.add(at: t0.addingTimeInterval(-1), kmh: 0)
        XCTAssertEqual(timer.state, .armed)
        // 0.5 km/h is passed at 0.0125 s; 96.56 km/h at 2.414 s.
        drive(&timer, from: 0, accel: 40, dt: 0.3, seconds: 4)
        guard case .finished(let r) = timer.state else { return XCTFail("\(timer.state)") }
        XCTAssertEqual(r.seconds, 96.56064 / 40 - 0.5 / 40, accuracy: 0.01)
        XCTAssertEqual(r.endKmh, 96.56, accuracy: 0.1)
        XCTAssertEqual(r.peakPowerKW, 200)
        XCTAssertTrue(r.readingsPerSecond > 3)
        XCTAssertTrue(r.splits.contains { $0.label == "0–30 mph" })
        XCTAssertFalse(r.splits.contains { $0.label == "0–60 mph" })
    }

    func testNeedsAStopFirst() {
        var timer = RunTimer(type: .zeroTo100kmh)
        timer.add(at: t0, kmh: 30)
        XCTAssertEqual(timer.state, .waiting("Come to a stop"))
        timer.add(at: t0.addingTimeInterval(1), kmh: 50)
        guard case .waiting = timer.state else { return XCTFail() }
    }

    func testQuarterMileDistanceAndTrap() {
        var timer = RunTimer(type: .quarterMile)
        timer.add(at: t0.addingTimeInterval(-1), kmh: 0)
        // Constant a = 10 km/h/s = 2.778 m/s². 402.336 m takes sqrt(2·402.336/2.778) ≈ 17.02 s.
        drive(&timer, from: 0, accel: 10, dt: 0.25, seconds: 20)
        guard case .finished(let r) = timer.state else { return XCTFail("\(timer.state)") }
        XCTAssertEqual(r.metres, 402.336, accuracy: 0.01)
        XCTAssertEqual(r.seconds, (2 * 402.336 / (10 / 3.6)).squareRoot(), accuracy: 0.1)
        XCTAssertEqual(r.endKmh, r.seconds * 10, accuracy: 1.5)
        let labels = r.splits.filter { $0.kind == .distance }.map(\.label)
        XCTAssertEqual(labels, ["60 ft", "330 ft", "⅛ mile", "1000 ft"])
    }

    func testRolloutTakesTheFirstFootOff() {
        var plain = RunTimer(type: .quarterMile)
        var rolled = RunTimer(type: .quarterMile, rollout: true)
        for timer in [0, 1] {
            var t = timer == 0 ? plain : rolled
            t.add(at: t0.addingTimeInterval(-1), kmh: 0)
            drive(&t, from: 0, accel: 10, dt: 0.25, seconds: 20)
            if timer == 0 { plain = t } else { rolled = t }
        }
        guard case .finished(let a) = plain.state, case .finished(let b) = rolled.state else { return XCTFail() }
        XCTAssertTrue(b.rollout)
        // A foot at 2.78 m/s² takes about 0.47 s.
        XCTAssertEqual(a.seconds - b.seconds, 0.47, accuracy: 0.1)
    }

    func testInGearPull() {
        var timer = RunTimer(type: .fiftyTo70mph)
        timer.add(at: t0, kmh: 70)
        XCTAssertEqual(timer.state, .armed)
        // From 70 km/h at 20 km/h/s: 80.47 at 0.52 s, 112.65 at 2.13 s.
        drive(&timer, from: 70, accel: 20, dt: 0.2, seconds: 3, start: t0.addingTimeInterval(0.2))
        guard case .finished(let r) = timer.state else { return XCTFail("\(timer.state)") }
        XCTAssertEqual(r.seconds, (112.654 - 80.467) / 20, accuracy: 0.01)
        XCTAssertEqual(r.trace.first?.kmh ?? 0, 80.467, accuracy: 0.01)
        XCTAssertTrue(r.splits.contains { $0.label == "50–60 mph" })
    }

    func testInGearAbortsWhenSlowingDown() {
        var timer = RunTimer(type: .fiftyTo70mph)
        timer.add(at: t0, kmh: 75)
        timer.add(at: t0.addingTimeInterval(0.5), kmh: 85)
        guard case .running = timer.state else { return XCTFail("\(timer.state)") }
        timer.add(at: t0.addingTimeInterval(1), kmh: 70)
        XCTAssertEqual(timer.state, .armed)
    }

    func testBrakingDistance() {
        var timer = RunTimer(type: .brake100kmh)
        timer.add(at: t0, kmh: 110)
        XCTAssertEqual(timer.state, .armed)
        // From 110 km/h at -36 km/h/s (1.02 g): 100 at 0.278 s, stop at 3.06 s.
        drive(&timer, from: 110, accel: -36, dt: 0.2, seconds: 3.4, start: t0.addingTimeInterval(0.2))
        guard case .finished(let r) = timer.state else { return XCTFail("\(timer.state)") }
        XCTAssertEqual(r.seconds, (100 - 0.5) / 36, accuracy: 0.02)
        // v²/2a = 27.78² / (2·10) ≈ 38.6 m.
        XCTAssertEqual(r.metres, 38.6, accuracy: 1)
        XCTAssertEqual(r.peakDecelG ?? 0, 1.02, accuracy: 0.05)
        XCTAssertTrue(r.splits.isEmpty)
    }

    func testMotionLaunchStartsEarlier() {
        var timer = RunTimer(type: .zeroTo60mph)
        timer.add(at: t0, kmh: 0)
        let launch = t0.addingTimeInterval(0.1)
        timer.add(at: t0.addingTimeInterval(0.4), kmh: 8, launchedAt: launch)
        guard case .running(let since) = timer.state else { return XCTFail("\(timer.state)") }
        XCTAssertEqual(since, launch)
    }

    func testTimesOut() {
        var timer = RunTimer(type: .zeroTo200kmh)
        timer.add(at: t0, kmh: 0)
        timer.add(at: t0.addingTimeInterval(1), kmh: 10)
        timer.add(at: t0.addingTimeInterval(200), kmh: 100)
        guard case .waiting = timer.state else { return XCTFail("\(timer.state)") }
    }

    func testResultRoundTrips() throws {
        var timer = RunTimer(type: .zeroTo60mph)
        timer.note(soc: 80, batteryC: 25, car: "EV6")
        timer.add(at: t0.addingTimeInterval(-1), kmh: 0)
        drive(&timer, from: 0, accel: 40, seconds: 3)
        guard case .finished(let r) = timer.state else { return XCTFail() }
        XCTAssertEqual(r.socPercent, 80)
        let back = try JSONDecoder().decode(RunResult.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
    }

    func testEveryTypeHasWords() {
        for type in RunType.allCases {
            XCTAssertFalse(type.title.isEmpty)
            XCTAssertFalse(type.instructions.isEmpty)
        }
        XCTAssertEqual(RunType.fiftyTo70mph.instructions, "Drive steadily below 50 mph, then accelerate hard through it.")
        XCTAssertEqual(RunType.eightyTo120kmh.category, .rolling)
        XCTAssertEqual(RunType.standingMile.category, .distance)
    }

    func testACreepToTheLineIsNotTheStart() {
        var timer = RunTimer(type: .zeroTo60mph)
        timer.add(at: t0.addingTimeInterval(-1), kmh: 0)
        timer.add(at: t0, kmh: 2)
        timer.add(at: t0.addingTimeInterval(0.5), kmh: 3)
        timer.add(at: t0.addingTimeInterval(1), kmh: 0)
        XCTAssertEqual(timer.state, .armed)
        let launch = t0.addingTimeInterval(5)
        drive(&timer, from: 0, accel: 40, dt: 0.3, seconds: 4, start: launch)
        guard case .finished(let r) = timer.state else { return XCTFail("\(timer.state)") }
        XCTAssertEqual(r.seconds, 96.56064 / 40 - 0.5 / 40, accuracy: 0.02)
        XCTAssertEqual(r.date.timeIntervalSince(launch), 0.0125, accuracy: 0.02)
    }

    func testAGapAbandonsTheAttempt() {
        var timer = RunTimer(type: .zeroTo60mph)
        timer.add(at: t0.addingTimeInterval(-1), kmh: 0)
        timer.add(at: t0, kmh: 10)
        timer.add(at: t0.addingTimeInterval(0.3), kmh: 20)
        guard case .running = timer.state else { return XCTFail("\(timer.state)") }
        timer.add(at: t0.addingTimeInterval(0.3 + RunTimer.maxGap + 0.5), kmh: 100)
        if case .finished = timer.state { XCTFail("finished across a gap") }
    }

    func testTickAbandonsARunWhoseReadingsStopped() {
        var timer = RunTimer(type: .zeroTo60mph)
        timer.add(at: t0.addingTimeInterval(-1), kmh: 0)
        timer.add(at: t0, kmh: 10)
        timer.add(at: t0.addingTimeInterval(0.3), kmh: 20)
        guard case .running = timer.state else { return XCTFail("\(timer.state)") }
        // Within the gap: still running.
        timer.tick(now: t0.addingTimeInterval(0.3 + RunTimer.maxGap - 0.1))
        guard case .running = timer.state else { return XCTFail("\(timer.state)") }
        timer.tick(now: t0.addingTimeInterval(0.3 + RunTimer.maxGap + 0.1))
        guard case .waiting = timer.state else { return XCTFail("\(timer.state)") }
        XCTAssertTrue(timer.trace.isEmpty)
        // A fresh stop arms it again.
        timer.add(at: t0.addingTimeInterval(5), kmh: 0)
        XCTAssertEqual(timer.state, .armed)
    }

    func testTickAbandonsARunPastTheTimeLimit() {
        var timer = RunTimer(type: .quarterMile)
        timer.add(at: t0.addingTimeInterval(-1), kmh: 0)
        // So slow it is still short of the quarter mile when the time limit comes (it passes walking
        // pace about 5 s in, so the clock is just short of the limit at the last reading).
        drive(&timer, from: 0, accel: 0.1, dt: 0.5, seconds: RunTimer.maxSeconds + 3)
        guard case .running(let since) = timer.state else { return XCTFail("\(timer.state)") }
        timer.tick(now: since.addingTimeInterval(RunTimer.maxSeconds - 0.5))
        guard case .running = timer.state else { return XCTFail("abandoned too soon: \(timer.state)") }
        timer.tick(now: since.addingTimeInterval(RunTimer.maxSeconds + 0.1))
        guard case .waiting = timer.state else { return XCTFail("\(timer.state)") }
    }

    func testTickLeavesOtherStatesAlone() {
        var timer = RunTimer(type: .zeroTo60mph)
        timer.add(at: t0, kmh: 0)
        XCTAssertEqual(timer.state, .armed)
        timer.tick(now: t0.addingTimeInterval(60))
        XCTAssertEqual(timer.state, .armed)
    }

    func testRolloutSplitsCountFromZero() {
        var timer = RunTimer(type: .quarterMile, rollout: true)
        timer.add(at: t0.addingTimeInterval(-1), kmh: 0)
        drive(&timer, from: 0, accel: 10, dt: 0.25, seconds: 20)
        guard case .finished(let r) = timer.state else { return XCTFail("\(timer.state)") }
        let speeds = r.splits.filter { $0.kind == .speedMph }.map(\.label)
        XCTAssertFalse(speeds.isEmpty)
        XCTAssertTrue(speeds.allSatisfy { $0.hasPrefix("0–") }, "\(speeds)")
    }

    func testAnAbortedMotionLaunchIsForgotten() {
        var timer = RunTimer(type: .zeroTo60mph)
        timer.add(at: t0, kmh: 0)
        timer.add(at: t0.addingTimeInterval(0.4), kmh: 8, launchedAt: t0.addingTimeInterval(0.1))
        guard case .running = timer.state else { return XCTFail("\(timer.state)") }
        timer.add(at: t0.addingTimeInterval(0.8), kmh: 0)
        XCTAssertEqual(timer.state, .armed)
        drive(&timer, from: 0, accel: 40, dt: 0.3, seconds: 4, start: t0.addingTimeInterval(3))
        guard case .finished(let r) = timer.state else { return XCTFail("\(timer.state)") }
        XCTAssertFalse(r.motionLaunch)
    }

    func testNotedContextSurvivesATimeout() {
        var timer = RunTimer(type: .zeroTo200kmh)
        timer.note(soc: 80, batteryC: 25, car: "EV6")
        timer.add(at: t0, kmh: 0)
        timer.add(at: t0.addingTimeInterval(1), kmh: 10)
        timer.add(at: t0.addingTimeInterval(200), kmh: 100)
        guard case .waiting = timer.state else { return XCTFail("\(timer.state)") }
        timer.add(at: t0.addingTimeInterval(299), kmh: 0)
        drive(&timer, from: 0, accel: 40, dt: 0.3, seconds: 6, start: t0.addingTimeInterval(300))
        guard case .finished(let r) = timer.state else { return XCTFail("\(timer.state)") }
        XCTAssertEqual(r.socPercent, 80)
        XCTAssertEqual(r.car, "EV6")
    }

    func testPromptsMatchTheArmMargin() {
        XCTAssertEqual(RunTimer.waitingWords(.brake60mph), "Get above 63 mph")
        XCTAssertEqual(RunTimer.waitingWords(.brake100kmh), "Get above 103 km/h")
        XCTAssertEqual(RunType.brake60mph.instructions, "Get above 63 mph, then brake hard to a stop.")
    }

    func testOldRunsStillDecode() throws {
        // Saved before rollout, motion launch, splits and the trace were kept.
        let json = """
        [{"id":"8C2F4C1E-2F5A-4B8E-9C1D-3E6F7A8B9C0D","type":"zeroTo60mph","date":780000000,"seconds":3.4,
          "metres":45,"endKmh":96.6,"peakKmh":96.6,"readingsPerSecond":8},
         {"id":"9C2F4C1E-2F5A-4B8E-9C1D-3E6F7A8B9C0D","type":"renamedType","date":780000000,"seconds":3.4}]
        """
        let runs = try JSONDecoder().decode(LossyArray<RunResult>.self, from: Data(json.utf8)).elements
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].type, .zeroTo60mph)
        XCTAssertFalse(runs[0].rollout)
        XCTAssertFalse(runs[0].motionLaunch)
        XCTAssertTrue(runs[0].splits.isEmpty)
        XCTAssertTrue(runs[0].trace.isEmpty)
    }
}

final class LapTimerTests: XCTestCase {
    private let origin = GeoPoint(lat: 52.0, lon: -1.0)

    /// A point `x` metres east and `y` metres north of the origin.
    private func at(_ x: Double, _ y: Double) -> GeoPoint {
        let k = 180 / Double.pi / GeoPoint.earthRadius
        return GeoPoint(lat: origin.lat + y * k, lon: origin.lon + x * k / cos(origin.lat * .pi / 180))
    }

    /// Drives around a 100 m square loop heading north through the origin, at `speed` m/s.
    private func lap(_ timer: inout LapTimer, start: Date, speed: Double) -> Date {
        // Corners: (0,-10) → (0,90) → (-100,90) → (-100,-10) → back.
        let path: [(Double, Double)] = [(0, -10), (0, 90), (-100, 90), (-100, -10), (0, -10)]
        var t = start
        for (a, b) in zip(path, path.dropFirst()) {
            let length = hypot(b.0 - a.0, b.1 - a.1)
            let steps = Int(length / (speed * 0.5))
            for i in 1...steps {
                let f = Double(i) / Double(steps)
                t = t.addingTimeInterval(length / speed / Double(steps))
                timer.add(at: t, point: at(a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f), kmh: speed * 3.6)
            }
        }
        return t
    }

    func testLapsAndBest() {
        var timer = LapTimer(line: FinishLine(centre: origin, heading: 0))
        timer.add(at: t0, point: at(0, -10))
        var t = lap(&timer, start: t0, speed: 10)
        XCTAssertNotNil(timer.lapStart)
        XCTAssertTrue(timer.laps.isEmpty)
        t = lap(&timer, start: t, speed: 10)
        t = lap(&timer, start: t, speed: 12.5)
        t = lap(&timer, start: t, speed: 12.5)
        // Each lap runs from y = 0 on one call to y = 0 on the next, 10 m in.
        XCTAssertEqual(timer.laps.map(\.seconds).count, 3)
        XCTAssertEqual(timer.laps[0].seconds, 40, accuracy: 0.05)
        XCTAssertEqual(timer.laps[1].seconds, 39.8, accuracy: 0.05)
        XCTAssertEqual(timer.laps[2].seconds, 32, accuracy: 0.05)
        XCTAssertEqual(timer.laps[0].metres, 400, accuracy: 1)
        XCTAssertEqual(timer.best?.number, 3)
        _ = t
    }

    func testDeltaAgainstBest() {
        var timer = LapTimer(line: FinishLine(centre: origin, heading: 0))
        timer.add(at: t0, point: at(0, -10))
        var t = lap(&timer, start: t0, speed: 10)
        t = lap(&timer, start: t, speed: 10)
        _ = lap(&timer, start: t, speed: 12.5)
        // Lap 2 (39.8 s) is the best. Lap 3, 390 m in at 12.5 m/s: 31.2 s against 39 s.
        XCTAssertEqual(timer.best?.number, 2)
        XCTAssertEqual(timer.delta ?? 99, -7.8, accuracy: 0.1)
    }

    func testIgnoresWrongWayAndWideCrossings() {
        var timer = LapTimer(line: FinishLine(centre: origin, heading: 0, halfWidth: 10))
        timer.add(at: t0, point: at(0, 10))
        timer.add(at: t0.addingTimeInterval(1), point: at(0, -10))
        XCTAssertNil(timer.lapStart)
        timer.add(at: t0.addingTimeInterval(2), point: at(30, -10))
        timer.add(at: t0.addingTimeInterval(3), point: at(30, 10))
        XCTAssertNil(timer.lapStart)
        timer.add(at: t0.addingTimeInterval(4), point: at(5, -10))
        timer.add(at: t0.addingTimeInterval(5), point: at(5, 10))
        XCTAssertEqual(timer.lapStart!.timeIntervalSince(t0), 4.5, accuracy: 0.01)
    }

    /// Drives `path` (metres from the origin) at `speed` m/s, a fix every half second.
    private func drive(_ timer: inout LapTimer, _ path: [(Double, Double)], start: Date, speed: Double, kmh: Double? = nil, course: Double? = nil) -> Date {
        var t = start
        for (a, b) in zip(path, path.dropFirst()) {
            let length = hypot(b.0 - a.0, b.1 - a.1)
            let steps = max(1, Int(length / (speed * 0.5)))
            for i in 1...steps {
                let f = Double(i) / Double(steps)
                t = t.addingTimeInterval(length / speed / Double(steps))
                timer.add(at: t, point: at(a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f), kmh: kmh ?? speed * 3.6, course: course)
            }
        }
        return t
    }

    func testFirstLapCountsFromSetLine() {
        var timer = LapTimer(line: FinishLine(centre: origin, heading: 0), startedAt: t0)
        XCTAssertEqual(timer.lapStart, t0)
        // Off the line north, round the 100 m square and back across it: 400 m at 10 m/s.
        _ = drive(&timer, [(0, 0), (0, 90), (-100, 90), (-100, -10), (0, -10), (0, 10)], start: t0, speed: 10)
        XCTAssertEqual(timer.laps.count, 1)
        XCTAssertEqual(timer.laps.first?.seconds ?? 0, 40, accuracy: 0.1)
    }

    func testIgnoresSlowAndWrongCourseCrossings() {
        var timer = LapTimer(line: FinishLine(centre: origin, heading: 0), startedAt: t0)
        let start = t0.addingTimeInterval(20)
        timer.add(at: start, point: at(0, -10))
        // Crawling across (GPS wobble while parked), and heading the wrong way by the course.
        timer.add(at: start.addingTimeInterval(1), point: at(0, 2), kmh: 5)
        timer.add(at: start.addingTimeInterval(2), point: at(0, -10), kmh: 40, course: 180)
        timer.add(at: start.addingTimeInterval(3), point: at(0, 2), kmh: 40, course: 180)
        XCTAssertTrue(timer.laps.isEmpty)
        XCTAssertEqual(timer.lapStart, t0)
        timer.add(at: start.addingTimeInterval(4), point: at(0, -10), kmh: 40, course: 0)
        timer.add(at: start.addingTimeInterval(5), point: at(0, 2), kmh: 40, course: 0)
        XCTAssertEqual(timer.laps.count, 1)
    }

    func testLapsRoundTripAndOldLapsDecode() throws {
        let laps = try JSONDecoder().decode([Lap].self, from: Data(#"[{"number":1,"seconds":61.2}]"#.utf8))
        XCTAssertEqual(laps.first?.seconds, 61.2)
        XCTAssertEqual(laps.first?.metres, 0)
    }
}
