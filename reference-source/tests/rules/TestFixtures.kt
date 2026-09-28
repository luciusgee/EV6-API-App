package app.elroq.precondition.rules

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

val PRAGUE: ZoneId = ZoneId.of("Europe/Prague")

/** Wednesday 23 Sep 2026 at the given local time. */
fun wednesdayAt(hour: Int, minute: Int = 0): ZonedDateTime =
    ZonedDateTime.of(LocalDate.of(2026, 9, 23), LocalTime.of(hour, minute), PRAGUE)

val WEEKDAYS = setOf(DayOfWeek.MONDAY, DayOfWeek.TUESDAY, DayOfWeek.WEDNESDAY, DayOfWeek.THURSDAY, DayOfWeek.FRIDAY)

val OFFICE = Place("office", "Office", LatLon(50.0870, 14.4210), 200, usualParkingSpot = LatLon(50.0875, 14.4215))
val HOME = Place("home", "Home", LatLon(50.0500, 14.3000), 150)
val PLACES = listOf(OFFICE, HOME).associateBy { it.id }

fun vehicle(
    soc: Int? = 60,
    plugged: Boolean? = false,
    climate: ClimateState = ClimateState.OFF,
    outside: Double? = null,
    position: LatLon? = OFFICE.centre,
    fetchedAt: Instant = wednesdayAt(17).toInstant(),
) = VehicleSnapshot(
    socPercent = soc,
    pluggedIn = plugged,
    climate = climate,
    climateRawState = if (climate == ClimateState.RUNNING) "HEATING" else "OFF",
    outsideTempC = outside,
    parkingPosition = position,
    fetchedAtEpochMs = fetchedAt.toEpochMilli(),
)

/** Inputs whose values tests set directly, counting what the evaluator asked for. */
class FakeInputs(
    var vehicleState: VehicleSnapshot? = vehicle(),
    /** Vehicle state is already cached (free) rather than costing a read. */
    var cached: Boolean = false,
    var weather: Double? = 2.0,
    var forecast: Double? = 1.0,
    var cabin: Double? = null,
    /** Next to the car by default (the default vehicle is parked at the office). */
    var phone: LatLon? = OFFICE.centre,
) : EvaluationInputs {
    var phoneLookups = 0
    var vehicleReads = 0
    val weatherAt = mutableListOf<LatLon>()
    val forecastTimes = mutableListOf<Instant>()
    private var fetched = false

    override fun vehicleIfFree(): VehicleSnapshot? = if (cached || fetched) vehicleState else null

    override suspend fun vehicle(): VehicleSnapshot? {
        if (!cached && !fetched) {
            vehicleReads++
            fetched = true
        }
        return vehicleState
    }

    override suspend fun weatherNow(at: LatLon): TempReading? {
        weatherAt += at
        return weather?.let { TempReading(it, "Open-Meteo", Instant.EPOCH) }
    }

    override suspend fun forecastAt(at: LatLon, time: Instant): TempReading? {
        weatherAt += at
        forecastTimes += time
        return forecast?.let { TempReading(it, "Open-Meteo forecast", time) }
    }

    override suspend fun cabinTemp(): TempReading? = cabin?.let { TempReading(it, "cabin sensor", Instant.EPOCH) }

    override suspend fun phoneLocation(): LatLon? {
        phoneLookups++
        return phone
    }
}

fun rule(
    id: String = "r1",
    name: String = id,
    trigger: Trigger = Trigger.GeofenceExit("office"),
    conditions: List<Condition> = emptyList(),
    action: Action = Action.StartClimate(21.0),
    priority: Int = 0,
    enabled: Boolean = true,
    cooldownMinutes: Int = 60,
    proceedIfUnknown: Boolean = false,
) = Rule(id, name, enabled, priority, trigger, conditions, action, cooldownMinutes, proceedIfUnknown)
