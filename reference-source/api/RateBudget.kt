package app.elroq.precondition.api

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import java.time.Clock
import java.time.Instant
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours

enum class RequestKind { AUTOMATION, MANUAL }

data class BudgetConfig(
    /** Used until the API has told us its limit via RateLimit-Limit. */
    val fallbackLimit: Int = 20,
    /** Requests per window that automation may never touch. */
    val manualReserve: Int = 4,
    val window: Duration = 1.hours,
)

@Serializable
data class SentRequest(val id: Long, val atEpochMs: Long, val kind: RequestKind, val completed: Boolean = false)

@Serializable
data class RateBudgetState(
    val limit: Int? = null,
    val remaining: Int? = null,
    val resetAtEpochMs: Long? = null,
    val observedAtEpochMs: Long? = null,
    val exhaustedUntilEpochMs: Long? = null,
    val sent: List<SentRequest> = emptyList(),
    val nextId: Long = 1,
)

interface RateBudgetStore {
    suspend fun load(): RateBudgetState
    suspend fun save(state: RateBudgetState)
}

data class BudgetSnapshot(
    val limit: Int,
    val remaining: Int,
    val automationAvailable: Int,
    val manualAvailable: Int,
    val automationUsedInWindow: Int,
    val manualReserve: Int,
    val resetAt: Instant?,
    val exhaustedUntil: Instant?,
    /** True when the numbers come from API headers rather than local counting. */
    val fromServer: Boolean,
)

/** Proof that a request slot was taken; hand it back to [RateBudget.complete]. */
data class BudgetTicket(val id: Long, val kind: RequestKind)

/**
 * Tracks the per-VIN rate limit and keeps [BudgetConfig.manualReserve] requests for manual commands.
 *
 * Remaining requests come from the last RateLimit-* headers when they are still current, minus
 * requests sent since; otherwise from local counting over the window. Automation is capped twice:
 * it must leave the reserve untouched, and it may never use more than `limit − reserve` in a window.
 */
class RateBudget(
    private val store: RateBudgetStore,
    private val clock: Clock,
    private val config: suspend () -> BudgetConfig,
) {
    private val mutex = Mutex()

    suspend fun snapshot(): BudgetSnapshot = mutex.withLock { compute(store.load(), config(), clock.instant()) }

    suspend fun available(kind: RequestKind): Int = snapshot().let {
        if (kind == RequestKind.AUTOMATION) it.automationAvailable else it.manualAvailable
    }

    /** Takes one request slot, or returns null if the budget has none left for [kind]. */
    suspend fun tryAcquire(kind: RequestKind): BudgetTicket? = mutex.withLock {
        val now = clock.instant()
        val state = store.load()
        val snap = compute(state, config(), now)
        val available = if (kind == RequestKind.AUTOMATION) snap.automationAvailable else snap.manualAvailable
        if (available < 1) return null
        val id = state.nextId
        val sent = state.sent + SentRequest(id, now.toEpochMilli(), kind)
        store.save(prune(state.copy(sent = sent, nextId = id + 1), now, config()))
        BudgetTicket(id, kind)
    }

    /**
     * Records the outcome of a request.
     * @param meta null when no response arrived (network failure); the request still counts.
     * @param error the mapped error, if the request failed.
     */
    suspend fun complete(ticket: BudgetTicket, meta: ResponseMeta?, error: ApiError? = null) = mutex.withLock {
        val now = clock.instant()
        var state = store.load()
        val cfg = config()

        // 401/403 do not count against the limit.
        state = if (meta != null && (meta.httpCode == 401 || meta.httpCode == 403)) {
            state.copy(sent = state.sent.filterNot { it.id == ticket.id })
        } else {
            state.copy(sent = state.sent.map { if (it.id == ticket.id) it.copy(completed = true) else it })
        }

        if (meta != null && (meta.rateRemaining != null || meta.rateLimit != null || meta.rateResetAt != null)) {
            state = state.copy(
                limit = meta.rateLimit ?: state.limit,
                remaining = meta.rateRemaining ?: state.remaining,
                resetAtEpochMs = meta.rateResetAt?.toEpochMilli() ?: state.resetAtEpochMs,
                observedAtEpochMs = meta.receivedAt.toEpochMilli(),
            )
        }

        if (error is ApiError.RateLimited) {
            val candidates = listOfNotNull(
                meta?.retryAfter?.let { now.plusMillis(it.inWholeMilliseconds) },
                meta?.rateResetAt,
                state.resetAtEpochMs?.let(Instant::ofEpochMilli)?.takeIf { it.isAfter(now) },
            )
            val until = candidates.maxOrNull() ?: now.plusMillis(cfg.window.inWholeMilliseconds)
            state = state.copy(exhaustedUntilEpochMs = until.toEpochMilli(), remaining = 0, observedAtEpochMs = now.toEpochMilli())
        }

        store.save(prune(state, now, cfg))
    }

    /** Two windows of history is enough to count the current one. */
    private fun prune(state: RateBudgetState, now: Instant, cfg: BudgetConfig): RateBudgetState {
        val keepAfter = now.toEpochMilli() - 2 * cfg.window.inWholeMilliseconds
        return state.copy(sent = state.sent.filter { it.atEpochMs >= keepAfter })
    }

    companion object {
        fun compute(state: RateBudgetState, cfg: BudgetConfig, now: Instant): BudgetSnapshot {
            val limit = state.limit ?: cfg.fallbackLimit
            val nowMs = now.toEpochMilli()
            val windowMs = cfg.window.inWholeMilliseconds
            val resetAt = state.resetAtEpochMs
            val serverCurrent = resetAt != null && nowMs < resetAt && state.remaining != null && state.observedAtEpochMs != null

            // Start of the window the server is counting, or a rolling window when we don't know it.
            val windowStart = when {
                resetAt != null && nowMs < resetAt -> resetAt - windowMs
                resetAt != null && nowMs < resetAt + windowMs -> resetAt
                else -> nowMs - windowMs
            }
            val inWindow = state.sent.filter { it.atEpochMs >= windowStart }

            val remaining = if (serverCurrent) {
                val notYetReflected = state.sent.count { !it.completed || it.atEpochMs > state.observedAtEpochMs!! }
                state.remaining!! - notYetReflected
            } else {
                limit - inWindow.size
            }

            val exhaustedUntil = state.exhaustedUntilEpochMs?.takeIf { it > nowMs }
            val automationUsed = inWindow.count { it.kind == RequestKind.AUTOMATION }
            val manual = if (exhaustedUntil != null) 0 else remaining.coerceAtLeast(0)
            val automation = if (exhaustedUntil != null) 0 else minOf(
                remaining - cfg.manualReserve,
                limit - cfg.manualReserve - automationUsed,
            ).coerceAtLeast(0)

            val shownReset = when {
                resetAt != null && nowMs < resetAt -> Instant.ofEpochMilli(resetAt)
                else -> inWindow.minOfOrNull { it.atEpochMs }?.let { Instant.ofEpochMilli(it + windowMs) }
            }
            return BudgetSnapshot(
                limit = limit,
                remaining = remaining.coerceAtLeast(0),
                automationAvailable = automation,
                manualAvailable = manual,
                automationUsedInWindow = automationUsed,
                manualReserve = cfg.manualReserve,
                resetAt = shownReset,
                exhaustedUntil = exhaustedUntil?.let(Instant::ofEpochMilli),
                fromServer = serverCurrent,
            )
        }
    }
}
