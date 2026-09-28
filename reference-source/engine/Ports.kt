package app.elroq.precondition.engine

import app.elroq.precondition.rules.CooldownState
import app.elroq.precondition.rules.GuardSettings
import app.elroq.precondition.rules.LatLon
import app.elroq.precondition.rules.Place
import app.elroq.precondition.rules.Rule
import app.elroq.precondition.rules.TempReading
import app.elroq.precondition.rules.VehicleSnapshot
import kotlinx.serialization.Serializable
import java.time.Instant

/*
 * Interfaces the engine needs from the Android side (Room, DataStore, notifications, BLE).
 * Keeping them here lets the whole decision path run in plain JVM unit tests.
 */

interface RuleStore {
    suspend fun rules(): List<Rule>
    suspend fun disableRule(id: String, reason: String)
}

interface PlaceStore {
    suspend fun places(): List<Place>
}

interface SettingsSource {
    suspend fun guards(): GuardSettings
    suspend fun defaultTargetC(): Double
    /** Allow climatisation on battery power when the car is not plugged in. */
    suspend fun climateWithoutExternalPower(): Boolean
}

fun interface PhoneLocator {
    /** Current phone location, or null without permission or a recent fix. */
    suspend fun locate(): LatLon?
}

fun interface CabinSensor {
    /** Current cabin temperature, or null when the sensor is out of range or not paired. */
    suspend fun read(): TempReading?
}

interface VehicleCacheStore {
    suspend fun load(): VehicleSnapshot?
    suspend fun save(snapshot: VehicleSnapshot)
}

@Serializable
data class LastCommand(val atEpochMs: Long, val description: String, val automated: Boolean)

@Serializable
data class AutomationState(
    val lastAutomatedCommandAtMs: Long? = null,
    val lastFiredByRuleMs: Map<String, Long> = emptyMap(),
    /** Per trigger dedup key, when that geofence event was last handled. */
    val lastTriggerAtMs: Map<String, Long> = emptyMap(),
    val consecutiveFailures: Int = 0,
    val pausedAfterFailures: Boolean = false,
    /** Set on 401/403; automation stays stopped until the key is replaced or a request succeeds. */
    val authFailure: String? = null,
    val apiKeyExpiresAtMs: Long? = null,
    val keyExpiryWarnedForMs: Long? = null,
    val firstVehicleDumpDone: Boolean = false,
    val lastCommand: LastCommand? = null,
) {
    fun cooldowns() = CooldownState(
        lastAutomatedCommandAt = lastAutomatedCommandAtMs?.let(Instant::ofEpochMilli),
        lastFiredByRule = lastFiredByRuleMs.mapValues { Instant.ofEpochMilli(it.value) },
    )

    val automationBlockedReason: String?
        get() = when {
            authFailure != null -> "automation stopped: $authFailure"
            pausedAfterFailures -> "automation paused after $consecutiveFailures consecutive failures"
            else -> null
        }
}

interface AutomationStateStore {
    suspend fun load(): AutomationState
    suspend fun update(transform: (AutomationState) -> AutomationState): AutomationState
}

enum class LogKind { FIRED, SKIPPED, COMMAND, MANUAL, DRY_RUN, ERROR, INFO }

data class LogEntry(
    val at: Instant,
    val kind: LogKind,
    /** Short outcome, e.g. "fired", "skipped", "sent", "failed". */
    val decision: String,
    val reason: String,
    val trigger: String? = null,
    val ruleId: String? = null,
    val ruleName: String? = null,
    val httpCode: Int? = null,
    val requestsUsed: Int = 0,
    val details: String? = null,
)

fun interface EventLog {
    suspend fun append(entry: LogEntry)
}

interface Notifier {
    /** A climatisation command was accepted. [canStop] adds a Stop action. */
    suspend fun commandSent(title: String, text: String, canStop: Boolean)

    suspend fun problem(title: String, text: String, openSettings: Boolean = false)
}
