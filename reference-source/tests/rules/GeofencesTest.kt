package app.elroq.precondition.rules

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GeofencesTest {

    @Test
    fun `registers only what enabled rules need`() {
        val rules = listOf(
            rule("a", trigger = Trigger.GeofenceExit("office")),
            rule("b", trigger = Trigger.GeofenceEnter("office")),
            rule("c", trigger = Trigger.Approaching("home", 5.0)),
            rule("d", trigger = Trigger.Approaching("home", 5.0)),
            rule("e", trigger = Trigger.GeofenceEnter("home"), enabled = false),
            rule("f", trigger = Trigger.Approaching("gone", 1.0)),
            rule("g", trigger = Trigger.Schedule(WEEKDAYS, java.time.LocalTime.NOON)),
        )
        val specs = Geofences.required(rules, listOf(OFFICE, HOME)).associateBy { it.id }
        assertEquals(setOf("place:office", "approach:home:5.0"), specs.keys)
        assertEquals(GeofenceSpec("place:office", OFFICE.centre, 200f, enter = true, exit = true), specs["place:office"])
        assertEquals(GeofenceSpec("approach:home:5.0", HOME.centre, 5000f, enter = true, exit = false), specs["approach:home:5.0"])
    }

    @Test
    fun `maps fired geofences back to events`() {
        assertEquals(TriggerEvent.GeofenceExited("office"), Geofences.eventFor("place:office", Transition.EXIT))
        assertEquals(TriggerEvent.GeofenceEntered("office"), Geofences.eventFor("place:office", Transition.ENTER))
        assertEquals(TriggerEvent.Approached("home", 5.0), Geofences.eventFor("approach:home:5.0", Transition.ENTER))
        assertNull(Geofences.eventFor("approach:home:5.0", Transition.EXIT))
        assertNull(Geofences.eventFor("approach:bad", Transition.ENTER))
        assertNull(Geofences.eventFor("other", Transition.ENTER))
    }

    @Test
    fun `round trip from rule to event matches the rule`() {
        val r = rule(trigger = Trigger.Approaching("home", 2.5))
        val spec = Geofences.required(listOf(r), listOf(HOME)).single()
        val event = Geofences.eventFor(spec.id, Transition.ENTER)!!
        assertEquals(true, r.trigger.matches(event, java.time.DayOfWeek.MONDAY))
    }
}
