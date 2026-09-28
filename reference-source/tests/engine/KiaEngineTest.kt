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
import app.elroq.precondition.api.kia.FakeKia
import app.elroq.precondition.api.kia.InMemoryKiaSessionStore
import app.elroq.precondition.api.kia.KiaClient
import app.elroq.precondition.rules.HOME
import app.elroq.precondition.rules.LatLon
import app.elroq.precondition.rules.OFFICE
import app.elroq.precondition.rules.PRAGUE
import app.elroq.precondition.rules.Place
import app.elroq.precondition.rules.RuleEvaluator
import app.elroq.precondition.rules.Templates
import app.elroq.precondition.rules.TriggerEvent
import app.elroq.precondition.rules.wednesdayAt
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.hours

/** The same engine, rules and guards, driving a Kia through [KiaClient] against the Kia simulator. */
class KiaEngineTest {
    private val clock = MutableClock(wednesdayAt(17, 10).toInstant())
    private val fakeCar = FakeCar(clock, FakeCarState(latitude = OFFICE.centre.lat, longitude = OFFICE.centre.lon))
    private val budgetStore = MemoryBudgetStore()
    private val budget = RateBudget(budgetStore, clock) { BudgetConfig(fallbackLimit = 80, manualReserve = 8, window = 24.hours) }
    private val state = MemoryState()
    private val log = MemoryLog()
    private val notifier = RecordingNotifier()
    private val monitor = ApiMonitor(state, notifier, log, clock, authHelp = "Paste a new refresh token in Settings.") { PRAGUE }
    private val creds = Credentials("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCDEFGHIJKL", "", pin = "1234")
    private val sessions = InMemoryKiaSessionStore()
    private val client = KiaClient(OkHttpClient.Builder().addInterceptor(FakeKia(fakeCar, clock)).build(), budget, { creds }, sessions, monitor, clock)
    private val cache = MemoryVehicleCache()
    private val vehicles = VehicleRepository(client, cache, state, { creds }, log, clock)
    private val rules = MemoryRules(mutableListOf(Templates.leavingWork("office", id = "leave")))
    private val settings = MemorySettings()
    private val weather = FixedWeather()
    private val places = object : PlaceStore {
        override suspend fun places(): List<Place> = listOf(OFFICE, HOME)
    }
    private var phoneAt: LatLon? = OFFICE.centre
    private val engine = PreconditionEngine(
        RuleEvaluator(), rules, places, settings, state, vehicles, weather, { null }, { phoneAt }, client, budget, monitor, log, notifier, clock,
    ) { PRAGUE }

    private suspend fun trigger() = engine.onTrigger(TriggerEvent.GeofenceExited("office"), clock.instant(), Attempt())

    @Test
    fun `leaving the office on a cold evening heats the Kia`() = runTest {
        val outcome = trigger()
        assertTrue(outcome.toString(), outcome is EngineOutcome.Fired)
        assertEquals("HEATING", fakeCar.state.climateState)
        assertEquals(21.0, fakeCar.state.targetTempC, 0.0)
        assertEquals(2, log.entries.sumOf { it.requestsUsed })
        assertEquals(2, budgetStore.state.sent.count { it.kind == RequestKind.AUTOMATION })
        assertNotNull(sessions.session?.deviceId)
    }

    @Test
    fun `guards still apply to the Kia`() = runTest {
        fakeCar.state = fakeCar.state.copy(socPercent = 20)
        assertTrue(trigger() is EngineOutcome.Skipped)
        assertEquals("OFF", fakeCar.state.climateState)
    }

    @Test
    fun `the rule stays quiet when the phone is not with the car`() = runTest {
        phoneAt = HOME.centre
        assertTrue(trigger() is EngineOutcome.Skipped)
        assertEquals("OFF", fakeCar.state.climateState)
    }

    @Test
    fun `a rejected Kia login stops automation with Kia instructions`() = runTest {
        fakeCar.state = fakeCar.state.copy(scenario = FakeScenario.KEY_EXPIRED)
        val outcome = trigger()
        assertTrue(outcome is EngineOutcome.Failed && (outcome as EngineOutcome.Failed).error is ApiError.LoginFailed)
        assertNotNull(state.state.authFailure)
        assertTrue(notifier.problems.single().contains("Paste a new refresh token in Settings."))

        fakeCar.state = fakeCar.state.copy(scenario = FakeScenario.NONE)
        assertTrue(engine.refreshVehicle() is ApiResult.Success)
        assertNull(state.state.authFailure)
    }

    @Test
    fun `a busy car is retried later rather than failing the rule`() = runTest {
        cache.snapshot = (vehicles.fetch(RequestKind.MANUAL) as ApiResult.Success).value
        fakeCar.state = fakeCar.state.copy(scenario = FakeScenario.VEHICLE_BUSY)
        val outcome = trigger()
        assertTrue(outcome.toString(), outcome is EngineOutcome.Failed && (outcome as EngineOutcome.Failed).retry != Retry.NONE)
    }

    @Test
    fun `manual stop reaches the car`() = runTest {
        fakeCar.state = fakeCar.state.copy(climateState = "HEATING")
        assertTrue(engine.manualStop() is ManualOutcome.Sent)
        assertEquals("OFF", fakeCar.state.climateState)
    }
}
