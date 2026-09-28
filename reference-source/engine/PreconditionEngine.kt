package app.elroq.precondition.engine

import app.elroq.precondition.api.ApiError
import app.elroq.precondition.api.ApiResult
import app.elroq.precondition.api.RateBudget
import app.elroq.precondition.api.RequestKind
import app.elroq.precondition.api.VehicleApi
import app.elroq.precondition.rules.Action
import app.elroq.precondition.rules.Describe
import app.elroq.precondition.rules.Evaluation
import app.elroq.precondition.rules.Geofences
import app.elroq.precondition.rules.EvaluationInputs
import app.elroq.precondition.rules.EvaluationRequest
import app.elroq.precondition.rules.Guards
import app.elroq.precondition.rules.LatLon
import app.elroq.precondition.rules.Rule
import app.elroq.precondition.rules.RuleEvaluator
import app.elroq.precondition.rules.TempReading
import app.elroq.precondition.rules.Tri
import app.elroq.precondition.rules.TriggerEvent
import app.elroq.precondition.rules.VehicleSnapshot
import app.elroq.precondition.rules.syntheticEvent
import app.elroq.precondition.weather.WeatherSource
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime

/** Where the worker is in its retry sequence. */
data class Attempt(
    val number: Int = 0,
    /** No further WorkManager retries will follow a network failure. */
    val isLast: Boolean = true,
    /** This run is the single retry after 429 vehicle-not-accepting-requests. */
    val vehicleBusyRetry: Boolean = false,
) {
    val isRetry: Boolean get() = number > 0 || vehicleBusyRetry
}

enum class Retry { NONE, BACKOFF, VEHICLE_BUSY }

sealed interface EngineOutcome {
    data class Skipped(val reason: String) : EngineOutcome
    data class Fired(val rule: Rule, val action: Action) : EngineOutcome
    data class Failed(val error: ApiError, val retry: Retry) : EngineOutcome
}

sealed interface ManualOutcome {
    data class Sent(val description: String) : ManualOutcome
    data class Refused(val reason: String) : ManualOutcome
    data class Failed(val error: ApiError) : ManualOutcome
}

/**
 * Every trigger ends up here. The engine loads rules and state, runs [RuleEvaluator], sends the
 * winning action through the car's [VehicleApi], and records the outcome — cooldowns, failure counts, log,
 * notification. Runs are serialised so two triggers never race on cooldowns or the budget.
 */
class PreconditionEngine(
    private val evaluator: RuleEvaluator,
    private val rules: RuleStore,
    private val places: PlaceStore,
    private val settings: SettingsSource,
    private val state: AutomationStateStore,
    private val vehicles: VehicleRepository,
    private val weather: WeatherSource,
    private val cabin: CabinSensor,
    private val phone: PhoneLocator,
    private val client: VehicleApi,
    private val budget: RateBudget,
    private val monitor: ApiMonitor,
    private val log: EventLog,
    private val notifier: Notifier,
    private val clock: Clock,
    private val zone: () -> ZoneId = { ZoneId.systemDefault() },
) {
    private val mutex = Mutex()

    suspend fun onTrigger(event: TriggerEvent, triggeredAt: Instant, attempt: Attempt = Attempt()): EngineOutcome =
        mutex.withLock { handle(event, triggeredAt, attempt) }

    private suspend fun handle(event: TriggerEvent, triggeredAt: Instant, attempt: Attempt): EngineOutcome {
        val now = clock.instant()
        val placeMap = places.places().associateBy { it.id }
        val label = Describe.event(event) { placeMap[it]?.name ?: it }

        suspend fun skip(reason: String, kind: LogKind = LogKind.SKIPPED): EngineOutcome {
            log.append(LogEntry(now, kind, "skipped", reason, trigger = label))
            return EngineOutcome.Skipped(reason)
        }

        val age = Duration.between(triggeredAt, now)
        if (age > STALE_AFTER) return skip("trigger is ${age.toMinutes()} min old; abandoned")

        val st = state.load()
        st.automationBlockedReason?.let { return skip(it) }

        val dedupKey = event.dedupKey
        if (dedupKey != null && !attempt.isRetry) {
            val last = st.lastTriggerAtMs[dedupKey]
            if (last != null && now.toEpochMilli() - last < DEDUP_WINDOW.toMillis()) {
                return skip("duplicate event within ${DEDUP_WINDOW.toMinutes()} min; ignored", LogKind.INFO)
            }
            state.update { it.copy(lastTriggerAtMs = it.lastTriggerAtMs + (dedupKey to now.toEpochMilli())) }
        }

        val inputs = EngineInputs.create(vehicles, weather, cabin, phone, RequestKind.AUTOMATION)
        val evaluation = evaluator.evaluate(
            EvaluationRequest(
                event = event,
                now = ZonedDateTime.ofInstant(now, zone()),
                rules = rules.rules(),
                places = placeMap,
                guards = settings.guards(),
                cooldowns = st.cooldowns(),
                budget = { budget.available(RequestKind.AUTOMATION) },
                inputs = inputs,
            ),
        )
        logEvaluation(evaluation, label, inputs.requestsMade, LogKind.FIRED)

        // A 401/403 during the state read has already stopped automation via ApiMonitor.
        inputs.vehicleError?.takeIf { it.isAuthFailure }?.let { return EngineOutcome.Failed(it, Retry.NONE) }

        val winner = evaluation.winner
        if (winner == null) {
            // The state read itself failed: retry or count it like a failed command.
            inputs.vehicleError?.let { return failure(it, null, attempt, label) }
            return EngineOutcome.Skipped(evaluation.globalSkip ?: evaluation.verdicts.lastOrNull()?.reason ?: "no rule passed")
        }
        return execute(winner, label, evaluation.winnerVerdict?.temperature, attempt)
    }

    private suspend fun execute(rule: Rule, label: String, temp: TempReading?, attempt: Attempt): EngineOutcome {
        val action = rule.action
        val result = send(action, RequestKind.AUTOMATION)
        val now = clock.instant()
        val description = Describe.action(action)

        return when (result) {
            is ApiResult.Success -> {
                state.update { s ->
                    s.copy(
                        lastAutomatedCommandAtMs = now.toEpochMilli(),
                        lastFiredByRuleMs = s.lastFiredByRuleMs + (rule.id to now.toEpochMilli()),
                        consecutiveFailures = 0,
                        lastCommand = LastCommand(now.toEpochMilli(), description, automated = true),
                    )
                }
                log.append(
                    LogEntry(now, LogKind.COMMAND, "sent", "$description accepted", label, rule.id, rule.name, result.meta.httpCode, 1),
                )
                val context = listOfNotNull(label, temp?.let { Describe.temp(it.celsius) }).joinToString(", ")
                val headline = when (action) {
                    is Action.StartClimate -> "Preconditioning to ${Describe.temp(action.targetC)}"
                    Action.StopClimate -> "Climatisation stopped"
                }
                notifier.commandSent(headline, "$headline — $context (${rule.name})", canStop = action is Action.StartClimate)
                EngineOutcome.Fired(rule, action)
            }
            is ApiResult.Failure -> {
                val requests = if (result.madeRequest) 1 else 0
                log.append(
                    LogEntry(now, LogKind.ERROR, "failed", "$description: ${result.error.message}", label, rule.id, rule.name, result.error.httpCode, requests),
                )
                failure(result.error, rule, attempt, label)
            }
        }
    }

    private suspend fun failure(error: ApiError, rule: Rule?, attempt: Attempt, label: String): EngineOutcome {
        val now = clock.instant()
        when {
            error.isAuthFailure -> return EngineOutcome.Failed(error, Retry.NONE)
            error is ApiError.OperationNotSupported || error is ApiError.OperationDisabled -> {
                if (rule != null) {
                    rules.disableRule(rule.id, error.message)
                    log.append(LogEntry(now, LogKind.ERROR, "rule disabled", "${rule.name} disabled: ${error.message}", label, rule.id, rule.name, error.httpCode))
                    notifier.problem("Rule disabled", "“${rule.name}” was disabled: ${error.message}.")
                }
                return EngineOutcome.Failed(error, Retry.NONE)
            }
            error is ApiError.VehicleNotAcceptingRequests && !attempt.vehicleBusyRetry -> {
                log.append(LogEntry(now, LogKind.INFO, "retrying", "vehicle not accepting requests; retrying once in 2 min", label, rule?.id, rule?.name, error.httpCode))
                return EngineOutcome.Failed(error, Retry.VEHICLE_BUSY)
            }
            error is ApiError.Network && !attempt.isLast -> {
                log.append(LogEntry(now, LogKind.INFO, "retrying", "${error.message}; will retry with backoff", label, rule?.id, rule?.name))
                return EngineOutcome.Failed(error, Retry.BACKOFF)
            }
            error is ApiError.BudgetExhausted || error is ApiError.NotConfigured -> return EngineOutcome.Failed(error, Retry.NONE)
        }

        // A final failure: count it, and pause automation after three in a row.
        val s = state.update { st ->
            val failures = st.consecutiveFailures + 1
            st.copy(consecutiveFailures = failures, pausedAfterFailures = st.pausedAfterFailures || failures >= MAX_CONSECUTIVE_FAILURES)
        }
        val what = rule?.let { "“${it.name}”" } ?: "Reading the car"
        notifier.problem("Preconditioning failed", "$what failed: ${error.message}.")
        if (s.pausedAfterFailures && s.consecutiveFailures == MAX_CONSECUTIVE_FAILURES) {
            log.append(LogEntry(now, LogKind.ERROR, "paused", "automation paused after $MAX_CONSECUTIVE_FAILURES consecutive failures", label))
            notifier.problem("Automation paused", "$MAX_CONSECUTIVE_FAILURES preconditioning attempts failed in a row. Resume it from the dashboard.")
        }
        return EngineOutcome.Failed(error, Retry.NONE)
    }

    /** "Test now": full evaluation of one rule, ignoring whether its trigger matches, without sending. */
    suspend fun dryRun(ruleId: String): Evaluation? {
        val rule = rules.rules().firstOrNull { it.id == ruleId } ?: return null
        return dryRun(rule)
    }

    /** Dry run of a rule that may not be saved yet (the editor's draft). */
    suspend fun dryRun(rule: Rule): Evaluation = mutex.withLock {
        val now = clock.instant()
        val placeMap = places.places().associateBy { it.id }
        val st = state.load()
        // Reading the car for a test is the user's own request, so it uses the manual budget.
        val inputs = EngineInputs.create(vehicles, weather, cabin, phone, RequestKind.MANUAL)
        val evaluation = evaluator.evaluate(
            EvaluationRequest(
                event = rule.trigger.syntheticEvent(),
                now = ZonedDateTime.ofInstant(now, zone()),
                rules = listOf(rule.copy(enabled = true)),
                places = placeMap,
                guards = settings.guards(),
                cooldowns = st.cooldowns(),
                budget = { budget.available(RequestKind.AUTOMATION) },
                inputs = inputs,
                requireTriggerMatch = false,
            ),
        )
        logEvaluation(evaluation, "test now", inputs.requestsMade, LogKind.DRY_RUN)
        evaluation
    }

    /** Manual start: SoC and rate-budget guards apply; cooldowns and pause do not. */
    suspend fun manualStart(targetC: Double? = null): ManualOutcome = mutex.withLock {
        val target = targetC ?: settings.defaultTargetC()
        manual(Action.StartClimate(target))
    }

    suspend fun manualStop(): ManualOutcome = mutex.withLock { manual(Action.StopClimate) }

    private suspend fun manual(action: Action): ManualOutcome {
        val now = clock.instant()
        val description = Describe.action(action)
        suspend fun refuse(reason: String): ManualOutcome {
            log.append(LogEntry(now, LogKind.MANUAL, "refused", "$description: $reason"))
            return ManualOutcome.Refused(reason)
        }

        var requests = 0
        if (action is Action.StartClimate) {
            var vehicle = vehicles.fresh()
            val needed = if (vehicle == null) 2 else 1
            if (budget.available(RequestKind.MANUAL) < needed) return refuse("rate budget exhausted")
            if (vehicle == null) {
                val fetched = vehicles.fetch(RequestKind.MANUAL)
                if (fetched.madeRequest) requests++
                vehicle = (fetched as? ApiResult.Success)?.value
                    ?: return refuse("vehicle state unavailable: ${(fetched as ApiResult.Failure).error.message}")
            }
            val soc = Guards.soc(vehicle, settings.guards().minSocPercent)
            if (soc.result != Tri.PASS) return refuse(soc.detail)
        } else if (budget.available(RequestKind.MANUAL) < 1) {
            return refuse("rate budget exhausted")
        }

        val result = send(action, RequestKind.MANUAL)
        if (result.madeRequest) requests++
        return when (result) {
            is ApiResult.Success -> {
                state.update { it.copy(lastCommand = LastCommand(now.toEpochMilli(), description, automated = false)) }
                log.append(LogEntry(now, LogKind.MANUAL, "sent", "$description accepted", httpCode = result.meta.httpCode, requestsUsed = requests))
                if (action is Action.StartClimate) {
                    notifier.commandSent("Preconditioning to ${Describe.temp(action.targetC)}", "Started manually", canStop = true)
                }
                ManualOutcome.Sent(description)
            }
            is ApiResult.Failure -> {
                log.append(LogEntry(now, LogKind.MANUAL, "failed", "$description: ${result.error.message}", httpCode = result.error.httpCode, requestsUsed = requests))
                ManualOutcome.Failed(result.error)
            }
        }
    }

    /** Dashboard refresh; a user action, so it draws on the manual budget. */
    suspend fun refreshVehicle(): ApiResult<VehicleSnapshot> {
        val result = vehicles.fetch(RequestKind.MANUAL)
        if (result is ApiResult.Failure) {
            log.append(LogEntry(clock.instant(), LogKind.MANUAL, "refresh failed", result.error.message, httpCode = result.error.httpCode, requestsUsed = if (result.madeRequest) 1 else 0))
        }
        return result
    }

    /**
     * Keeps the parked position fresh for "near the car" rules: reads the car (automation budget) when
     * such a rule is enabled and the cached state is older than [maxAge]. Returns true if it read the car.
     */
    suspend fun refreshCarPositionIfDue(maxAge: Duration = POSITION_MAX_AGE): Boolean = mutex.withLock {
        if (!Geofences.needsCarPosition(rules.rules())) return@withLock false
        if (state.load().automationBlockedReason != null) return@withLock false
        val cached = vehicles.cached()
        if (cached != null && Duration.between(cached.fetchedAt, clock.instant()) < maxAge) return@withLock false
        if (budget.available(RequestKind.AUTOMATION) < POSITION_REFRESH_MIN_BUDGET) return@withLock false
        val result = vehicles.fetch(RequestKind.AUTOMATION)
        val requests = if (result.madeRequest) 1 else 0
        val (decision, reason) = when (result) {
            is ApiResult.Success -> "position" to when {
                result.value.parkingPosition == null -> "car position unavailable; near-car rules can't fire"
                result.value.parked == false -> "car is moving; near-car fence paused"
                else -> "car position refreshed for near-car rules"
            }
            is ApiResult.Failure -> "position failed" to "car position refresh failed: ${result.error.message}"
        }
        log.append(LogEntry(clock.instant(), LogKind.INFO, decision, reason, httpCode = result.meta?.httpCode, requestsUsed = requests))
        result is ApiResult.Success
    }

    suspend fun resumeAutomation() {
        state.update { it.copy(pausedAfterFailures = false, consecutiveFailures = 0) }
        log.append(LogEntry(clock.instant(), LogKind.INFO, "resumed", "automation resumed by user"))
    }

    private suspend fun send(action: Action, kind: RequestKind): ApiResult<Unit> = when (action) {
        is Action.StartClimate -> client.startClimate(action.targetC, kind, settings.climateWithoutExternalPower())
        Action.StopClimate -> client.stopClimate(kind)
    }

    private suspend fun logEvaluation(evaluation: Evaluation, label: String, requests: Int, firedKind: LogKind) {
        val at = evaluation.at
        evaluation.globalSkip?.let {
            log.append(LogEntry(at, if (firedKind == LogKind.DRY_RUN) LogKind.DRY_RUN else LogKind.SKIPPED, "skipped", it, label, requestsUsed = requests))
            return
        }
        evaluation.verdicts.forEachIndexed { i, v ->
            val kind = when {
                firedKind == LogKind.DRY_RUN -> LogKind.DRY_RUN
                v.fired -> LogKind.FIRED
                else -> LogKind.SKIPPED
            }
            val decision = when {
                firedKind == LogKind.DRY_RUN && v.fired -> "would fire"
                firedKind == LogKind.DRY_RUN -> "would skip"
                v.fired -> "fired"
                else -> "skipped"
            }
            log.append(
                LogEntry(
                    at = at,
                    kind = kind,
                    decision = decision,
                    reason = v.reason,
                    trigger = label,
                    ruleId = v.ruleId,
                    ruleName = v.ruleName,
                    // Requests are attributed to the last rule evaluated, where the cycle stopped.
                    requestsUsed = if (i == evaluation.verdicts.lastIndex) requests else 0,
                    details = v.checks.joinToString("\n") { "${it.result} ${it.name}: ${it.detail}" },
                ),
            )
        }
    }

    companion object {
        val STALE_AFTER: Duration = Duration.ofMinutes(30)
        val DEDUP_WINDOW: Duration = Duration.ofMinutes(5)
        const val MAX_CONSECUTIVE_FAILURES = 3
        val POSITION_MAX_AGE: Duration = Duration.ofHours(3)

        /** Leave room for a full precondition cycle (read + command) after a position refresh. */
        const val POSITION_REFRESH_MIN_BUDGET = 3
    }
}

/** [EvaluationInputs] backed by the repositories, memoising the vehicle read for one evaluation. */
internal class EngineInputs private constructor(
    private val vehicles: VehicleRepository,
    private val weather: WeatherSource,
    private val cabin: CabinSensor,
    private val phone: PhoneLocator,
    private val kind: RequestKind,
    private var vehicle: VehicleSnapshot?,
) : EvaluationInputs {
    private var phoneLocated = false
    private var phoneFix: LatLon? = null
    private var attempted = false
    var requestsMade = 0
        private set
    var vehicleError: ApiError? = null
        private set

    override fun vehicleIfFree(): VehicleSnapshot? = vehicle

    override suspend fun vehicle(): VehicleSnapshot? {
        vehicle?.let { return it }
        if (attempted) return null
        attempted = true
        val result = vehicles.fetch(kind)
        if (result.madeRequest) requestsMade++
        return when (result) {
            is ApiResult.Success -> result.value.also { vehicle = it }
            is ApiResult.Failure -> {
                vehicleError = result.error
                null
            }
        }
    }

    override suspend fun weatherNow(at: LatLon): TempReading? = weather.current(at)

    override suspend fun forecastAt(at: LatLon, time: Instant): TempReading? = weather.forecastAt(at, time)

    override suspend fun cabinTemp(): TempReading? = cabin.read()

    override suspend fun phoneLocation(): LatLon? {
        if (!phoneLocated) {
            phoneLocated = true
            phoneFix = phone.locate()
        }
        return phoneFix
    }

    companion object {
        suspend fun create(vehicles: VehicleRepository, weather: WeatherSource, cabin: CabinSensor, phone: PhoneLocator, kind: RequestKind) =
            EngineInputs(vehicles, weather, cabin, phone, kind, vehicles.fresh())
    }
}
