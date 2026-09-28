package app.elroq.precondition.rules

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.DayOfWeek
import java.time.LocalTime

/**
 * A rule is one trigger, a set of AND-ed conditions, one action, and a cooldown.
 * Global guards (SoC, already running, cooldowns, rate budget, pause) are applied on top by
 * [RuleEvaluator]; they are not part of the rule itself.
 */
@Serializable
data class Rule(
    val id: String,
    val name: String,
    val enabled: Boolean = true,
    /** Higher runs first. Ties are broken by name, then id, so ordering is deterministic. */
    val priority: Int = 0,
    val trigger: Trigger,
    val conditions: List<Condition> = emptyList(),
    val action: Action,
    val cooldownMinutes: Int = DEFAULT_COOLDOWN_MINUTES,
    /** When true, a condition whose input is unknown counts as passed instead of failed. Guards never do. */
    val proceedIfUnknown: Boolean = false,
) {
    companion object {
        const val DEFAULT_COOLDOWN_MINUTES = 60
    }
}

@Serializable
sealed interface Trigger {
    @Serializable
    @SerialName("geofenceExit")
    data class GeofenceExit(val placeId: String) : Trigger

    @Serializable
    @SerialName("geofenceEnter")
    data class GeofenceEnter(val placeId: String) : Trigger

    /** Phone comes within [km] of the place. Implemented as an outer geofence, not continuous tracking. */
    @Serializable
    @SerialName("approaching")
    data class Approaching(val placeId: String, val km: Double) : Trigger

    @Serializable
    @SerialName("schedule")
    data class Schedule(
        val days: Set<@Serializable(DayOfWeekSerializer::class) DayOfWeek>,
        @Serializable(LocalTimeSerializer::class) val time: LocalTime,
    ) : Trigger

    /**
     * Phone comes within [meters] of where the car is parked. Implemented as a geofence around the
     * car's last reported parking position, refreshed every few hours.
     */
    @Serializable
    @SerialName("nearCar")
    data class NearCar(val meters: Int) : Trigger
}

@Serializable
sealed interface Condition {
    /** Inclusive start, exclusive end. If start is after end the window wraps past midnight. */
    @Serializable
    @SerialName("timeWindow")
    data class TimeWindow(
        @Serializable(LocalTimeSerializer::class) val start: LocalTime,
        @Serializable(LocalTimeSerializer::class) val end: LocalTime,
    ) : Condition

    @Serializable
    @SerialName("daysOfWeek")
    data class DaysOfWeek(val days: Set<@Serializable(DayOfWeekSerializer::class) DayOfWeek>) : Condition

    @Serializable
    @SerialName("tempBelow")
    data class TempBelow(val celsius: Double, val source: TempSource) : Condition

    @Serializable
    @SerialName("tempAbove")
    data class TempAbove(val celsius: Double, val source: TempSource) : Condition

    /** Below [low] or above [high]: "heat when cold, cool when hot" in one rule. */
    @Serializable
    @SerialName("tempOutside")
    data class TempOutside(val low: Double, val high: Double, val source: TempSource) : Condition

    @Serializable
    @SerialName("socAtLeast")
    data class SocAtLeast(val percent: Int) : Condition

    @Serializable
    @SerialName("pluggedIn")
    data class PluggedIn(val expected: Boolean) : Condition

    @Serializable
    @SerialName("carAtPlace")
    data class CarAtPlace(val placeId: String) : Condition

    /**
     * The phone is within [meters] of where the car is parked, checked when the rule is evaluated.
     * Stops a rule firing when you are somewhere else (on holiday, or left the car at work).
     */
    @Serializable
    @SerialName("phoneNearCar")
    data class PhoneNearCar(val meters: Int) : Condition
}

@Serializable
sealed interface TempSource {
    /** Outside-temperature field reported by the car, if the API returns one. */
    @Serializable
    @SerialName("carOutside")
    data object CarOutside : TempSource

    /** Open-Meteo current temperature at the car's position (or the place's usual parking spot). */
    @Serializable
    @SerialName("weatherAtCar")
    data object WeatherAtCar : TempSource

    /** Open-Meteo hourly forecast at the car's position for the next occurrence of [time]. */
    @Serializable
    @SerialName("forecastAt")
    data class ForecastAt(@Serializable(LocalTimeSerializer::class) val time: LocalTime) : TempSource

    /** Optional BLE thermometer in the cabin; unknown unless the phone is in range. */
    @Serializable
    @SerialName("cabinBle")
    data object CabinBle : TempSource

    /** Car outside temperature if reported, otherwise weather at the car. Cabin is never used. */
    @Serializable
    @SerialName("bestAvailable")
    data object BestAvailable : TempSource
}

@Serializable
sealed interface Action {
    @Serializable
    @SerialName("startClimate")
    data class StartClimate(val targetC: Double) : Action

    @Serializable
    @SerialName("stopClimate")
    data object StopClimate : Action
}

@Serializable
data class LatLon(val lat: Double, val lon: Double) {
    /** Great-circle distance in metres. */
    fun distanceTo(other: LatLon): Double {
        val r = 6_371_000.0
        val dLat = Math.toRadians(other.lat - lat)
        val dLon = Math.toRadians(other.lon - lon)
        val a = Math.sin(dLat / 2).let { it * it } +
            Math.cos(Math.toRadians(lat)) * Math.cos(Math.toRadians(other.lat)) *
            Math.sin(dLon / 2).let { it * it }
        return 2 * r * Math.asin(Math.sqrt(a.coerceIn(0.0, 1.0)))
    }
}

@Serializable
data class Place(
    val id: String,
    val name: String,
    val centre: LatLon,
    val radiusM: Int,
    /** Where the car is usually parked for this place; used for weather when the car's position is unknown. */
    val usualParkingSpot: LatLon? = null,
) {
    fun contains(point: LatLon): Boolean = centre.distanceTo(point) <= radiusM

    /** Best guess at where the car is when it is "at" this place. */
    val parkingSpotOrCentre: LatLon get() = usualParkingSpot ?: centre

    companion object {
        const val MIN_RADIUS_M = 100
        const val MAX_RADIUS_M = 2000
    }
}

/** What actually happened on the phone. Rules are matched against it with [Trigger.matches]. */
@Serializable
sealed interface TriggerEvent {
    @Serializable
    @SerialName("exited")
    data class GeofenceExited(val placeId: String) : TriggerEvent

    @Serializable
    @SerialName("entered")
    data class GeofenceEntered(val placeId: String) : TriggerEvent

    @Serializable
    @SerialName("approached")
    data class Approached(val placeId: String, val km: Double) : TriggerEvent

    @Serializable
    @SerialName("schedule")
    data class ScheduleFired(@Serializable(LocalTimeSerializer::class) val time: LocalTime) : TriggerEvent

    @Serializable
    @SerialName("approachedCar")
    data class ApproachedCar(val meters: Int) : TriggerEvent

    /** Key used to ignore a repeated geofence event within the dedup window. Null means never deduplicated. */
    val dedupKey: String?
        get() = when (this) {
            is GeofenceExited -> "exit:$placeId"
            is GeofenceEntered -> "enter:$placeId"
            is Approached -> "approach:$placeId:$km"
            is ApproachedCar -> "car:$meters"
            is ScheduleFired -> null
        }
}

fun Trigger.matches(event: TriggerEvent, today: DayOfWeek): Boolean = when (this) {
    is Trigger.GeofenceExit -> event is TriggerEvent.GeofenceExited && event.placeId == placeId
    is Trigger.GeofenceEnter -> event is TriggerEvent.GeofenceEntered && event.placeId == placeId
    is Trigger.Approaching -> event is TriggerEvent.Approached && event.placeId == placeId && event.km == km
    is Trigger.Schedule -> event is TriggerEvent.ScheduleFired && event.time == time && today in days
    is Trigger.NearCar -> event is TriggerEvent.ApproachedCar && event.meters == meters
}

/** The event a trigger would produce; used by "test now" dry runs. */
fun Trigger.syntheticEvent(): TriggerEvent = when (this) {
    is Trigger.GeofenceExit -> TriggerEvent.GeofenceExited(placeId)
    is Trigger.GeofenceEnter -> TriggerEvent.GeofenceEntered(placeId)
    is Trigger.Approaching -> TriggerEvent.Approached(placeId, km)
    is Trigger.Schedule -> TriggerEvent.ScheduleFired(time)
    is Trigger.NearCar -> TriggerEvent.ApproachedCar(meters)
}

/** Place the trigger refers to, if any. */
val Trigger.placeId: String?
    get() = when (this) {
        is Trigger.GeofenceExit -> placeId
        is Trigger.GeofenceEnter -> placeId
        is Trigger.Approaching -> placeId
        is Trigger.Schedule -> null
        is Trigger.NearCar -> null
    }
