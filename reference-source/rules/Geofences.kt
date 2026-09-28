package app.elroq.precondition.rules

/** A geofence to register with Play Services. Pure data so the mapping can be unit-tested. */
data class GeofenceSpec(
    val id: String,
    val centre: LatLon,
    val radiusM: Float,
    val enter: Boolean,
    val exit: Boolean,
)

enum class Transition { ENTER, EXIT }

/**
 * Which geofences the enabled rules need, and how a fired geofence maps back to a [TriggerEvent].
 *
 * Places get one fence with the transitions their rules use. "Approaching X km" rules get a separate,
 * larger ENTER-only fence per distinct distance — no continuous location tracking.
 */
object Geofences {
    private const val PLACE = "place:"
    private const val APPROACH = "approach:"
    private const val CAR = "car:"

    /**
     * @param carPosition where the car is parked, for "near the car" rules. Null (unknown, or the car is
     *   moving) registers no car fences.
     */
    fun required(rules: List<Rule>, places: List<Place>, carPosition: LatLon? = null): List<GeofenceSpec> {
        val byId = places.associateBy { it.id }
        val triggers = rules.filter { it.enabled }.map { it.trigger }

        val placeFences = byId.values.mapNotNull { place ->
            val enter = triggers.any { it is Trigger.GeofenceEnter && it.placeId == place.id }
            val exit = triggers.any { it is Trigger.GeofenceExit && it.placeId == place.id }
            if (!enter && !exit) null
            else GeofenceSpec(PLACE + place.id, place.centre, place.radiusM.toFloat(), enter, exit)
        }
        val approachFences = triggers.filterIsInstance<Trigger.Approaching>()
            .distinct()
            .mapNotNull { t ->
                val place = byId[t.placeId] ?: return@mapNotNull null
                GeofenceSpec(approachId(t.placeId, t.km), place.centre, (t.km * 1000).toFloat(), enter = true, exit = false)
            }
        val carFences = if (carPosition == null) emptyList() else triggers.filterIsInstance<Trigger.NearCar>()
            .map { it.meters }
            .distinct()
            .map { m -> GeofenceSpec("$CAR$m", carPosition, m.toFloat(), enter = true, exit = false) }
        return placeFences + approachFences + carFences
    }

    /** Whether any enabled rule needs the car's position kept fresh. */
    fun needsCarPosition(rules: List<Rule>): Boolean = rules.any { it.enabled && it.trigger is Trigger.NearCar }

    fun eventFor(geofenceId: String, transition: Transition): TriggerEvent? = when {
        geofenceId.startsWith(PLACE) -> {
            val placeId = geofenceId.removePrefix(PLACE)
            if (transition == Transition.ENTER) TriggerEvent.GeofenceEntered(placeId) else TriggerEvent.GeofenceExited(placeId)
        }
        geofenceId.startsWith(CAR) && transition == Transition.ENTER ->
            geofenceId.removePrefix(CAR).toIntOrNull()?.let { TriggerEvent.ApproachedCar(it) }
        geofenceId.startsWith(APPROACH) && transition == Transition.ENTER -> {
            val rest = geofenceId.removePrefix(APPROACH)
            val sep = rest.lastIndexOf(':')
            val km = rest.substring(sep + 1).toDoubleOrNull()
            if (sep <= 0 || km == null) null else TriggerEvent.Approached(rest.substring(0, sep), km)
        }
        else -> null
    }

    private fun approachId(placeId: String, km: Double) = "$APPROACH$placeId:$km"
}
