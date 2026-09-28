package app.elroq.precondition.rules

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.LocalDate
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes

enum class ClimateState { OFF, RUNNING, UNKNOWN }

/**
 * Vehicle state as the rules see it. Every field is nullable: null means the API did not return it
 * (partial 200, missing licence, unsupported), which rules treat as unknown, never as a failure.
 */
@Serializable
data class VehicleSnapshot(
    val socPercent: Int? = null,
    val rangeKm: Int? = null,
    val pluggedIn: Boolean? = null,
    val chargePowerKw: Double? = null,
    val minutesToFullyCharged: Int? = null,
    val climate: ClimateState = ClimateState.UNKNOWN,
    /** Raw air-conditioning state string from the API, for display and logs. */
    val climateRawState: String? = null,
    val targetTempC: Double? = null,
    /** When the car expects to reach the target temperature, if climatising. */
    val targetReachedAtEpochMs: Long? = null,
    val climateWithoutExternalPower: Boolean? = null,
    val chargingState: String? = null,
    val outsideTempC: Double? = null,
    val parkingPosition: LatLon? = null,
    /** True when the API says PARKED, false when IN_MOTION, null when not reported. */
    val parked: Boolean? = null,
    val carCapturedAtEpochMs: Long? = null,
    val fetchedAtEpochMs: Long,
    /** Sections the API reported in its `errors` list, e.g. "PARKING_POSITION_UNSUPPORTED". */
    val unavailable: List<String> = emptyList(),
) {
    val fetchedAt: Instant get() = Instant.ofEpochMilli(fetchedAtEpochMs)
}

data class TempReading(val celsius: Double, val source: String, val at: Instant)

/**
 * Everything the evaluator may need beyond the rule itself. Implementations fetch lazily and memoise
 * within one evaluation, so asking twice never costs two requests.
 */
interface EvaluationInputs {
    /** Vehicle state already in hand (fresh cache or fetched earlier in this evaluation). Never costs a request. */
    fun vehicleIfFree(): VehicleSnapshot?

    /** Vehicle state, reading the Škoda API if the cache is stale. Null if unavailable. */
    suspend fun vehicle(): VehicleSnapshot?

    suspend fun weatherNow(at: LatLon): TempReading?

    suspend fun forecastAt(at: LatLon, time: Instant): TempReading?

    suspend fun cabinTemp(): TempReading?

    /** The phone's current location, or null without permission or a fix. Costs no Škoda request. */
    suspend fun phoneLocation(): LatLon?
}

/** How many Škoda requests automation may still make in the current rate window. */
fun interface BudgetView {
    suspend fun automationAvailable(): Int
}

data class GuardSettings(
    val minSocPercent: Int = 25,
    val globalCooldown: Duration = 15.minutes,
    val automationPaused: Boolean = false,
    val holidays: Set<LocalDate> = emptySet(),
)

data class CooldownState(
    val lastAutomatedCommandAt: Instant? = null,
    val lastFiredByRule: Map<String, Instant> = emptyMap(),
)
