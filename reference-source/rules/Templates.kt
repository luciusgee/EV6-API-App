package app.elroq.precondition.rules

import java.time.DayOfWeek
import java.time.LocalTime
import java.util.UUID

/** The example rules from the spec, offered as starting points in the rule editor. */
object Templates {
    private val weekdays = setOf(
        DayOfWeek.MONDAY, DayOfWeek.TUESDAY, DayOfWeek.WEDNESDAY, DayOfWeek.THURSDAY, DayOfWeek.FRIDAY,
    )

    data class Template(val title: String, val description: String, val placeHint: String, val build: (placeId: String) -> Rule)

    val all: List<Template> = listOf(
        Template(
            title = "Leaving work",
            description = "Leave the office Mon–Fri 16:00–19:00 below 5 °C, phone near the car → heat to 21 °C",
            placeHint = "Office",
        ) { office -> leavingWork(office) },
        Template(
            title = "Morning commute",
            description = "Mon–Fri 07:20, car at Home and you with it, forecast at 07:40 below 3 °C → heat to 20 °C",
            placeHint = "Home",
        ) { home -> morningCommute(home) },
        Template(
            title = "Hot day",
            description = "Leave the office when it is above 24 °C at the car → cool to 20 °C",
            placeHint = "Office",
        ) { office -> hotDay(office) },
    )

    fun leavingWork(officeId: String, id: String = newId()) = Rule(
        id = id,
        name = "Leaving work",
        trigger = Trigger.GeofenceExit(officeId),
        conditions = listOf(
            Condition.DaysOfWeek(weekdays),
            Condition.TimeWindow(LocalTime.of(16, 0), LocalTime.of(19, 0)),
            Condition.TempBelow(5.0, TempSource.BestAvailable),
            // Only if you're actually with the car, not if it was left at work while you're elsewhere.
            Condition.PhoneNearCar(1500),
        ),
        action = Action.StartClimate(21.0),
    )

    fun morningCommute(homeId: String, id: String = newId()) = Rule(
        id = id,
        name = "Morning commute",
        trigger = Trigger.Schedule(weekdays, LocalTime.of(7, 20)),
        conditions = listOf(
            Condition.CarAtPlace(homeId),
            // Not when you're away (e.g. on holiday) and the car is at home.
            Condition.PhoneNearCar(500),
            Condition.TempBelow(3.0, TempSource.ForecastAt(LocalTime.of(7, 40))),
        ),
        action = Action.StartClimate(20.0),
    )

    fun hotDay(officeId: String, id: String = newId()) = Rule(
        id = id,
        name = "Hot day",
        trigger = Trigger.GeofenceExit(officeId),
        conditions = listOf(Condition.TempAbove(24.0, TempSource.WeatherAtCar)),
        action = Action.StartClimate(20.0),
    )

    fun newId(): String = UUID.randomUUID().toString()
}
