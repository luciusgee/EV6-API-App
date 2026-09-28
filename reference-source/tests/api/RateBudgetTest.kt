package app.elroq.precondition.api

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import kotlin.time.Duration.Companion.seconds

class RateBudgetTest {
    private val clock = MutableClock()
    private val store = MemoryBudgetStore()
    private var config = BudgetConfig()
    private val budget = RateBudget(store, clock) { config }

    private fun meta(code: Int = 200, remaining: Int? = null, resetIn: Long? = null, limit: Int? = 20, retryAfter: Long? = null) =
        ResponseMeta(
            httpCode = code,
            receivedAt = clock.instant(),
            rateLimit = limit.takeIf { remaining != null || resetIn != null },
            rateRemaining = remaining,
            rateResetAt = resetIn?.let { clock.instant().plusSeconds(it) },
            retryAfter = retryAfter?.seconds,
        )

    /** Spend one request that the server reports back with [remaining]. */
    private suspend fun spend(kind: RequestKind, remaining: Int? = null, resetIn: Long? = null, code: Int = 200): Boolean {
        val ticket = budget.tryAcquire(kind) ?: return false
        budget.complete(ticket, meta(code, remaining, resetIn))
        return true
    }

    @Test
    fun `fresh budget keeps four for manual commands`() = runTest {
        val snap = budget.snapshot()
        assertEquals(20, snap.limit)
        assertEquals(20, snap.remaining)
        assertEquals(16, snap.automationAvailable)
        assertEquals(20, snap.manualAvailable)
        assertFalse(snap.fromServer)
    }

    @Test
    fun `automation never uses more than limit minus four in a window`() = runTest {
        var automated = 0
        repeat(30) { if (spend(RequestKind.AUTOMATION)) automated++ }
        assertEquals(16, automated)
        assertEquals(0, budget.available(RequestKind.AUTOMATION))
        // The reserve is still there for the user.
        repeat(4) { assertTrue(spend(RequestKind.MANUAL)) }
        assertFalse(spend(RequestKind.MANUAL))
    }

    @Test
    fun `the cap holds with server headers too`() = runTest {
        var remaining = 20
        var automated = 0
        repeat(30) {
            if (spend(RequestKind.AUTOMATION, remaining = remaining - 1, resetIn = 3000)) {
                remaining--
                automated++
            }
        }
        assertEquals(16, automated)
        assertTrue(budget.snapshot().fromServer)
    }

    @Test
    fun `manual use eats into what automation may use`() = runTest {
        repeat(10) { spend(RequestKind.MANUAL) }
        assertEquals(10, budget.snapshot().remaining)
        assertEquals(6, budget.available(RequestKind.AUTOMATION))
    }

    @Test
    fun `server remaining wins over local counting`() = runTest {
        spend(RequestKind.AUTOMATION, remaining = 5, resetIn = 600)
        val snap = budget.snapshot()
        assertEquals(5, snap.remaining)
        assertEquals(1, snap.automationAvailable)
        assertEquals(clock.instant().plusSeconds(600), snap.resetAt)
    }

    @Test
    fun `requests sent after the last headers are subtracted`() = runTest {
        spend(RequestKind.AUTOMATION, remaining = 10, resetIn = 600)
        clock.advanceSeconds(5)
        val pending = budget.tryAcquire(RequestKind.AUTOMATION)!!
        assertEquals(9, budget.snapshot().remaining)
        clock.advanceSeconds(1)
        budget.complete(pending, null) // network failure: still counts
        assertEquals(9, budget.snapshot().remaining)
    }

    @Test
    fun `window resets after the reset time`() = runTest {
        repeat(16) { spend(RequestKind.AUTOMATION, remaining = 19 - it, resetIn = 1800 - it.toLong()) }
        assertEquals(0, budget.available(RequestKind.AUTOMATION))
        clock.advanceSeconds(1801)
        val snap = budget.snapshot()
        assertEquals(20, snap.remaining)
        assertEquals(16, snap.automationAvailable)
    }

    @Test
    fun `rolling window without headers`() = runTest {
        repeat(16) { spend(RequestKind.AUTOMATION) }
        assertEquals(0, budget.available(RequestKind.AUTOMATION))
        clock.advanceSeconds(3601)
        assertEquals(16, budget.available(RequestKind.AUTOMATION))
        assertNull(budget.snapshot().resetAt)
    }

    @Test
    fun `401 and 403 do not count`() = runTest {
        repeat(5) { spend(RequestKind.AUTOMATION, code = 401) }
        repeat(5) { spend(RequestKind.AUTOMATION, code = 403) }
        assertEquals(20, budget.snapshot().remaining)
    }

    @Test
    fun `5xx responses count`() = runTest {
        repeat(3) { spend(RequestKind.AUTOMATION, code = 503) }
        assertEquals(17, budget.snapshot().remaining)
    }

    @Test
    fun `429 marks the budget exhausted until reset`() = runTest {
        val ticket = budget.tryAcquire(RequestKind.AUTOMATION)!!
        val m = meta(429, remaining = 0, resetIn = 900).copy(retryAfter = 300.seconds)
        budget.complete(ticket, m, ApiError.RateLimited(300.seconds))
        val snap = budget.snapshot()
        assertEquals(0, snap.manualAvailable)
        assertEquals(0, snap.automationAvailable)
        assertEquals(clock.instant().plusSeconds(900), snap.exhaustedUntil)
        assertNull(budget.tryAcquire(RequestKind.MANUAL))
        clock.advanceSeconds(901)
        assertEquals(20, budget.snapshot().manualAvailable)
    }

    @Test
    fun `429 without headers waits a full window`() = runTest {
        val ticket = budget.tryAcquire(RequestKind.MANUAL)!!
        budget.complete(ticket, ResponseMeta(429, clock.instant()), ApiError.RateLimited(null))
        assertEquals(clock.instant().plusSeconds(3600), budget.snapshot().exhaustedUntil)
    }

    @Test
    fun `vehicle busy 429 does not exhaust the budget`() = runTest {
        val ticket = budget.tryAcquire(RequestKind.AUTOMATION)!!
        budget.complete(ticket, ResponseMeta(429, clock.instant()), ApiError.VehicleNotAcceptingRequests(null))
        assertNull(budget.snapshot().exhaustedUntil)
        assertEquals(19, budget.snapshot().remaining)
    }

    @Test
    fun `limit comes from headers and the fallback is configurable`() = runTest {
        config = BudgetConfig(fallbackLimit = 10, manualReserve = 2)
        assertEquals(8, budget.available(RequestKind.AUTOMATION))
        spend(RequestKind.AUTOMATION, remaining = 29, resetIn = 3000)
        store.state = store.state.copy(limit = 30)
        val snap = budget.snapshot()
        assertEquals(30, snap.limit)
        assertEquals(27, snap.automationAvailable)
    }

    @Test
    fun `old history is pruned`() = runTest {
        spend(RequestKind.AUTOMATION)
        clock.advanceSeconds(3 * 3600)
        spend(RequestKind.AUTOMATION)
        assertEquals(1, store.state.sent.size)
        assertNotNull(budget.snapshot().resetAt)
    }

    @Test
    fun `ticket ids are unique`() = runTest {
        val a = budget.tryAcquire(RequestKind.AUTOMATION)!!
        val b = budget.tryAcquire(RequestKind.AUTOMATION)!!
        assertTrue(a.id != b.id)
        budget.complete(a, meta(401))
        assertEquals(listOf(b.id), store.state.sent.map { it.id })
    }

    @Test
    fun `compute is pure`() {
        val state = RateBudgetState(
            limit = 20, remaining = 3, resetAtEpochMs = Instant.parse("2026-09-23T15:30:00Z").toEpochMilli(),
            observedAtEpochMs = Instant.parse("2026-09-23T14:59:00Z").toEpochMilli(),
        )
        val snap = RateBudget.compute(state, BudgetConfig(), clock.instant())
        assertEquals(3, snap.manualAvailable)
        assertEquals(0, snap.automationAvailable)
    }
}
