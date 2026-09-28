package app.elroq.precondition.engine

import app.elroq.precondition.api.ApiError
import app.elroq.precondition.api.ApiResult
import app.elroq.precondition.api.BudgetConfig
import app.elroq.precondition.api.Credentials
import app.elroq.precondition.api.FakeCar
import app.elroq.precondition.api.FakeCarState
import app.elroq.precondition.api.FakeScenario
import app.elroq.precondition.api.MemoryBudgetStore
import app.elroq.precondition.api.MutableClock
import app.elroq.precondition.api.RateBudget
import app.elroq.precondition.api.RequestKind
import app.elroq.precondition.api.SkodaApiService
import app.elroq.precondition.api.SkodaClient
import app.elroq.precondition.api.TEST_KEY
import app.elroq.precondition.api.TEST_VIN
import app.elroq.precondition.rules.Action
import app.elroq.precondition.rules.GuardSettings
import app.elroq.precondition.rules.LatLon
import app.elroq.precondition.rules.OFFICE
import app.elroq.precondition.rules.HOME
import app.elroq.precondition.rules.PRAGUE
import app.elroq.precondition.rules.Place
import app.elroq.precondition.rules.Rule
import app.elroq.precondition.rules.RuleEvaluator
import app.elroq.precondition.rules.TempReading
import app.elroq.precondition.rules.Templates
import app.elroq.precondition.rules.TriggerEvent
import app.elroq.precondition.rules.VehicleSnapshot
import app.elroq.precondition.rules.rule
import app.elroq.precondition.rules.wednesdayAt
import app.elroq.precondition.weather.WeatherSource
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import java.io.IOException
import java.time.Instant

class MemoryRules(var list: MutableList<Rule>) : RuleStore {
    val disabled = mutableMapOf<String, String>()
    override suspend fun rules() = list.toList()
    override suspend fun disableRule(id: String, reason: String) {
        disabled[id] = reason
        list = list.map { if (it.id == id) it.copy(enabled = false) else it }.toMutableList()
    }
}

class MemorySettings(var guards: GuardSettings = GuardSettings()) : SettingsSource {
    override suspend fun guards() = guards
    override suspend fun defaultTargetC() = 21.0
    override suspend fun climateWithoutExternalPower() = true
}

class MemoryState(var state: AutomationState = AutomationState()) : AutomationStateStore {
    override suspend fun load() = state
    override suspend fun update(transform: (AutomationState) -> AutomationState) = transform(state).also { state = it }
}

class MemoryVehicleCache(var snapshot: VehicleSnapshot? = null) : VehicleCacheStore {
    override suspend fun load() = snapshot
    override suspend fun save(snapshot: VehicleSnapshot) {
        this.snapshot = snapshot
    }
}

class MemoryLog : EventLog {
    val entries = mutableListOf<LogEntry>()
    override suspend fun append(entry: LogEntry) {
        entries += entry
    }
}

class RecordingNotifier : Notifier {
    val sent = mutableListOf<String>()
    val problems = mutableListOf<String>()
    override suspend fun commandSent(title: String, text: String, canStop: Boolean) {
        sent += text
    }
    override suspend fun problem(title: String, text: String, openSettings: Boolean) {
        problems += "$title: $text"
    }
}

class FixedWeather(var celsius: Double? = 3.0) : WeatherSource {
    var calls = 0
    override suspend fun current(at: LatLon) = celsius?.let { calls++; TempReading(it, "Open-Meteo", Instant.EPOCH) }
    override suspend fun forecastAt(at: LatLon, time: Instant) = current(at)
}

/**
 * The engine against the fake car: the real client, budget, error mapping and evaluator, with only
 * the network replaced. The tests follow the spec's acceptance criteria.
 */
class PreconditionEngineTest {
    private val clock = MutableClock(wednesdayAt(17, 10).toInstant())
    private val fakeCar = FakeCar(clock, FakeCarState(latitude = OFFICE.centre.lat, longitude = OFFICE.centre.lon))
    private var networkDown = false
    private val budgetStore = MemoryBudgetStore()
    private val budget = RateBudget(budgetStore, clock) { BudgetConfig() }
    private val state = MemoryState()
    private val log = MemoryLog()
    private val notifier = RecordingNotifier()
    private val monitor = ApiMonitor(state, notifier, log, clock) { PRAGUE }
    private val creds = Credentials(TEST_KEY, TEST_VIN)
    private val offline = Interceptor { chain -> if (networkDown) throw IOException("no network") else chain.proceed(chain.request()) }
    private val client = SkodaClient(
        Retrofit.Builder()
            .baseUrl(SkodaApiService.BASE_URL)
            .client(OkHttpClient.Builder().addInterceptor(offline).addInterceptor(fakeCar).build())
            .addConverterFactory(Json.asConverterFactory("application/json".toMediaType()))
            .build()
            .create(SkodaApiService::class.java),
        budget, { creds }, monitor, clock,
    )
    private val cache = MemoryVehicleCache()
    private val vehicles = VehicleRepository(client, cache, state, { creds }, log, clock)
    private val rules = MemoryRules(mutableListOf(Templates.leavingWork("office", id = "leave")))
    private val settings = MemorySettings()
    private val weather = FixedWeather()
    /** Where the phone is; next to the fake car by default. */
    private var phoneAt: LatLon? = OFFICE.centre
    private val places = object : PlaceStore {
        override suspend fun places(): List<Place> = listOf(OFFICE, HOME)
    }
    private val engine = PreconditionEngine(
        RuleEvaluator(), rules, places, settings, state, vehicles, weather, { null }, { phoneAt }, client, budget, monitor, log, notifier, clock,
    ) { PRAGUE }

    private val exitOffice = TriggerEvent.GeofenceExited("office")

    private suspend fun trigger(event: TriggerEvent = exitOffice, attempt: Attempt = Attempt()) =
        engine.onTrigger(event, clock.instant(), attempt)

    // ---- Acceptance: leaving the office below 5 °C starts heating ---------------------------

    @Test
    fun `leaving the office on a cold weekday evening starts heating`() = runTest {
        val outcome = trigger()
        assertTrue(outcome.toString(), outcome is EngineOutcome.Fired)
        assertEquals("HEATING", fakeCar.state.climateState)
        assertEquals(21.0, fakeCar.state.targetTempC, 0.0)
        assertEquals(listOf("Preconditioning to 21.0 °C — left Office, 3.0 °C (Leaving work)"), notifier.sent)
        assertEquals(2, log.entries.sumOf { it.requestsUsed })
        assertTrue(log.entries.any { it.kind == LogKind.FIRED && it.ruleId == "leave" })
        assertTrue(log.entries.any { it.kind == LogKind.COMMAND && it.httpCode == 202 })
        assertNotNull(state.state.lastFiredByRuleMs["leave"])
        assertEquals(clock.millis(), state.state.lastAutomatedCommandAtMs)
    }

    @Test
    fun `first vehicle response is logged once with the VIN masked`() = runTest {
        trigger()
        clock.advanceSeconds(3600)
        engine.refreshVehicle()
        val dumps = log.entries.filter { it.decision == "first vehicle response" }
        assertEquals(1, dumps.size)
        assertFalse(dumps.single().details!!.contains(FakeCar.FAKE_VIN))
        assertTrue(dumps.single().details!!.contains("0001"))
    }

    // ---- Acceptance: guards are never bypassed and each case is logged -----------------------

    @Test
    fun `no command when SoC is below the minimum`() = runTest {
        fakeCar.state = fakeCar.state.copy(socPercent = 20)
        assertTrue(trigger() is EngineOutcome.Skipped)
        assertEquals("OFF", fakeCar.state.climateState)
        assertTrue(log.entries.any { it.kind == LogKind.SKIPPED && it.reason.contains("SoC 20% below minimum 25%") })
        assertTrue(notifier.sent.isEmpty())
    }

    @Test
    fun `no command when climate is already on`() = runTest {
        fakeCar.state = fakeCar.state.copy(climateState = "HEATING")
        assertTrue(trigger() is EngineOutcome.Skipped)
        assertTrue(log.entries.any { it.reason.contains("already running") })
    }

    @Test
    fun `no command while a cooldown is active`() = runTest {
        assertTrue(trigger() is EngineOutcome.Fired)
        fakeCar.state = fakeCar.state.copy(climateState = "OFF")
        clock.advanceSeconds(6 * 60) // past the dedup window, inside the global cooldown
        assertTrue(trigger() is EngineOutcome.Skipped)
        assertTrue(log.entries.last().reason.contains("cooldown"))
        clock.advanceSeconds(20 * 60) // past global, inside the rule's 60 min
        assertTrue(trigger() is EngineOutcome.Skipped)
        assertTrue(log.entries.last().reason.contains("rule cooldown"))
    }

    // ---- Acceptance: automation never uses more than limit − 4 ------------------------------

    @Test
    fun `automation never uses more than limit minus four in a window`() = runTest {
        // A rule that always passes and never cools down, triggered far more often than the budget allows.
        rules.list = mutableListOf(rule("spam", cooldownMinutes = 0))
        settings.guards = GuardSettings(globalCooldown = kotlin.time.Duration.ZERO)
        repeat(40) {
            fakeCar.state = fakeCar.state.copy(climateState = "OFF")
            cache.snapshot = null // force a state read every time
            clock.advanceSeconds(60)
            engine.onTrigger(TriggerEvent.GeofenceExited("office"), clock.instant(), Attempt(vehicleBusyRetry = true))
        }
        val automationRequests = budgetStore.state.sent.count { it.kind == RequestKind.AUTOMATION }
        assertEquals(16, automationRequests)
        assertEquals(16, log.entries.sumOf { it.requestsUsed })
        assertTrue(log.entries.any { it.reason.contains("rate budget") })
        // The manual reserve is intact.
        assertEquals(4, budget.available(RequestKind.MANUAL))
        assertTrue(engine.manualStop() is ManualOutcome.Sent)
    }

    // ---- Acceptance: an expired key stops automation within one attempt ----------------------

    @Test
    fun `an expired API key stops automation and notifies`() = runTest {
        fakeCar.state = fakeCar.state.copy(scenario = FakeScenario.KEY_EXPIRED)
        val outcome = trigger()
        assertTrue(outcome is EngineOutcome.Failed && (outcome as EngineOutcome.Failed).error is ApiError.KeyExpired)
        assertEquals(Retry.NONE, (outcome as EngineOutcome.Failed).retry)
        assertEquals("API key expired", state.state.authFailure)
        assertEquals(1, notifier.problems.size)
        assertTrue(notifier.problems.single().startsWith("Automation stopped"))

        // Later triggers don't even try.
        fakeCar.state = fakeCar.state.copy(scenario = FakeScenario.NONE)
        clock.advanceSeconds(600)
        val next = trigger(TriggerEvent.GeofenceExited("home"))
        assertTrue(next is EngineOutcome.Skipped)
        assertTrue((next as EngineOutcome.Skipped).reason.startsWith("automation stopped"))
        assertEquals(1, notifier.problems.size)

        // A successful manual request proves a new key works and resumes automation.
        assertTrue(engine.refreshVehicle() is ApiResult.Success)
        assertNull(state.state.authFailure)
    }

    @Test
    fun `a key rejected on the command also stops automation`() = runTest {
        cache.snapshot = (vehicles.fetch(RequestKind.MANUAL) as ApiResult.Success).value
        fakeCar.state = fakeCar.state.copy(scenario = FakeScenario.KEY_NOT_AUTHORIZED)
        assertTrue(trigger() is EngineOutcome.Failed)
        assertNotNull(state.state.authFailure)
    }

    // ---- Error handling ---------------------------------------------------------------------

    @Test
    fun `unsupported operation disables the rule`() = runTest {
        fakeCar.state = fakeCar.state.copy(scenario = FakeScenario.NOT_SUPPORTED)
        assertTrue(trigger() is EngineOutcome.Failed)
        assertTrue(rules.disabled.containsKey("leave"))
        assertTrue(notifier.problems.single().startsWith("Rule disabled"))
    }

    @Test
    fun `vehicle busy retries once then gives up`() = runTest {
        cache.snapshot = (vehicles.fetch(RequestKind.MANUAL) as ApiResult.Success).value
        fakeCar.state = fakeCar.state.copy(scenario = FakeScenario.VEHICLE_BUSY)
        val first = trigger() as EngineOutcome.Failed
        assertEquals(Retry.VEHICLE_BUSY, first.retry)
        assertEquals(0, state.state.consecutiveFailures)

        clock.advanceSeconds(120)
        val second = trigger(attempt = Attempt(vehicleBusyRetry = true)) as EngineOutcome.Failed
        assertEquals(Retry.NONE, second.retry)
        assertEquals(1, state.state.consecutiveFailures)
    }

    @Test
    fun `network failure asks for a backoff retry until the last attempt`() = runTest {
        networkDown = true
        val first = trigger(attempt = Attempt(number = 0, isLast = false)) as EngineOutcome.Failed
        assertEquals(Retry.BACKOFF, first.retry)
        networkDown = false
        clock.advanceSeconds(30)
        assertTrue(trigger(attempt = Attempt(number = 1, isLast = false)) is EngineOutcome.Fired)
    }

    @Test
    fun `network failure on the last attempt is final`() = runTest {
        networkDown = true
        val outcome = trigger(attempt = Attempt(number = 2, isLast = true)) as EngineOutcome.Failed
        assertEquals(Retry.NONE, outcome.retry)
        assertEquals(1, state.state.consecutiveFailures)
        assertTrue(notifier.problems.single().contains("Reading the car failed"))
    }

    @Test
    fun `three consecutive failures pause automation`() = runTest {
        cache.snapshot = (vehicles.fetch(RequestKind.MANUAL) as ApiResult.Success).value
        rules.list = mutableListOf(rule("r", cooldownMinutes = 0))
        settings.guards = GuardSettings(globalCooldown = kotlin.time.Duration.ZERO)
        fakeCar.state = fakeCar.state.copy(scenario = FakeScenario.SERVER_ERROR)
        repeat(3) {
            clock.advanceSeconds(360)
            trigger()
        }
        assertTrue(state.state.pausedAfterFailures)
        assertTrue(notifier.problems.last().startsWith("Automation paused"))

        fakeCar.state = fakeCar.state.copy(scenario = FakeScenario.NONE)
        clock.advanceSeconds(360)
        assertTrue((trigger() as EngineOutcome.Skipped).reason.contains("paused after 3"))

        engine.resumeAutomation()
        clock.advanceSeconds(360)
        assertTrue(trigger() is EngineOutcome.Fired)
        assertEquals(0, state.state.consecutiveFailures)
    }

    // ---- Trigger handling -------------------------------------------------------------------

    @Test
    fun `repeated geofence events within five minutes are ignored`() = runTest {
        rules.list = mutableListOf(rule("r", conditions = listOf(app.elroq.precondition.rules.Condition.TempBelow(-20.0, app.elroq.precondition.rules.TempSource.WeatherAtCar))))
        trigger()
        clock.advanceSeconds(120)
        val second = trigger() as EngineOutcome.Skipped
        assertTrue(second.reason.contains("duplicate"))
        clock.advanceSeconds(200)
        assertFalse((trigger() as EngineOutcome.Skipped).reason.contains("duplicate"))
    }

    @Test
    fun `stale triggers are abandoned`() = runTest {
        val outcome = engine.onTrigger(exitOffice, clock.instant().minusSeconds(31 * 60)) as EngineOutcome.Skipped
        assertTrue(outcome.reason.contains("abandoned"))
        assertEquals(0, budgetStore.state.sent.size)
    }

    @Test
    fun `skipped rules cost no requests when cheap checks fail`() = runTest {
        clock.now = wednesdayAt(12).toInstant()
        assertTrue(trigger() is EngineOutcome.Skipped)
        assertEquals(0, budgetStore.state.sent.size)
    }

    @Test
    fun `fresh cache saves the state read`() = runTest {
        cache.snapshot = (vehicles.fetch(RequestKind.MANUAL) as ApiResult.Success).value
        clock.advanceSeconds(300)
        trigger()
        assertEquals(1, budgetStore.state.sent.count { it.kind == RequestKind.AUTOMATION })
    }

    // ---- Dry run and manual commands --------------------------------------------------------

    @Test
    fun `test now evaluates without sending`() = runTest {
        clock.now = wednesdayAt(17, 30).toInstant()
        val evaluation = engine.dryRun("leave")!!
        assertEquals("leave", evaluation.winner?.id)
        assertEquals("OFF", fakeCar.state.climateState)
        assertTrue(log.entries.any { it.kind == LogKind.DRY_RUN && it.decision == "would fire" })
        assertTrue(budgetStore.state.sent.all { it.kind == RequestKind.MANUAL })
        assertNull(engine.dryRun("missing"))
    }

    @Test
    fun `manual start ignores cooldowns but not the SoC guard`() = runTest {
        state.state = state.state.copy(lastAutomatedCommandAtMs = clock.millis())
        assertTrue(engine.manualStart(22.0) is ManualOutcome.Sent)
        assertEquals(22.0, fakeCar.state.targetTempC, 0.0)
        assertEquals("climatise to 22.0 °C", state.state.lastCommand?.description)

        fakeCar.state = fakeCar.state.copy(socPercent = 10)
        cache.snapshot = null
        val refused = engine.manualStart() as ManualOutcome.Refused
        assertTrue(refused.reason.contains("below minimum"))
    }

    @Test
    fun `manual commands respect the rate budget`() = runTest {
        // The fake car allows one request this hour, and the budget already knows it.
        fakeCar.state = fakeCar.state.copy(limit = 1)
        budgetStore.state = budgetStore.state.copy(limit = 1, remaining = 1, resetAtEpochMs = clock.millis() + 600_000, observedAtEpochMs = clock.millis())
        assertEquals(ManualOutcome.Refused("rate budget exhausted"), engine.manualStart())
        assertTrue(engine.manualStop() is ManualOutcome.Sent)
        assertEquals(ManualOutcome.Refused("rate budget exhausted"), engine.manualStop())
    }

    @Test
    fun `manual failures are reported`() = runTest {
        fakeCar.state = fakeCar.state.copy(scenario = FakeScenario.VEHICLE_BUSY)
        assertTrue(engine.manualStop() is ManualOutcome.Failed)
        assertTrue(engine.manualStart() is ManualOutcome.Refused)
    }

    @Test
    fun `stop rules stop climatisation`() = runTest {
        rules.list = mutableListOf(rule("stop", trigger = app.elroq.precondition.rules.Trigger.GeofenceEnter("home"), action = Action.StopClimate))
        fakeCar.state = fakeCar.state.copy(climateState = "HEATING")
        assertTrue(trigger(TriggerEvent.GeofenceEntered("home")) is EngineOutcome.Fired)
        assertEquals("OFF", fakeCar.state.climateState)
        assertEquals("Climatisation stopped — arrived at Home (stop)", notifier.sent.single())
    }

    // ---- Phone near the car ------------------------------------------------------------------

    @Test
    fun `leaving work is skipped when the phone is not with the car`() = runTest {
        phoneAt = LatLon(48.2, 16.4) // Vienna; the car is at the office in Prague
        assertTrue(trigger() is EngineOutcome.Skipped)
        assertEquals("OFF", fakeCar.state.climateState)
        assertTrue(log.entries.any { it.reason.contains("phone within 1.5 km of the car") && it.reason.contains("km from the car") })
    }

    @Test
    fun `morning commute is skipped on holiday with the car at home`() = runTest {
        fakeCar.state = fakeCar.state.copy(latitude = HOME.centre.lat, longitude = HOME.centre.lon)
        rules.list = mutableListOf(Templates.morningCommute("home", id = "morning"))
        clock.now = wednesdayAt(7, 20).toInstant()
        weather.celsius = -2.0
        val event = TriggerEvent.ScheduleFired(java.time.LocalTime.of(7, 20))

        phoneAt = LatLon(28.1, -15.4) // Gran Canaria
        assertTrue(trigger(event) is EngineOutcome.Skipped)

        phoneAt = HOME.centre
        clock.advanceSeconds(60)
        assertTrue(trigger(event) is EngineOutcome.Fired)
    }

    // ---- Near-car position refresh ------------------------------------------------------------

    @Test
    fun `car position is refreshed only when a near-car rule needs it`() = runTest {
        assertFalse(engine.refreshCarPositionIfDue())
        assertEquals(0, budgetStore.state.sent.size)

        rules.list = mutableListOf(rule("near", trigger = app.elroq.precondition.rules.Trigger.NearCar(300)))
        assertTrue(engine.refreshCarPositionIfDue())
        assertEquals(RequestKind.AUTOMATION, budgetStore.state.sent.single().kind)
        assertEquals(true, cache.snapshot!!.parked)
        assertTrue(log.entries.any { it.reason == "car position refreshed for near-car rules" && it.requestsUsed == 1 })

        // Fresh enough: no second read.
        clock.advanceSeconds(3600)
        assertFalse(engine.refreshCarPositionIfDue())
        clock.advanceSeconds(2 * 3600 + 1)
        assertTrue(engine.refreshCarPositionIfDue())
        assertEquals(2, log.entries.count { it.decision == "position" && it.requestsUsed == 1 })
    }

    @Test
    fun `position refresh leaves room for a precondition cycle and respects a stop`() = runTest {
        rules.list = mutableListOf(rule("near", trigger = app.elroq.precondition.rules.Trigger.NearCar(300)))
        budgetStore.state = budgetStore.state.copy(limit = 20, remaining = 6, resetAtEpochMs = clock.millis() + 600_000, observedAtEpochMs = clock.millis())
        assertFalse(engine.refreshCarPositionIfDue()) // only 2 automation requests left
        budgetStore.state = app.elroq.precondition.api.RateBudgetState()
        state.state = state.state.copy(authFailure = "API key expired")
        assertFalse(engine.refreshCarPositionIfDue())
        assertEquals(0, budgetStore.state.sent.size)
    }

    @Test
    fun `failed position refresh is logged`() = runTest {
        rules.list = mutableListOf(rule("near", trigger = app.elroq.precondition.rules.Trigger.NearCar(300)))
        fakeCar.state = fakeCar.state.copy(scenario = FakeScenario.SERVER_ERROR)
        assertFalse(engine.refreshCarPositionIfDue())
        assertTrue(log.entries.last().reason.startsWith("car position refresh failed"))
    }

    @Test
    fun `approaching the car fires its rule`() = runTest {
        rules.list = mutableListOf(rule("near", trigger = app.elroq.precondition.rules.Trigger.NearCar(300)))
        assertTrue(trigger(TriggerEvent.ApproachedCar(300)) is EngineOutcome.Fired)
        assertEquals("HEATING", fakeCar.state.climateState)
    }

    // ---- Key expiry -------------------------------------------------------------------------

    @Test
    fun `warns once when the key expires within seven days`() = runTest {
        monitor.onResponse(
            app.elroq.precondition.api.ResponseMeta(200, clock.instant(), apiKeyExpiresAt = clock.instant().plusSeconds(10 * 86400)),
            null,
        )
        assertTrue(notifier.problems.isEmpty())
        clock.advanceSeconds(4 * 86400)
        monitor.checkKeyExpiry()
        monitor.checkKeyExpiry()
        assertEquals(1, notifier.problems.size)
        assertTrue(notifier.problems.single().startsWith("API key expiring"))
    }
}
