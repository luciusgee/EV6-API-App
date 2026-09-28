package app.elroq.precondition.rules

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.DayOfWeek
import java.time.LocalTime

class RuleJsonTest {

    private val rules = listOf(
        Templates.leavingWork("office", id = "a"),
        Templates.morningCommute("home", id = "b"),
        Templates.hotDay("office", id = "c"),
        rule("d", trigger = Trigger.Approaching("home", 3.5), action = Action.StopClimate, conditions = listOf(
            Condition.PluggedIn(false),
            Condition.SocAtLeast(30),
            Condition.TempAbove(10.0, TempSource.CabinBle),
            Condition.TempBelow(0.0, TempSource.CarOutside),
        )),
        rule("e", trigger = Trigger.GeofenceEnter("home"), proceedIfUnknown = true, priority = 3),
    )

    @Test
    fun `export and import round-trip`() {
        val text = RuleJson.export(listOf(OFFICE, HOME), rules)
        val result = RuleJson.import(text)
        assertTrue(result.issues.toString(), result.ok)
        assertEquals(rules, result.rules)
        assertEquals(listOf(OFFICE, HOME), result.places)
    }

    @Test
    fun `export uses readable times and days`() {
        val text = RuleJson.export(emptyList(), listOf(Templates.morningCommute("home", id = "b")))
        assertTrue(text.contains("\"time\": \"07:20\""))
        assertTrue(text.contains("\"MON\""))
        assertTrue(text.contains("\"type\": \"forecastAt\""))
        assertFalse(text.lowercase().contains("apikey"))
    }

    @Test
    fun `hand-written rules accept full day names`() {
        val text = """
            {"rules": [{"id": "x", "name": "Sunday", "trigger": {"type": "schedule", "days": ["sunday"], "time": "9:05"},
              "action": {"type": "stopClimate"}}]}
        """.trimIndent()
        val result = RuleJson.import(text)
        assertTrue(result.issues.toString(), result.ok)
        assertEquals(Trigger.Schedule(setOf(DayOfWeek.SUNDAY), LocalTime.of(9, 5)), result.rules.single().trigger)
        assertEquals(Rule.DEFAULT_COOLDOWN_MINUTES, result.rules.single().cooldownMinutes)
    }

    @Test
    fun `invalid rules are reported individually and the rest imported`() {
        val text = """
            {"places": [{"id": "home", "name": "Home", "centre": {"lat": 50.0, "lon": 14.0}, "radiusM": 150}],
             "rules": [
              {"id": "ok", "name": "Fine", "trigger": {"type": "geofenceExit", "placeId": "home"}, "action": {"type": "startClimate", "targetC": 21}},
              {"id": "bad-time", "name": "Bad time", "trigger": {"type": "schedule", "days": ["MON"], "time": "25:00"}, "action": {"type": "stopClimate"}},
              {"id": "bad-place", "name": "Gym", "trigger": {"type": "geofenceExit", "placeId": "gym"}, "action": {"type": "startClimate", "targetC": 21}},
              {"id": "hot", "name": "Too hot", "trigger": {"type": "geofenceExit", "placeId": "home"}, "action": {"type": "startClimate", "targetC": 40}},
              {"id": "ok", "name": "Duplicate", "trigger": {"type": "geofenceExit", "placeId": "home"}, "action": {"type": "stopClimate"}},
              {"id": "weird", "name": "Unknown type", "trigger": {"type": "teleport"}, "action": {"type": "stopClimate"}}
             ]}
        """.trimIndent()
        val result = RuleJson.import(text)
        assertEquals(listOf("ok"), result.rules.map { it.id })
        val byName = result.issues.associateBy { it.name }
        assertTrue(byName["Bad time"]!!.message.contains("25:00"))
        assertTrue(byName["Gym"]!!.message.contains("unknown place 'gym'"))
        assertTrue(byName["Too hot"]!!.message.contains("16–30"))
        assertTrue(byName["Duplicate"]!!.message.contains("duplicate id"))
        assertTrue(byName.containsKey("Unknown type"))
        assertTrue(result.issues.first { it.name == "Gym" }.toString().startsWith("rule #3 \"Gym\""))
    }

    @Test
    fun `rules may refer to places already on the phone`() {
        val text = RuleJson.export(emptyList(), listOf(Templates.hotDay("office", id = "c")))
        assertFalse(RuleJson.import(text).ok)
        assertTrue(RuleJson.import(text, existingPlaceIds = setOf("office")).ok)
    }

    @Test
    fun `invalid places are reported`() {
        val text = """{"places": [{"id": "p", "name": "Tiny", "centre": {"lat": 50.0, "lon": 14.0}, "radiusM": 20}]}"""
        val result = RuleJson.import(text)
        assertTrue(result.places.isEmpty())
        assertTrue(result.issues.single().message.contains("radius"))
    }

    @Test
    fun `broken files are reported`() {
        assertEquals("file", RuleJson.import("not json").issues.single().section)
        assertTrue(RuleJson.import("""{"version": 99}""").issues.single().message.contains("newer"))
        assertTrue(RuleJson.import("""{"rules": {}}""").issues.single().message.contains("not a list"))
    }
}

class RuleValidatorTest {
    private val ids = setOf("office", "home")

    @Test
    fun `templates are valid`() {
        Templates.all.forEach { t ->
            assertEquals(t.title, emptyList<String>(), RuleValidator.validate(t.build("office"), ids))
        }
    }

    @Test
    fun `catches every kind of problem`() {
        val bad = Rule(
            id = "", name = " ", cooldownMinutes = -1,
            trigger = Trigger.Approaching("nowhere", 0.0),
            conditions = listOf(
                Condition.TimeWindow(LocalTime.NOON, LocalTime.NOON),
                Condition.DaysOfWeek(emptySet()),
                Condition.TempBelow(-60.0, TempSource.WeatherAtCar),
                Condition.TempAbove(60.0, TempSource.WeatherAtCar),
                Condition.SocAtLeast(120),
                Condition.CarAtPlace("nowhere"),
            ),
            action = Action.StartClimate(10.0),
        )
        val problems = RuleValidator.validate(bad, ids)
        // 12 field problems, plus "below -60 and above 60" being impossible together.
        assertEquals(problems.toString(), 13, problems.size)
        assertTrue(RuleValidator.validate(rule(trigger = Trigger.Schedule(emptySet(), LocalTime.NOON)), ids).single().contains("no days"))
        assertTrue(RuleValidator.validate(rule(trigger = Trigger.GeofenceEnter("x")), ids).single().contains("unknown place"))
    }

    @Test
    fun `validates places`() {
        assertTrue(RuleValidator.validatePlace(OFFICE).isEmpty())
        assertEquals(4, RuleValidator.validatePlace(Place("", "", LatLon(95.0, 0.0), 5000)).size)
    }
}

class ScheduleCalculatorTest {
    private val weekdays0720 = Trigger.Schedule(WEEKDAYS, LocalTime.of(7, 20))

    @Test
    fun `next occurrence later today`() {
        assertEquals(wednesdayAt(7, 20), ScheduleCalculator.next(weekdays0720, wednesdayAt(6)))
    }

    @Test
    fun `next occurrence skips the weekend`() {
        val friday = wednesdayAt(8).plusDays(2)
        assertEquals(wednesdayAt(7, 20).plusDays(5), ScheduleCalculator.next(weekdays0720, friday))
    }

    @Test
    fun `exactly at the time means the next one`() {
        assertEquals(wednesdayAt(7, 20).plusDays(1), ScheduleCalculator.next(weekdays0720, wednesdayAt(7, 20)))
    }

    @Test
    fun `one day a week wraps to next week`() {
        val wedOnly = Trigger.Schedule(setOf(DayOfWeek.WEDNESDAY), LocalTime.of(7, 20))
        assertEquals(wednesdayAt(7, 20).plusDays(7), ScheduleCalculator.next(wedOnly, wednesdayAt(9)))
    }

    @Test
    fun `no days never fires`() {
        assertEquals(null, ScheduleCalculator.next(Trigger.Schedule(emptySet(), LocalTime.NOON), wednesdayAt(9)))
    }

    @Test
    fun `soonest check across enabled rules`() {
        val rules = listOf(
            rule("a", trigger = weekdays0720),
            rule("b", trigger = Trigger.Schedule(WEEKDAYS, LocalTime.of(6, 45))),
            rule("c", trigger = Trigger.Schedule(WEEKDAYS, LocalTime.of(6, 30)), enabled = false),
            rule("d"),
        )
        val next = ScheduleCalculator.nextCheck(rules, wednesdayAt(6))!!
        assertEquals(wednesdayAt(6, 45), next.at)
        assertEquals(LocalTime.of(6, 45), next.time)
        assertEquals(null, ScheduleCalculator.nextCheck(listOf(rule("d")), wednesdayAt(6)))
    }

    @Test
    fun `a time in the spring-forward gap moves forward`() {
        val gap = Trigger.Schedule(setOf(DayOfWeek.SUNDAY), LocalTime.of(2, 30))
        val saturday = java.time.ZonedDateTime.of(2026, 3, 28, 12, 0, 0, 0, PRAGUE)
        val next = ScheduleCalculator.next(gap, saturday)!!
        assertEquals(LocalTime.of(3, 30), next.toLocalTime())
    }
}

class DescribeTest {
    private val name: (String) -> String = { PLACES[it]?.name ?: it }

    @Test
    fun `describes triggers, events, conditions and actions`() {
        assertEquals("leave Office", Describe.trigger(Trigger.GeofenceExit("office"), name))
        assertEquals("arrive at Home", Describe.trigger(Trigger.GeofenceEnter("home"), name))
        assertEquals("within 2.5 km of Home", Describe.trigger(Trigger.Approaching("home", 2.5), name))
        assertEquals("within 3 km of Home", Describe.trigger(Trigger.Approaching("home", 3.0), name))
        assertEquals("Mon–Fri at 07:20", Describe.trigger(Trigger.Schedule(WEEKDAYS, LocalTime.of(7, 20)), name))
        assertEquals("every day", Describe.days(DayOfWeek.entries.toSet()))
        assertEquals("Sat–Sun", Describe.days(setOf(DayOfWeek.SATURDAY, DayOfWeek.SUNDAY)))
        assertEquals("Mon,Wed", Describe.days(setOf(DayOfWeek.WEDNESDAY, DayOfWeek.MONDAY)))

        assertEquals("left Office", Describe.event(TriggerEvent.GeofenceExited("office"), name))
        assertEquals("arrived at Home", Describe.event(TriggerEvent.GeofenceEntered("home"), name))
        assertEquals("approaching Home (5 km)", Describe.event(TriggerEvent.Approached("home", 5.0), name))
        assertEquals("schedule 07:20", Describe.event(TriggerEvent.ScheduleFired(LocalTime.of(7, 20)), name))

        assertEquals("16:00–19:00", Describe.condition(Condition.TimeWindow(LocalTime.of(16, 0), LocalTime.of(19, 0)), name))
        assertEquals("Mon–Fri", Describe.condition(Condition.DaysOfWeek(WEEKDAYS), name))
        assertEquals("temp at car below 5.0 °C", Describe.condition(Condition.TempBelow(5.0, TempSource.BestAvailable), name))
        assertEquals("weather at car above 24.0 °C", Describe.condition(Condition.TempAbove(24.0, TempSource.WeatherAtCar), name))
        assertEquals("forecast at 07:40 below 3.0 °C", Describe.condition(Condition.TempBelow(3.0, TempSource.ForecastAt(LocalTime.of(7, 40))), name))
        assertEquals("cabin sensor above 1.0 °C", Describe.condition(Condition.TempAbove(1.0, TempSource.CabinBle), name))
        assertEquals("car outside temp above 1.0 °C", Describe.condition(Condition.TempAbove(1.0, TempSource.CarOutside), name))
        assertEquals("SoC ≥ 40%", Describe.condition(Condition.SocAtLeast(40), name))
        assertEquals("plugged in", Describe.condition(Condition.PluggedIn(true), name))
        assertEquals("not plugged in", Describe.condition(Condition.PluggedIn(false), name))
        assertEquals("car at Home", Describe.condition(Condition.CarAtPlace("home"), name))

        assertEquals("climatise to 21.0 °C", Describe.action(Action.StartClimate(21.0)))
        assertEquals("stop climatisation", Describe.action(Action.StopClimate))
    }

    @Test
    fun `trigger helpers`() {
        assertEquals("office", Trigger.GeofenceExit("office").placeId)
        assertEquals("home", Trigger.GeofenceEnter("home").placeId)
        assertEquals("home", Trigger.Approaching("home", 1.0).placeId)
        assertEquals(null, Trigger.Schedule(WEEKDAYS, LocalTime.NOON).placeId)
        assertEquals(TriggerEvent.Approached("home", 1.0), Trigger.Approaching("home", 1.0).syntheticEvent())
        assertEquals(TriggerEvent.GeofenceEntered("home"), Trigger.GeofenceEnter("home").syntheticEvent())
        assertEquals("exit:office", TriggerEvent.GeofenceExited("office").dedupKey)
        assertEquals("enter:home", TriggerEvent.GeofenceEntered("home").dedupKey)
        assertEquals("approach:home:1.0", TriggerEvent.Approached("home", 1.0).dedupKey)
        assertEquals(null, TriggerEvent.ScheduleFired(LocalTime.NOON).dedupKey)
    }

    @Test
    fun `distance and containment`() {
        val a = LatLon(50.0, 14.0)
        assertEquals(0.0, a.distanceTo(a), 0.001)
        assertEquals(111_195.0, a.distanceTo(LatLon(51.0, 14.0)), 50.0)
        assertTrue(OFFICE.contains(OFFICE.centre))
        assertFalse(OFFICE.contains(HOME.centre))
        assertEquals(HOME.centre, HOME.parkingSpotOrCentre)
    }
}
