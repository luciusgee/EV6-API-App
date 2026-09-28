package app.elroq.precondition.engine

import app.elroq.precondition.api.ApiError
import app.elroq.precondition.api.ApiResult
import app.elroq.precondition.api.CredentialsProvider
import app.elroq.precondition.api.RequestKind
import app.elroq.precondition.api.VehicleApi
import app.elroq.precondition.api.redactVin
import app.elroq.precondition.rules.VehicleSnapshot
import java.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes

/** True when the call reached (or may have reached) the network, i.e. it cost a request. */
val ApiResult<*>.madeRequest: Boolean
    get() = meta != null || (this is ApiResult.Failure && error is ApiError.Network)

/**
 * Vehicle state with a 10-minute cache. Rules read the cache unless it is stale; nothing polls.
 */
class VehicleRepository(
    private val client: VehicleApi,
    private val cache: VehicleCacheStore,
    private val state: AutomationStateStore,
    private val credentials: CredentialsProvider,
    private val log: EventLog,
    private val clock: Clock,
    val ttl: Duration = 10.minutes,
) {
    /** Last known state of any age, for display. */
    suspend fun cached(): VehicleSnapshot? = cache.load()

    /** Cached state if younger than [ttl]. */
    suspend fun fresh(): VehicleSnapshot? = cache.load()?.takeIf {
        clock.millis() - it.fetchedAtEpochMs < ttl.inWholeMilliseconds
    }

    suspend fun fetch(kind: RequestKind): ApiResult<VehicleSnapshot> {
        return when (val result = client.getVehicle(kind)) {
            is ApiResult.Failure -> result
            is ApiResult.Success -> {
                val snapshot = result.value.snapshot
                cache.save(snapshot)
                dumpFirstResponse(result.value.rawJson, result.meta.httpCode)
                ApiResult.Success(snapshot, result.meta)
            }
        }
    }

    /**
     * Milestone 1 asks for the full response in the log once, to answer the open questions
     * (outside temperature field, parking position availability). The VIN is masked.
     */
    private suspend fun dumpFirstResponse(raw: String, httpCode: Int) {
        if (state.load().firstVehicleDumpDone) return
        val vin = credentials.credentials()?.vin
        log.append(
            LogEntry(
                at = clock.instant(),
                kind = LogKind.INFO,
                decision = "first vehicle response",
                reason = "Full vehicle response recorded for checking available fields",
                httpCode = httpCode,
                details = redactVin(raw, vin),
            ),
        )
        state.update { it.copy(firstVehicleDumpDone = true) }
    }
}
