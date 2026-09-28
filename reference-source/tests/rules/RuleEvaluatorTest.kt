package app.elroq.precondition.rules

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalTime
import java.time.ZonedDateTime
import kotlin.time.Duration.Companion.minutes

class RuleEvaluatorTest {
    private val evaluator = RuleEvaluator()
    private val exitOffice = TriggerEvent.GeofenceExited("office")

    private suspend fun evaluate(
        rules: List<Rule>,
        inputs: FakeInputs = FakeInputs(),
        now: ZonedDateTime = wednesdayAt(17),
        event: TriggerEvent = exitOffice,
        guards: GuardSettings = GuardSettings(),
        cooldowns: CooldownState = CooldownState(),
        budget: Int = 16,
        requireTriggerMatch: Boolean = true,
    ): Evaluation = evaluator.evaluate(
        EvaluationRequest(event, now, rules, PLACES, guards, cooldowns, { budget }, inputs, requireTriggerMatch),
    )

    private val leavingWork = Templates.leavingWork("office", id = "leave")

    // ---- The spec's example rules ---------------------------------------------------------

    @Test
    fun `leaving work fires on a cold weekday evening`() = runTest {
        val result = evaluate(listOf(leavingWork), FakeInputs(weather = 3.0))
        assertEquals(leavingWork, result.winner)
        assertEquals(Action.StartClimate(21.0), result.winner!!.action)
        assertTrue(result.winnerVerdict!!.reason.contains("3.0 °C"))
        assertEquals(3.0, result.winnerVerdict!!.temperature!!.celsius, 0.0)
    }

    @Test
    fun `leaving work is skipped outside its time window without reading the car`() = runTest {
        val inputs = FakeInputs(weather = 3.0)
        val result = evaluate(listOf(leavingWork), inputs, now = wednesdayAt(15, 59))
        assertNull(result.winner)
        assertTrue(result.verdicts.single().reason.contains("16:00–19:00"))
        assertEquals(0, inputs.vehicleReads)
        assertTrue(inputs.weatherAt.isEmpty())
    }

    @Test
    fun `leaving work is skipped at the weekend`() = runTest {
        val saturday = wednesdayAt(17).plusDays(3)
        val result = evaluate(listOf(leavingWork), FakeInputs(weather = 3.0), now = saturday)
        assertNull(result.winner)
        assertTrue(result.verdicts.single().reason.contains("today is Sat"))
    }

    @Test
    fun `leaving work is skipped when it is not cold`() = runTest {
        val result = evaluate(listOf(leavingWork), FakeInputs(weather = 8.0))
        assertNull(result.winner)
        assertTrue(result.verdicts.single().reason, result.verdicts.single().reason.contains("8.0 °C"))
    }

    @Test
    fun `morning commute uses the forecast at departure time`() = runTest {
        val morning = Templates.morningCommute("home", id = "morning")
        val inputs = FakeInputs(vehicleState = vehicle(position = HOME.centre), forecast = 1.5, phone = HOME.centre)
        val now = wednesdayAt(7, 20)
        val result = evaluate(listOf(morning), inputs, now = now, event = TriggerEvent.ScheduleFired(LocalTime.of(7, 20)))
        assertEquals(morning, result.winner)
        assertEquals(wednesdayAt(7, 40).toInstant(), inputs.forecastTimes.single())
    }

    @Test
    fun `forecast time more than an hour past means tomorrow`() = runTest {
        val r = rule(
            trigger = Trigger.Schedule(WEEKDAYS, LocalTime.of(9, 0)),
            conditions = listOf(Condition.TempBelow(3.0, TempSource.ForecastAt(LocalTime.of(7, 40)))),
        )
        val inputs = FakeInputs()
        evaluate(listOf(r), inputs, now = wednesdayAt(9), event = TriggerEvent.ScheduleFired(LocalTime.of(9, 0)))
        assertEquals(wednesdayAt(7, 40).plusDays(1).toInstant(), inputs.forecastTimes.single())
    }

    @Test
    fun `morning commute is skipped when the car is not at home`() = runTest {
        val morning = Templates.morningCommute("home", id = "morning")
        val inputs = FakeInputs(vehicleState = vehicle(position = OFFICE.centre))
        val result = evaluate(listOf(morning), inputs, now = wednesdayAt(7, 20), event = TriggerEvent.ScheduleFired(LocalTime.of(7, 20)))
        assertNull(result.winner)
        assertTrue(result.verdicts.single().reason.contains("from Home"))
    }

    @Test
    fun `hot day cools when weather at the car is above 24`() = runTest {
        val hot = Templates.hotDay("office", id = "hot")
        val result = evaluate(listOf(hot), FakeInputs(weather = 27.0), now = wednesdayAt(13))
        assertEquals(hot, result.winner)
    }

    // ---- Guards -----------------------------------------------------------------------------

    @Test
    fun `low state of charge blocks start`() = runTest {
        val result = evaluate(listOf(rule()), FakeInputs(vehicleState = vehicle(soc = 20)))
        assertNull(result.winner)
        assertTrue(result.verdicts.single().reason.contains("SoC 20% below minimum 25%"))
    }

    @Test
    fun `low state of charge is fine when plugged in`() = runTest {
        val result = evaluate(listOf(rule()), FakeInputs(vehicleState = vehicle(soc = 10, plugged = true)))
        assertEquals("r1", result.winner?.id)
    }

    @Test
    fun `unknown state of charge blocks start even when the rule proceeds on unknowns`() = runTest {
        val r = rule(proceedIfUnknown = true)
        val result = evaluate(listOf(r), FakeInputs(vehicleState = vehicle(soc = null, plugged = null)))
        assertNull(result.winner)
        assertTrue(result.verdicts.single().reason.contains("state of charge unknown"))
    }

    @Test
    fun `custom minimum SoC is respected`() = runTest {
        val result = evaluate(listOf(rule()), FakeInputs(vehicleState = vehicle(soc = 40)), guards = GuardSettings(minSocPercent = 50))
        assertNull(result.winner)
    }

    @Test
    fun `already running blocks start`() = runTest {
        val result = evaluate(listOf(rule()), FakeInputs(vehicleState = vehicle(climate = ClimateState.RUNNING)))
        assertNull(result.winner)
        assertTrue(result.verdicts.single().reason.contains("already running (HEATING)"))
    }

    @Test
    fun `unknown climate state blocks start`() = runTest {
        val result = evaluate(listOf(rule()), FakeInputs(vehicleState = vehicle(climate = ClimateState.UNKNOWN)))
        assertNull(result.winner)
        assertTrue(result.verdicts.single().reason.contains("climatisation state unknown"))
    }

    @Test
    fun `unavailable vehicle state blocks every action`() = runTest {
        val result = evaluate(listOf(rule()), FakeInputs(vehicleState = null))
        assertNull(result.winner)
        assertEquals("vehicle state: unavailable", result.verdicts.single().reason)
    }

    @Test
    fun `stop needs climatisation to be running and ignores SoC`() = runTest {
        val stop = rule(action = Action.StopClimate)
        assertEquals(
            stop,
            evaluate(listOf(stop), FakeInputs(vehicleState = vehicle(soc = 5, climate = ClimateState.RUNNING))).winner,
        )
        val off = evaluate(listOf(stop), FakeInputs(vehicleState = vehicle(climate = ClimateState.OFF)))
        assertTrue(off.verdicts.single().reason.contains("already off"))
        val unknown = evaluate(listOf(stop), FakeInputs(vehicleState = vehicle(climate = ClimateState.UNKNOWN)))
        assertTrue(unknown.verdicts.single().reason.contains("unknown"))
    }

    @Test
    fun `rule cooldown blocks without reading the car`() = runTest {
        val inputs = FakeInputs()
        val cooldowns = CooldownState(lastFiredByRule = mapOf("r1" to wednesdayAt(16, 30).toInstant()))
        val result = evaluate(listOf(rule()), inputs, cooldowns = cooldowns)
        assertNull(result.winner)
        assertTrue(result.verdicts.single().reason.contains("rule cooldown: active until 17:30"))
        assertEquals(0, inputs.vehicleReads)
    }

    @Test
    fun `rule cooldown expires`() = runTest {
        val cooldowns = CooldownState(lastFiredByRule = mapOf("r1" to wednesdayAt(15, 59).toInstant()))
        assertEquals("r1", evaluate(listOf(rule()), cooldowns = cooldowns).winner?.id)
    }

    @Test
    fun `global cooldown blocks every rule`() = runTest {
        val cooldowns = CooldownState(lastAutomatedCommandAt = wednesdayAt(16, 50).toInstant())
        val result = evaluate(listOf(rule("a"), rule("b")), cooldowns = cooldowns)
        assertNull(result.winner)
        assertTrue(result.verdicts.all { it.reason.contains("global cooldown: active until 17:05") })
    }

    @Test
    fun `global cooldown uses the configured length`() = runTest {
        val cooldowns = CooldownState(lastAutomatedCommandAt = wednesdayAt(16, 50).toInstant())
        assertEquals("r1", evaluate(listOf(rule()), cooldowns = cooldowns, guards = GuardSettings(globalCooldown = 5.minutes)).winner?.id)
    }

    @Test
    fun `rate budget must cover the read and the command`() = runTest {
        val inputs = FakeInputs()
        val result = evaluate(listOf(rule()), inputs, budget = 1)
        assertNull(result.winner)
        assertTrue(result.verdicts.single().reason.contains("only 1 automation requests left, needs 2"))
        assertEquals(0, inputs.vehicleReads)
    }

    @Test
    fun `a fresh cache means one request is enough`() = runTest {
        val inputs = FakeInputs(cached = true)
        assertEquals("r1", evaluate(listOf(rule()), inputs, budget = 1).winner?.id)
        assertEquals(0, inputs.vehicleReads)
    }

    @Test
    fun `paused automation skips everything`() = runTest {
        val result = evaluate(listOf(rule()), guards = GuardSettings(automationPaused = true))
        assertEquals("automation paused", result.globalSkip)
        assertTrue(result.verdicts.isEmpty())
    }

    @Test
    fun `holidays skip everything`() = runTest {
        val result = evaluate(listOf(rule()), guards = GuardSettings(holidays = setOf(wednesdayAt(0).toLocalDate())))
        assertEquals("holiday 2026-09-23", result.globalSkip)
    }

    // ---- Matching and ordering ------------------------------------------------------------

    @Test
    fun `only enabled rules for this trigger are considered`() = runTest {
        val rules = listOf(
            rule("disabled", enabled = false),
            rule("enter", trigger = Trigger.GeofenceEnter("office")),
            rule("home", trigger = Trigger.GeofenceExit("home")),
        )
        assertEquals("no enabled rules for this trigger", evaluate(rules).globalSkip)
    }

    @Test
    fun `highest priority wins and lower rules are not evaluated`() = runTest {
        val rules = listOf(rule("low", priority = 1), rule("high", priority = 5))
        val result = evaluate(rules)
        assertEquals("high", result.winner?.id)
        assertEquals(listOf("high"), result.verdicts.map { it.ruleId })
    }

    @Test
    fun `a failing higher rule falls through to the next`() = runTest {
        val rules = listOf(
            rule("high", priority = 5, conditions = listOf(Condition.TempBelow(-10.0, TempSource.WeatherAtCar))),
            rule("low", priority = 1),
        )
        val result = evaluate(rules)
        assertEquals("low", result.winner?.id)
        assertEquals(listOf("high", "low"), result.verdicts.map { it.ruleId })
        assertFalse(result.verdicts.first().fired)
    }

    @Test
    fun `equal priorities are ordered by name`() = runTest {
        val result = evaluate(listOf(rule("2", name = "b"), rule("1", name = "a")))
        assertEquals("1", result.winner?.id)
    }

    @Test
    fun `approaching and entering triggers match their own events`() = runTest {
        val approach = rule("approach", trigger = Trigger.Approaching("home", 5.0))
        assertEquals("approach", evaluate(listOf(approach), event = TriggerEvent.Approached("home", 5.0)).winner?.id)
        assertNull(evaluate(listOf(approach), event = TriggerEvent.Approached("home", 2.0)).winner)
        val enter = rule("enter", trigger = Trigger.GeofenceEnter("home"))
        assertEquals("enter", evaluate(listOf(enter), event = TriggerEvent.GeofenceEntered("home")).winner?.id)
    }

    @Test
    fun `schedule triggers match only on their days`() = runTest {
        val sched = rule(trigger = Trigger.Schedule(setOf(java.time.DayOfWeek.THURSDAY), LocalTime.of(17, 0)))
        val event = TriggerEvent.ScheduleFired(LocalTime.of(17, 0))
        assertNull(evaluate(listOf(sched), event = event).winner)
        assertEquals("r1", evaluate(listOf(sched), event = event, now = wednesdayAt(17).plusDays(1)).winner?.id)
    }

    @Test
    fun `dry runs can ignore the trigger`() = runTest {
        val r = rule(trigger = Trigger.GeofenceEnter("home"))
        assertEquals("r1", evaluate(listOf(r), requireTriggerMatch = false).winner?.id)
    }

    // ---- Conditions -----------------------------------------------------------------------

    @Test
    fun `unknown temperature fails unless the rule proceeds on unknowns`() = runTest {
        val cond = listOf(Condition.TempBelow(5.0, TempSource.WeatherAtCar))
        val failed = evaluate(listOf(rule(conditions = cond)), FakeInputs(weather = null))
        assertNull(failed.winner)
        assertTrue(failed.verdicts.single().reason.contains("weather at car unavailable"))
        assertEquals(Tri.UNKNOWN, failed.verdicts.single().checks.last().result)

        val proceeded = evaluate(listOf(rule(conditions = cond, proceedIfUnknown = true)), FakeInputs(weather = null))
        assertEquals("r1", proceeded.winner?.id)
        assertTrue(proceeded.winnerVerdict!!.reason.contains("proceeding"))
    }

    @Test
    fun `weather is checked before the car is read when the place gives a location`() = runTest {
        val inputs = FakeInputs(weather = 10.0)
        val r = rule(conditions = listOf(Condition.TempBelow(5.0, TempSource.WeatherAtCar), Condition.SocAtLeast(50)))
        val result = evaluate(listOf(r), inputs)
        assertNull(result.winner)
        assertEquals(0, inputs.vehicleReads)
        assertEquals(OFFICE.usualParkingSpot, inputs.weatherAt.single())
        assertTrue(result.verdicts.single().reason.contains("usual spot at Office"))
    }

    @Test
    fun `weather uses the cached car position when there is one`() = runTest {
        val parked = LatLon(50.1, 14.5)
        val inputs = FakeInputs(vehicleState = vehicle(position = parked), cached = true)
        evaluate(listOf(rule(conditions = listOf(Condition.TempBelow(5.0, TempSource.WeatherAtCar)))), inputs)
        assertEquals(parked, inputs.weatherAt.single())
    }

    @Test
    fun `place centre is used when the place has no usual parking spot`() = runTest {
        val inputs = FakeInputs()
        val r = rule(trigger = Trigger.GeofenceExit("home"), conditions = listOf(Condition.TempBelow(5.0, TempSource.WeatherAtCar)))
        evaluate(listOf(r), inputs, event = TriggerEvent.GeofenceExited("home"))
        assertEquals(HOME.centre, inputs.weatherAt.single())
    }

    @Test
    fun `schedule rules without a place read the car for its position`() = runTest {
        val parked = LatLon(49.9, 14.0)
        val inputs = FakeInputs(vehicleState = vehicle(position = parked))
        val r = rule(
            trigger = Trigger.Schedule(WEEKDAYS, LocalTime.of(17, 0)),
            conditions = listOf(Condition.TempBelow(5.0, TempSource.WeatherAtCar)),
        )
        val result = evaluate(listOf(r), inputs, event = TriggerEvent.ScheduleFired(LocalTime.of(17, 0)))
        assertEquals("r1", result.winner?.id)
        assertEquals(1, inputs.vehicleReads)
        assertEquals(parked, inputs.weatherAt.single())
    }

    @Test
    fun `schedule rules without any location have unknown weather`() = runTest {
        val inputs = FakeInputs(vehicleState = vehicle(position = null))
        val r = rule(
            trigger = Trigger.Schedule(WEEKDAYS, LocalTime.of(17, 0)),
            conditions = listOf(Condition.TempBelow(5.0, TempSource.WeatherAtCar)),
        )
        val result = evaluate(listOf(r), inputs, event = TriggerEvent.ScheduleFired(LocalTime.of(17, 0)))
        assertNull(result.winner)
        assertTrue(inputs.weatherAt.isEmpty())
    }

    @Test
    fun `best available prefers the car's own sensor`() = runTest {
        val inputs = FakeInputs(vehicleState = vehicle(outside = 1.0), weather = 10.0)
        val result = evaluate(listOf(rule(conditions = listOf(Condition.TempBelow(5.0, TempSource.BestAvailable)))), inputs)
        assertEquals("r1", result.winner?.id)
        assertTrue(inputs.weatherAt.isEmpty())
        assertTrue(result.winnerVerdict!!.reason.contains("car sensor"))
    }

    @Test
    fun `best available falls back to weather`() = runTest {
        val inputs = FakeInputs(vehicleState = vehicle(outside = null), weather = 1.0)
        val result = evaluate(listOf(rule(conditions = listOf(Condition.TempBelow(5.0, TempSource.BestAvailable)))), inputs)
        assertEquals("r1", result.winner?.id)
        assertTrue(result.winnerVerdict!!.reason.contains("Open-Meteo"))
    }

    @Test
    fun `best available skips the read when the cache shows no car sensor`() = runTest {
        val inputs = FakeInputs(vehicleState = vehicle(outside = null), cached = true, weather = 9.0)
        evaluate(listOf(rule(conditions = listOf(Condition.TempBelow(5.0, TempSource.BestAvailable)))), inputs)
        assertEquals(0, inputs.vehicleReads)
        assertEquals(1, inputs.weatherAt.size)
    }

    @Test
    fun `car outside temperature unknown when the car does not report it`() = runTest {
        val result = evaluate(listOf(rule(conditions = listOf(Condition.TempAbove(20.0, TempSource.CarOutside)))))
        assertTrue(result.verdicts.single().reason.contains("car outside temp unavailable"))
    }

    @Test
    fun `cabin sensor is used when in range`() = runTest {
        val cond = listOf(Condition.TempAbove(30.0, TempSource.CabinBle))
        assertNull(evaluate(listOf(rule(conditions = cond)), FakeInputs(cabin = null)).winner)
        assertEquals("r1", evaluate(listOf(rule(conditions = cond)), FakeInputs(cabin = 35.0)).winner?.id)
        assertNull(evaluate(listOf(rule(conditions = cond)), FakeInputs(cabin = 25.0)).winner)
    }

    @Test
    fun `soc and plug conditions`() = runTest {
        val soc = rule(conditions = listOf(Condition.SocAtLeast(50)))
        assertEquals("r1", evaluate(listOf(soc), FakeInputs(vehicleState = vehicle(soc = 50))).winner?.id)
        assertTrue(evaluate(listOf(soc), FakeInputs(vehicleState = vehicle(soc = 49))).verdicts.single().reason.contains("49% < 50%"))
        assertTrue(evaluate(listOf(soc), FakeInputs(vehicleState = vehicle(soc = null, plugged = true))).verdicts.single().reason.contains("SoC unknown"))

        val plugged = rule(conditions = listOf(Condition.PluggedIn(true)))
        assertEquals("r1", evaluate(listOf(plugged), FakeInputs(vehicleState = vehicle(plugged = true))).winner?.id)
        assertNull(evaluate(listOf(plugged), FakeInputs(vehicleState = vehicle(plugged = false))).winner)
        assertTrue(evaluate(listOf(plugged), FakeInputs(vehicleState = vehicle(plugged = null))).verdicts.single().reason.contains("plug state unknown"))

        val unplugged = rule(conditions = listOf(Condition.PluggedIn(false)))
        assertEquals("r1", evaluate(listOf(unplugged), FakeInputs(vehicleState = vehicle(plugged = false))).winner?.id)
    }

    @Test
    fun `car at place is unknown without a parking position and fails for a deleted place`() = runTest {
        val atHome = rule(conditions = listOf(Condition.CarAtPlace("home")))
        val noPos = evaluate(listOf(atHome), FakeInputs(vehicleState = vehicle(position = null)))
        assertTrue(noPos.verdicts.single().reason.contains("parking position unavailable"))

        val gone = rule(conditions = listOf(Condition.CarAtPlace("gym")))
        assertTrue(evaluate(listOf(gone)).verdicts.single().reason.contains("no longer exists"))

        val atOffice = rule(conditions = listOf(Condition.CarAtPlace("office")))
        assertEquals("r1", evaluate(listOf(atOffice)).winner?.id)
    }

    @Test
    fun `time windows can wrap past midnight`() = runTest {
        val night = rule(conditions = listOf(Condition.TimeWindow(LocalTime.of(22, 0), LocalTime.of(6, 0))))
        assertEquals("r1", evaluate(listOf(night), now = wednesdayAt(23)).winner?.id)
        assertEquals("r1", evaluate(listOf(night), now = wednesdayAt(5, 59)).winner?.id)
        assertNull(evaluate(listOf(night), now = wednesdayAt(6)).winner)
        val allDay = rule(conditions = listOf(Condition.TimeWindow(LocalTime.NOON, LocalTime.NOON)))
        assertEquals("r1", evaluate(listOf(allDay)).winner?.id)
    }

    @Test
    fun `a rule with no conditions fires on guards alone`() = runTest {
        val result = evaluate(listOf(rule()))
        assertEquals("no conditions; guards passed", result.winnerVerdict!!.reason)
    }
}
