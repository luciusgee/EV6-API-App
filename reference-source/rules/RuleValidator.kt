package app.elroq.precondition.rules

object RuleValidator {
    const val MIN_TARGET_C = 16.0
    const val MAX_TARGET_C = 30.0
    const val MIN_CAR_RADIUS_M = 100
    const val MAX_CAR_RADIUS_M = 5000
    const val MIN_PHONE_DISTANCE_M = 50
    const val MAX_PHONE_DISTANCE_M = 20_000

    /** Returns a list of problems; empty means the rule is valid. */
    fun validate(rule: Rule, placeIds: Set<String>): List<String> = buildList {
        if (rule.id.isBlank()) add("id is empty")
        if (rule.name.isBlank()) add("name is empty")
        if (rule.cooldownMinutes < 0) add("cooldownMinutes must not be negative")

        fun checkPlace(id: String, what: String) {
            if (id !in placeIds) add("$what refers to unknown place '$id'")
        }

        when (val t = rule.trigger) {
            is Trigger.GeofenceExit -> checkPlace(t.placeId, "trigger")
            is Trigger.GeofenceEnter -> checkPlace(t.placeId, "trigger")
            is Trigger.Approaching -> {
                checkPlace(t.placeId, "trigger")
                if (t.km <= 0 || t.km > 100) add("approaching distance must be between 0 and 100 km")
            }
            is Trigger.Schedule -> if (t.days.isEmpty()) add("schedule has no days")
            is Trigger.NearCar -> if (t.meters !in MIN_CAR_RADIUS_M..MAX_CAR_RADIUS_M) {
                add("distance to the car must be $MIN_CAR_RADIUS_M–$MAX_CAR_RADIUS_M m")
            }
        }

        rule.conditions.forEach { c ->
            when (c) {
                is Condition.TimeWindow -> if (c.start == c.end) add("time window start and end are equal")
                is Condition.DaysOfWeek -> if (c.days.isEmpty()) add("days condition has no days")
                is Condition.TempBelow -> checkTemp(c.celsius)
                is Condition.TempAbove -> checkTemp(c.celsius)
                is Condition.TempOutside -> {
                    checkTemp(c.low)
                    checkTemp(c.high)
                    if (c.low >= c.high) add("temperature range: the lower limit must be below the upper limit")
                }
                is Condition.SocAtLeast -> if (c.percent !in 0..100) add("SoC must be 0–100%")
                is Condition.PluggedIn -> Unit
                is Condition.CarAtPlace -> checkPlace(c.placeId, "car-at-place condition")
                is Condition.PhoneNearCar -> if (c.meters !in MIN_PHONE_DISTANCE_M..MAX_PHONE_DISTANCE_M) {
                    add("phone-near-car distance must be $MIN_PHONE_DISTANCE_M–$MAX_PHONE_DISTANCE_M m")
                }
            }
        }

        // Conditions are all required (AND). "Below X" with "above Y ≥ X" on the same source can never pass.
        val below = rule.conditions.filterIsInstance<Condition.TempBelow>()
        val above = rule.conditions.filterIsInstance<Condition.TempAbove>()
        for (b in below) for (a in above) {
            if (a.source == b.source && a.celsius >= b.celsius) {
                add(
                    "“below ${Describe.temp(b.celsius)}” and “above ${Describe.temp(a.celsius)}” can never both be true — " +
                        "all conditions must pass. Use “temperature outside a range” instead.",
                )
            }
        }

        when (val a = rule.action) {
            is Action.StartClimate -> if (a.targetC !in MIN_TARGET_C..MAX_TARGET_C) {
                add("target temperature must be ${MIN_TARGET_C.toInt()}–${MAX_TARGET_C.toInt()} °C")
            }
            Action.StopClimate -> Unit
        }
    }

    fun validatePlace(place: Place): List<String> = buildList {
        if (place.id.isBlank()) add("id is empty")
        if (place.name.isBlank()) add("name is empty")
        if (place.radiusM !in Place.MIN_RADIUS_M..Place.MAX_RADIUS_M) {
            add("radius must be ${Place.MIN_RADIUS_M}–${Place.MAX_RADIUS_M} m")
        }
        if (place.centre.lat !in -90.0..90.0 || place.centre.lon !in -180.0..180.0) add("centre is not a valid coordinate")
    }

    private fun MutableList<String>.checkTemp(c: Double) {
        if (c !in -40.0..50.0) add("temperature threshold must be between -40 and 50 °C")
    }
}
