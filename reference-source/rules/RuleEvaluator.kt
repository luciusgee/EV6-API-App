package app.elroq.precondition.rules

import java.time.Instant
import java.time.ZonedDateTime
import javax.inject.Inject

enum class Tri { PASS, FAIL, UNKNOWN }

data class Check(val name: String, val result: Tri, val detail: String) {
    override fun toString(): String = "$name: $detail"
}

data class RuleVerdict(
    val ruleId: String,
    val ruleName: String,
    val fired: Boolean,
    /** Why it fired, or the first check that stopped it. */
    val reason: String,
    val checks: List<Check>,
    /** The last temperature reading a condition used, for notifications ("leaving Office, 3 °C"). */
    val temperature: TempReading? = null,
)

data class Evaluation(
    val event: TriggerEvent,
    val at: Instant,
    /** Set when nothing was evaluated at all (paused, holiday, no rules for this trigger). */
    val globalSkip: String?,
    val verdicts: List<RuleVerdict>,
    val winner: Rule?,
) {
    val winnerVerdict: RuleVerdict? get() = winner?.let { w -> verdicts.firstOrNull { it.ruleId == w.id } }
}

data class EvaluationRequest(
    val event: TriggerEvent,
    val now: ZonedDateTime,
    val rules: List<Rule>,
    val places: Map<String, Place>,
    val guards: GuardSettings,
    val cooldowns: CooldownState,
    val budget: BudgetView,
    val inputs: EvaluationInputs,
    /** False for "test now" dry runs, which evaluate a rule regardless of whether its trigger matches. */
    val requireTriggerMatch: Boolean = true,
)

/**
 * Pure rule evaluation: no Android, no I/O except through [EvaluationInputs] and [BudgetView].
 *
 * Order per rule, cheapest first so the Škoda API is only read when everything else already passed:
 * cooldowns → free conditions (time, day) → rate budget → weather/BLE conditions →
 * vehicle conditions → vehicle guards (SoC, already running). The first rule to pass wins.
 */
class RuleEvaluator @Inject constructor() {

    suspend fun evaluate(req: EvaluationRequest): Evaluation {
        val at = req.now.toInstant()
        fun skip(reason: String) = Evaluation(req.event, at, reason, emptyList(), null)

        if (req.guards.automationPaused) return skip("automation paused")
        if (req.now.toLocalDate() in req.guards.holidays) return skip("holiday ${req.now.toLocalDate()}")

        val candidates = req.rules
            .filter { it.enabled }
            .filter { !req.requireTriggerMatch || it.trigger.matches(req.event, req.now.dayOfWeek) }
            .sortedWith(compareByDescending<Rule> { it.priority }.thenBy { it.name }.thenBy { it.id })
        if (candidates.isEmpty()) return skip("no enabled rules for this trigger")

        val verdicts = mutableListOf<RuleVerdict>()
        for (rule in candidates) {
            val verdict = RuleRun(rule, req).run()
            verdicts += verdict
            if (verdict.fired) return Evaluation(req.event, at, null, verdicts, rule)
        }
        return Evaluation(req.event, at, null, verdicts, null)
    }

    private enum class Tier { FREE, NETWORK, VEHICLE }

    private class RuleRun(val rule: Rule, val req: EvaluationRequest) {
        private val checks = mutableListOf<Check>()
        private var usedTemp: TempReading? = null
        private val inputs get() = req.inputs
        private val now get() = req.now

        suspend fun run(): RuleVerdict {
            if (!record(ruleCooldown())) return stopped()
            if (!record(globalCooldown())) return stopped()

            val byTier = rule.conditions.groupBy { tierOf(it) }
            for (c in byTier[Tier.FREE].orEmpty()) if (!record(evalCondition(c))) return stopped()

            if (!record(budgetCheck())) return stopped()

            for (c in byTier[Tier.NETWORK].orEmpty()) if (!record(evalCondition(c))) return stopped()
            for (c in byTier[Tier.VEHICLE].orEmpty()) if (!record(evalCondition(c))) return stopped()

            for (g in vehicleGuards()) if (!record(g)) return stopped()

            val conditionSummary = checks
                .filter { it.name.startsWith(CONDITION_PREFIX) }
                .joinToString("; ") { it.detail }
            val reason = if (conditionSummary.isEmpty()) "no conditions; guards passed" else conditionSummary
            return RuleVerdict(rule.id, rule.name, fired = true, reason = reason, checks = checks.toList(), temperature = usedTemp)
        }

        private fun stopped(): RuleVerdict {
            val last = checks.last()
            return RuleVerdict(rule.id, rule.name, fired = false, reason = last.toString(), checks = checks.toList(), temperature = usedTemp)
        }

        /** Records a check and returns whether evaluation may continue. */
        private fun record(check: Check): Boolean {
            checks += check
            return check.result == Tri.PASS
        }

        // ---- Guards -------------------------------------------------------------------------

        private fun ruleCooldown(): Check {
            val last = req.cooldowns.lastFiredByRule[rule.id]
            val until = last?.plusSeconds(rule.cooldownMinutes * 60L)
            return if (until != null && now.toInstant().isBefore(until)) {
                Check("rule cooldown", Tri.FAIL, "active until ${Describe.time(until.atZone(now.zone).toLocalTime())}")
            } else {
                Check("rule cooldown", Tri.PASS, "not active")
            }
        }

        private fun globalCooldown(): Check {
            val last = req.cooldowns.lastAutomatedCommandAt
            val until = last?.plusMillis(req.guards.globalCooldown.inWholeMilliseconds)
            return if (until != null && now.toInstant().isBefore(until)) {
                Check("global cooldown", Tri.FAIL, "active until ${Describe.time(until.atZone(now.zone).toLocalTime())}")
            } else {
                Check("global cooldown", Tri.PASS, "not active")
            }
        }

        private suspend fun budgetCheck(): Check {
            val needed = if (inputs.vehicleIfFree() != null) 1 else 2
            val available = req.budget.automationAvailable()
            return if (available >= needed) {
                Check("rate budget", Tri.PASS, "$available available, needs $needed")
            } else {
                Check("rate budget", Tri.FAIL, "only $available automation requests left, needs $needed")
            }
        }

        private suspend fun vehicleGuards(): List<Check> {
            val v = inputs.vehicle()
                ?: return listOf(Check("vehicle state", Tri.FAIL, "unavailable"))
            return when (rule.action) {
                is Action.StartClimate -> listOf(Guards.soc(v, req.guards.minSocPercent), Guards.notRunning(v))
                Action.StopClimate -> listOf(Guards.running(v))
            }
        }

        // ---- Conditions ---------------------------------------------------------------------

        private fun tierOf(c: Condition): Tier = when (c) {
            is Condition.TimeWindow, is Condition.DaysOfWeek -> Tier.FREE
            is Condition.SocAtLeast, is Condition.PluggedIn, is Condition.CarAtPlace, is Condition.PhoneNearCar -> Tier.VEHICLE
            is Condition.TempBelow -> tierOf(c.source)
            is Condition.TempAbove -> tierOf(c.source)
            is Condition.TempOutside -> tierOf(c.source)
        }

        private fun tierOf(s: TempSource): Tier = when (s) {
            TempSource.CabinBle -> Tier.NETWORK
            TempSource.CarOutside -> Tier.VEHICLE
            TempSource.WeatherAtCar, is TempSource.ForecastAt ->
                if (freeCarLocation() != null) Tier.NETWORK else Tier.VEHICLE
            // A car already known not to report outside temperature means weather is the answer.
            TempSource.BestAvailable -> {
                val cached = inputs.vehicleIfFree()
                if (cached != null && cached.outsideTempC == null && freeCarLocation() != null) Tier.NETWORK
                else Tier.VEHICLE
            }
        }

        private suspend fun evalCondition(c: Condition): Check {
            val label = CONDITION_PREFIX + Describe.condition(c) { placeName(it) }
            val (result, detail) = when (c) {
                is Condition.TimeWindow -> timeWindow(c)
                is Condition.DaysOfWeek -> {
                    val today = now.dayOfWeek
                    (if (today in c.days) Tri.PASS else Tri.FAIL) to "today is ${Describe.days(setOf(today))}"
                }
                is Condition.TempBelow -> temperature(c.source, c.celsius, below = true)
                is Condition.TempAbove -> temperature(c.source, c.celsius, below = false)
                is Condition.TempOutside -> temperatureOutside(c)
                is Condition.SocAtLeast -> {
                    val soc = inputs.vehicle()?.socPercent
                    when {
                        soc == null -> Tri.UNKNOWN to "SoC unknown"
                        soc >= c.percent -> Tri.PASS to "SoC $soc% ≥ ${c.percent}%"
                        else -> Tri.FAIL to "SoC $soc% < ${c.percent}%"
                    }
                }
                is Condition.PluggedIn -> {
                    val plugged = inputs.vehicle()?.pluggedIn
                    when (plugged) {
                        null -> Tri.UNKNOWN to "plug state unknown"
                        c.expected -> Tri.PASS to if (plugged) "plugged in" else "not plugged in"
                        else -> Tri.FAIL to if (plugged) "plugged in" else "not plugged in"
                    }
                }
                is Condition.CarAtPlace -> carAtPlace(c)
                is Condition.PhoneNearCar -> phoneNearCar(c)
            }
            return when {
                result == Tri.UNKNOWN && rule.proceedIfUnknown ->
                    Check(label, Tri.PASS, "$detail (unknown, proceeding as the rule allows)")
                result == Tri.UNKNOWN -> Check(label, Tri.UNKNOWN, detail)
                else -> Check(label, result, detail)
            }
        }

        private fun timeWindow(c: Condition.TimeWindow): Pair<Tri, String> {
            val t = now.toLocalTime()
            val inside = when {
                c.start == c.end -> true
                c.start < c.end -> !t.isBefore(c.start) && t.isBefore(c.end)
                else -> !t.isBefore(c.start) || t.isBefore(c.end)
            }
            return (if (inside) Tri.PASS else Tri.FAIL) to "now ${Describe.time(t)}"
        }

        private suspend fun temperature(source: TempSource, threshold: Double, below: Boolean): Pair<Tri, String> {
            val reading = readTemp(source)
                ?: return Tri.UNKNOWN to "${Describe.source(source)} unavailable"
            usedTemp = reading
            val ok = if (below) reading.celsius < threshold else reading.celsius > threshold
            val op = if (below) "<" else ">"
            val notOp = if (below) "≥" else "≤"
            val detail = "${Describe.temp(reading.celsius)} (${reading.source}) " +
                "${if (ok) op else notOp} ${Describe.temp(threshold)}"
            return (if (ok) Tri.PASS else Tri.FAIL) to detail
        }

        private suspend fun readTemp(source: TempSource): TempReading? = when (source) {
            TempSource.CarOutside -> inputs.vehicle()?.let { v ->
                v.outsideTempC?.let { TempReading(it, "car sensor", v.fetchedAt) }
            }
            TempSource.WeatherAtCar -> carLocation()?.let { (loc, where) ->
                inputs.weatherNow(loc)?.let { it.copy(source = "${it.source} at $where") }
            }
            is TempSource.ForecastAt -> carLocation()?.let { (loc, where) ->
                inputs.forecastAt(loc, forecastInstant(source))?.let { it.copy(source = "${it.source} at $where") }
            }
            TempSource.CabinBle -> inputs.cabinTemp()
            TempSource.BestAvailable -> {
                val cached = inputs.vehicleIfFree()
                val fromCar = if (cached != null && cached.outsideTempC == null) null else readTemp(TempSource.CarOutside)
                fromCar ?: readTemp(TempSource.WeatherAtCar)
            }
        }

        private suspend fun temperatureOutside(c: Condition.TempOutside): Pair<Tri, String> {
            val reading = readTemp(c.source)
                ?: return Tri.UNKNOWN to "${Describe.source(c.source)} unavailable"
            usedTemp = reading
            val t = reading.celsius
            val where = "${Describe.temp(t)} (${reading.source})"
            return when {
                t < c.low -> Tri.PASS to "$where < ${Describe.temp(c.low)}"
                t > c.high -> Tri.PASS to "$where > ${Describe.temp(c.high)}"
                else -> Tri.FAIL to "$where is within ${Describe.temp(c.low)}–${Describe.temp(c.high)}"
            }
        }

        /** Next occurrence of the forecast time; a time up to an hour ago still means today. */
        private fun forecastInstant(s: TempSource.ForecastAt): Instant {
            val today = now.with(s.time)
            val target = if (today.isBefore(now.minusHours(1))) today.plusDays(1) else today
            return target.toInstant()
        }

        private suspend fun carAtPlace(c: Condition.CarAtPlace): Pair<Tri, String> {
            val place = req.places[c.placeId] ?: return Tri.FAIL to "place ${c.placeId} no longer exists"
            val pos = inputs.vehicle()?.parkingPosition
                ?: return Tri.UNKNOWN to "parking position unavailable"
            val distance = place.centre.distanceTo(pos).toInt()
            return if (place.contains(pos)) Tri.PASS to "car $distance m from ${place.name}"
            else Tri.FAIL to "car $distance m from ${place.name} (radius ${place.radiusM} m)"
        }

        /** Phone first: it is free, and without it there is no point reading the car. */
        private suspend fun phoneNearCar(c: Condition.PhoneNearCar): Pair<Tri, String> {
            val phone = inputs.phoneLocation() ?: return Tri.UNKNOWN to "phone location unavailable"
            val car = inputs.vehicle()?.parkingPosition ?: return Tri.UNKNOWN to "car position unavailable"
            val d = phone.distanceTo(car).toInt()
            val detail = "phone ${Describe.distance(d)} from the car"
            return (if (d <= c.meters) Tri.PASS else Tri.FAIL) to detail
        }

        /** Car location without spending a Škoda request: cached position, else the place's parking spot. */
        private fun freeCarLocation(): Pair<LatLon, String>? {
            inputs.vehicleIfFree()?.parkingPosition?.let { return it to "car position" }
            return placeFallback()
        }

        private suspend fun carLocation(): Pair<LatLon, String>? {
            freeCarLocation()?.let { return it }
            return inputs.vehicle()?.parkingPosition?.let { it to "car position" }
        }

        /** The place the car is most likely at: a CarAtPlace condition's place, else the trigger's place. */
        private fun placeFallback(): Pair<LatLon, String>? {
            val ids = rule.conditions.filterIsInstance<Condition.CarAtPlace>().map { it.placeId } +
                listOfNotNull(rule.trigger.placeId)
            val place = ids.firstNotNullOfOrNull { req.places[it] } ?: return null
            val where = if (place.usualParkingSpot != null) "usual spot at ${place.name}" else place.name
            return place.parkingSpotOrCentre to where
        }

        private fun placeName(id: String): String = req.places[id]?.name ?: id

        private companion object {
            const val CONDITION_PREFIX = "condition "
        }
    }
}
