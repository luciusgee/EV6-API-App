package app.elroq.precondition.rules

import java.time.DayOfWeek
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Human-readable descriptions used by logs, notifications and the rules list. */
object Describe {
    private val hhmm = DateTimeFormatter.ofPattern("HH:mm")

    fun time(t: LocalTime): String = t.format(hhmm)

    fun temp(c: Double): String = String.format(Locale.ROOT, "%.1f °C", c)

    fun days(days: Set<DayOfWeek>): String {
        if (days.size == 7) return "every day"
        val weekdays = setOf(
            DayOfWeek.MONDAY, DayOfWeek.TUESDAY, DayOfWeek.WEDNESDAY, DayOfWeek.THURSDAY, DayOfWeek.FRIDAY,
        )
        if (days == weekdays) return "Mon–Fri"
        if (days == setOf(DayOfWeek.SATURDAY, DayOfWeek.SUNDAY)) return "Sat–Sun"
        return days.sorted().joinToString(",") { d ->
            d.name.take(3).lowercase().replaceFirstChar { it.uppercase() }
        }
    }

    fun trigger(t: Trigger, placeName: (String) -> String): String = when (t) {
        is Trigger.GeofenceExit -> "leave ${placeName(t.placeId)}"
        is Trigger.GeofenceEnter -> "arrive at ${placeName(t.placeId)}"
        is Trigger.Approaching -> "within ${trimNumber(t.km)} km of ${placeName(t.placeId)}"
        is Trigger.Schedule -> "${days(t.days)} at ${time(t.time)}"
        is Trigger.NearCar -> "within ${t.meters} m of the car"
    }

    fun event(e: TriggerEvent, placeName: (String) -> String): String = when (e) {
        is TriggerEvent.GeofenceExited -> "left ${placeName(e.placeId)}"
        is TriggerEvent.GeofenceEntered -> "arrived at ${placeName(e.placeId)}"
        is TriggerEvent.Approached -> "approaching ${placeName(e.placeId)} (${trimNumber(e.km)} km)"
        is TriggerEvent.ScheduleFired -> "schedule ${time(e.time)}"
        is TriggerEvent.ApproachedCar -> "approaching the car (${e.meters} m)"
    }

    fun source(s: TempSource): String = when (s) {
        TempSource.CarOutside -> "car outside temp"
        TempSource.WeatherAtCar -> "weather at car"
        is TempSource.ForecastAt -> "forecast at ${time(s.time)}"
        TempSource.CabinBle -> "cabin sensor"
        TempSource.BestAvailable -> "temp at car"
    }

    fun condition(c: Condition, placeName: (String) -> String): String = when (c) {
        is Condition.TimeWindow -> "${time(c.start)}–${time(c.end)}"
        is Condition.DaysOfWeek -> days(c.days)
        is Condition.TempBelow -> "${source(c.source)} below ${temp(c.celsius)}"
        is Condition.TempAbove -> "${source(c.source)} above ${temp(c.celsius)}"
        is Condition.TempOutside -> "${source(c.source)} below ${temp(c.low)} or above ${temp(c.high)}"
        is Condition.SocAtLeast -> "SoC ≥ ${c.percent}%"
        is Condition.PluggedIn -> if (c.expected) "plugged in" else "not plugged in"
        is Condition.CarAtPlace -> "car at ${placeName(c.placeId)}"
        is Condition.PhoneNearCar -> "phone within ${distance(c.meters)} of the car"
    }

    fun distance(meters: Int): String =
        if (meters >= 1000) "${trimNumber(meters / 1000.0)} km" else "$meters m"

    fun action(a: Action): String = when (a) {
        is Action.StartClimate -> "climatise to ${temp(a.targetC)}"
        Action.StopClimate -> "stop climatisation"
    }

    private fun trimNumber(d: Double): String =
        if (d == Math.floor(d)) d.toLong().toString() else String.format(Locale.ROOT, "%.1f", d)
}
