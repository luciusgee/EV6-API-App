package app.elroq.precondition.rules

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NearCarTest {
    private val parked = LatLon(50.10, 14.50)

    @Test
    fun `near-car rules register a fence around the parked car`() {
        val rules = listOf(rule("a", trigger = Trigger.NearCar(300)), rule("b", trigger = Trigger.NearCar(300)), rule("c", trigger = Trigger.NearCar(800)))
        val specs = Geofences.required(rules, emptyList(), parked)
        assertEquals(
            listOf(
                GeofenceSpec("car:300", parked, 300f, enter = true, exit = false),
                GeofenceSpec("car:800", parked, 800f, enter = true, exit = false),
            ),
            specs,
        )
        assertTrue(Geofences.required(rules, emptyList(), carPosition = null).isEmpty())
        assertTrue(Geofences.needsCarPosition(rules))
        assertFalse(Geofences.needsCarPosition(listOf(rule("x"), rule("y", trigger = Trigger.NearCar(300), enabled = false))))
    }

    @Test
    fun `car fence events map back to the trigger`() {
        val event = Geofences.eventFor("car:300", Transition.ENTER)
        assertEquals(TriggerEvent.ApproachedCar(300), event)
        assertTrue(Trigger.NearCar(300).matches(event!!, java.time.DayOfWeek.MONDAY))
        assertFalse(Trigger.NearCar(500).matches(event, java.time.DayOfWeek.MONDAY))
        assertNull(Geofences.eventFor("car:300", Transition.EXIT))
        assertNull(Geofences.eventFor("car:far", Transition.ENTER))
        assertEquals("car:300", event.dedupKey)
        assertEquals(TriggerEvent.ApproachedCar(300), Trigger.NearCar(300).syntheticEvent())
        assertNull(Trigger.NearCar(300).placeId)
    }

    @Test
    fun `describes, validates and serialises`() {
        assertEquals("within 300 m of the car", Describe.trigger(Trigger.NearCar(300)) { it })
        assertEquals("approaching the car (300 m)", Describe.event(TriggerEvent.ApproachedCar(300)) { it })
        assertTrue(RuleValidator.validate(rule(trigger = Trigger.NearCar(300)), emptySet()).isEmpty())
        assertTrue(RuleValidator.validate(rule(trigger = Trigger.NearCar(50)), emptySet()).single().contains("100–5000 m"))
        val r = rule(trigger = Trigger.NearCar(400))
        val text = RuleJson.export(emptyList(), listOf(r))
        assertTrue(text.contains("\"nearCar\""))
        assertEquals(listOf(r), RuleJson.import(text).rules)
    }

    @Test
    fun `weather for a near-car rule uses the car's position`() = runTest {
        val inputs = FakeInputs(vehicleState = vehicle(position = parked), cached = true, weather = 1.0)
        val r = rule(trigger = Trigger.NearCar(300), conditions = listOf(Condition.TempBelow(5.0, TempSource.WeatherAtCar)))
        val result = RuleEvaluator().evaluate(
            EvaluationRequest(TriggerEvent.ApproachedCar(300), wednesdayAt(17), listOf(r), PLACES, GuardSettings(), CooldownState(), { 16 }, inputs),
        )
        assertEquals("r1", result.winner?.id)
        assertEquals(parked, inputs.weatherAt.single())
        assertEquals(0, inputs.vehicleReads)
    }
}

class PhoneNearCarTest {
    private val evaluator = RuleEvaluator()
    private val near = rule(conditions = listOf(Condition.PhoneNearCar(500)))

    private suspend fun eval(inputs: FakeInputs, r: Rule = near) = evaluator.evaluate(
        EvaluationRequest(TriggerEvent.GeofenceExited("office"), wednesdayAt(17), listOf(r), PLACES, GuardSettings(), CooldownState(), { 16 }, inputs),
    )

    @Test
    fun `passes when the phone is near the car`() = runTest {
        val result = eval(FakeInputs(phone = LatLon(OFFICE.centre.lat + 0.001, OFFICE.centre.lon)))
        assertEquals("r1", result.winner?.id)
        assertTrue(result.winnerVerdict!!.reason.contains("phone 111 m from the car"))
    }

    @Test
    fun `fails when the phone is elsewhere`() = runTest {
        val result = eval(FakeInputs(phone = HOME.centre))
        assertNull(result.winner)
        assertTrue(result.verdicts.single().reason, result.verdicts.single().reason.contains("km from the car"))
    }

    @Test
    fun `unknown phone location fails without reading the car`() = runTest {
        val inputs = FakeInputs(phone = null)
        val result = eval(inputs)
        assertNull(result.winner)
        assertTrue(result.verdicts.single().reason.contains("phone location unavailable"))
        assertEquals(0, inputs.vehicleReads)
        assertEquals("r1", eval(FakeInputs(phone = null), near.copy(proceedIfUnknown = true)).winner?.id)
    }

    @Test
    fun `unknown car position is unknown`() = runTest {
        val result = eval(FakeInputs(vehicleState = vehicle(position = null)))
        assertTrue(result.verdicts.single().reason.contains("car position unavailable"))
    }

    @Test
    fun `describes and validates`() {
        assertEquals("phone within 500 m of the car", Describe.condition(Condition.PhoneNearCar(500)) { it })
        assertEquals("phone within 1.5 km of the car", Describe.condition(Condition.PhoneNearCar(1500)) { it })
        assertEquals("2 km", Describe.distance(2000))
        assertTrue(RuleValidator.validate(near, setOf("office")).isEmpty())
        assertTrue(RuleValidator.validate(rule(conditions = listOf(Condition.PhoneNearCar(10))), setOf("office")).single().contains("50–20000 m"))
        val text = RuleJson.export(emptyList(), listOf(near))
        assertEquals(listOf(near), RuleJson.import(text, existingPlaceIds = setOf("office")).rules)
    }
}

class TempOutsideTest {
    private val outside = rule(conditions = listOf(Condition.TempOutside(16.0, 21.0, TempSource.WeatherAtCar)))

    private suspend fun eval(weather: Double?) = RuleEvaluator().evaluate(
        EvaluationRequest(TriggerEvent.GeofenceExited("office"), wednesdayAt(17), listOf(outside), PLACES, GuardSettings(), CooldownState(), { 16 }, FakeInputs(weather = weather)),
    )

    @Test
    fun `fires when cold or hot, not in between`() = runTest {
        assertEquals("r1", eval(10.0).winner?.id)
        assertTrue(eval(10.0).winnerVerdict!!.reason.contains("< 16.0 °C"))
        assertEquals("r1", eval(27.0).winner?.id)
        assertTrue(eval(27.0).winnerVerdict!!.reason.contains("> 21.0 °C"))
        val mild = eval(18.0)
        assertNull(mild.winner)
        assertTrue(mild.verdicts.single().reason.contains("within 16.0 °C–21.0 °C"))
        assertTrue(eval(null).verdicts.single().reason.contains("unavailable"))
    }

    @Test
    fun `describes, validates and serialises`() {
        assertEquals("weather at car below 16.0 °C or above 21.0 °C", Describe.condition(outside.conditions.single()) { it })
        assertTrue(RuleValidator.validate(outside, setOf("office")).isEmpty())
        val inverted = rule(conditions = listOf(Condition.TempOutside(21.0, 16.0, TempSource.WeatherAtCar)))
        assertTrue(RuleValidator.validate(inverted, setOf("office")).single().contains("lower limit"))
        assertEquals(listOf(outside), RuleJson.import(RuleJson.export(emptyList(), listOf(outside)), setOf("office")).rules)
    }

    @Test
    fun `below and above on the same source is rejected as impossible`() {
        val impossible = rule(conditions = listOf(Condition.TempBelow(16.0, TempSource.BestAvailable), Condition.TempAbove(21.0, TempSource.BestAvailable)))
        val problem = RuleValidator.validate(impossible, setOf("office")).single()
        assertTrue(problem, problem.contains("can never both be true") && problem.contains("outside a range"))
        // A real band ("between 5 and 16") is fine, as are different sources.
        val band = rule(conditions = listOf(Condition.TempBelow(16.0, TempSource.BestAvailable), Condition.TempAbove(5.0, TempSource.BestAvailable)))
        assertTrue(RuleValidator.validate(band, setOf("office")).isEmpty())
        val mixed = rule(conditions = listOf(Condition.TempBelow(16.0, TempSource.CabinBle), Condition.TempAbove(21.0, TempSource.WeatherAtCar)))
        assertTrue(RuleValidator.validate(mixed, setOf("office")).isEmpty())
    }
}
