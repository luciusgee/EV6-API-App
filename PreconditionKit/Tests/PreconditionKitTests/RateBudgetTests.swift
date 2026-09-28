import Foundation
import XCTest
@testable import PreconditionKit

/// Port of the Android `RateBudgetTest`, minus the Škoda rate-header cases (Kia sends none).
final class RateBudgetTests: XCTestCase {
    let time = MutableTime()
    let store = InMemoryRateBudgetStore()
    let config = Locked(BudgetConfig(limit: 20, manualReserve: 4, window: 3600))
    lazy var budget: RateBudget = {
        let config = self.config
        return RateBudget(store: store, time: time, config: { config.current })
    }()

    @discardableResult
    private func spend(_ kind: RequestKind, code: Int = 200) async -> Bool {
        guard let ticket = await budget.tryAcquire(kind) else { return false }
        await budget.complete(ticket, meta: ResponseMeta(httpCode: code, receivedAt: time.now()))
        return true
    }

    func testTheKiaDefaultsKeepEightOfEightyForManualCommands() async {
        let snap = RateBudget.compute(RateBudgetState(), .kia, t0)
        XCTAssertEqual(snap.limit, 80)
        XCTAssertEqual(snap.remaining, 80)
        XCTAssertEqual(snap.automationAvailable, 72)
        XCTAssertEqual(snap.manualAvailable, 80)
        XCTAssertEqual(snap.manualReserve, 8)
        XCTAssertNil(snap.resetAt)
    }

    func testAutomationNeverUsesMoreThanLimitMinusReserveInAWindow() async {
        var automated = 0
        for _ in 0..<30 where await spend(.automation) { automated += 1 }
        XCTAssertEqual(automated, 16)
        let available = await budget.available(.automation)
        XCTAssertEqual(available, 0)
        // The reserve is still there for the user.
        for _ in 0..<4 {
            let spent = await spend(.manual)
            XCTAssertTrue(spent)
        }
        let more = await spend(.manual)
        XCTAssertFalse(more)
    }

    func testManualUseEatsIntoWhatAutomationMayUse() async {
        for _ in 0..<10 { await spend(.manual) }
        let snap = await budget.snapshot()
        XCTAssertEqual(snap.remaining, 10)
        XCTAssertEqual(snap.automationAvailable, 6)
    }

    func testANetworkFailureStillCounts() async {
        let ticket = await budget.tryAcquire(.automation)!
        let pending = await budget.snapshot().remaining
        XCTAssertEqual(pending, 19)
        await budget.complete(ticket, meta: nil)
        let after = await budget.snapshot().remaining
        XCTAssertEqual(after, 19)
    }

    func testRollingWindow() async {
        for _ in 0..<16 { await spend(.automation) }
        var available = await budget.available(.automation)
        XCTAssertEqual(available, 0)
        let resetAt = await budget.snapshot().resetAt
        XCTAssertEqual(resetAt, t0.addingTimeInterval(3600))
        time.advance(3601)
        available = await budget.available(.automation)
        XCTAssertEqual(available, 16)
        let snap = await budget.snapshot()
        XCTAssertNil(snap.resetAt)
    }

    func testRejectedLoginsDoNotCount() async {
        for _ in 0..<5 { await spend(.automation, code: 401) }
        for _ in 0..<5 { await spend(.automation, code: 403) }
        let remaining = await budget.snapshot().remaining
        XCTAssertEqual(remaining, 20)
    }

    func testServerErrorsCount() async {
        for _ in 0..<3 { await spend(.automation, code: 503) }
        let remaining = await budget.snapshot().remaining
        XCTAssertEqual(remaining, 17)
    }

    func testRateLimitedBlocksEverythingUntilRetryAfter() async {
        let ticket = await budget.tryAcquire(.automation)!
        await budget.complete(ticket, meta: ResponseMeta(httpCode: 429, receivedAt: time.now(), retryAfter: 3600), error: .rateLimited(retryAfter: 3600))
        var snap = await budget.snapshot()
        XCTAssertEqual(snap.manualAvailable, 0)
        XCTAssertEqual(snap.automationAvailable, 0)
        XCTAssertEqual(snap.exhaustedUntil, t0.addingTimeInterval(3600))
        let manual = await budget.tryAcquire(.manual)
        XCTAssertNil(manual)
        time.advance(3601)
        snap = await budget.snapshot()
        XCTAssertEqual(snap.manualAvailable, 20)
        XCTAssertNil(snap.exhaustedUntil)
    }

    func testRateLimitedWithoutRetryAfterWaitsAFullWindow() async {
        let ticket = await budget.tryAcquire(.manual)!
        await budget.complete(ticket, meta: ResponseMeta(httpCode: 429, receivedAt: time.now()), error: .rateLimited(retryAfter: nil))
        let until = await budget.snapshot().exhaustedUntil
        XCTAssertEqual(until, t0.addingTimeInterval(3600))
    }

    func testABusyCarDoesNotExhaustTheBudget() async {
        let ticket = await budget.tryAcquire(.automation)!
        await budget.complete(ticket, meta: ResponseMeta(httpCode: 400, receivedAt: time.now()), error: .vehicleNotAcceptingRequests(retryAfter: 120))
        let snap = await budget.snapshot()
        XCTAssertNil(snap.exhaustedUntil)
        XCTAssertEqual(snap.remaining, 19)
    }

    func testConfigChangesApplyAtOnce() async {
        config.withLock { $0 = BudgetConfig(limit: 10, manualReserve: 2, window: 3600) }
        let available = await budget.available(.automation)
        XCTAssertEqual(available, 8)
    }

    func testOldHistoryIsPruned() async {
        await spend(.automation)
        time.advance(3 * 3600)
        await spend(.automation)
        let sent = await store.state.sent
        XCTAssertEqual(sent.count, 1)
        let resetAt = await budget.snapshot().resetAt
        XCTAssertNotNil(resetAt)
    }

    func testTicketIdsAreUnique() async {
        let a = await budget.tryAcquire(.automation)!
        let b = await budget.tryAcquire(.automation)!
        XCTAssertNotEqual(a.id, b.id)
        await budget.complete(a, meta: ResponseMeta(httpCode: 401, receivedAt: time.now()))
        let ids = await store.state.sent.map(\.id)
        XCTAssertEqual(ids, [b.id])
    }

    func testConcurrentAcquiresNeverOverspend() async {
        let budget = self.budget
        let granted = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<50 { group.addTask { await budget.tryAcquire(.automation) != nil } }
            var count = 0
            for await ok in group where ok { count += 1 }
            return count
        }
        XCTAssertEqual(granted, 16)
    }

    func testStateSurvivesACodableRoundTrip() async throws {
        await spend(.manual)
        let state = await store.state
        let copy = try JSONDecoder().decode(RateBudgetState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(copy, state)
    }
}
