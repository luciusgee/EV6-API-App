package app.elroq.precondition.api

import app.elroq.precondition.rules.ClimateState
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import java.time.Instant

class VehicleMapperTest {
    private val json = SkodaClient.defaultJson

    private fun map(text: String) = json.parseToJsonElement(text).let {
        VehicleMapper.toSnapshot(json.decodeFromJsonElement(VehicleResponseDto.serializer(), it), it, Instant.EPOCH)
    }

    @Test
    fun `climate states`() {
        fun state(s: String) = map("""{"vehicle": {"airConditioning": {"state": "$s"}}}""").climate
        listOf("HEATING", "COOLING", "HEATING_AUXILIARY", "VENTILATION").forEach { assertEquals(it, ClimateState.RUNNING, state(it)) }
        listOf("OFF", "COMPLETED").forEach { assertEquals(it, ClimateState.OFF, state(it)) }
        listOf("UNKNOWN", "UNSUPPORTED", "SOMETHING_NEW").forEach { assertEquals(it, ClimateState.UNKNOWN, state(it)) }
    }

    @Test
    fun `plug state from charging state`() {
        fun plugged(s: String) = map("""{"vehicle": {"charging": {"status": {"state": "$s"}}}}""").pluggedIn
        assertEquals(false, plugged("CONNECT_CABLE"))
        listOf("CHARGING", "CONSERVING", "READY_FOR_CHARGING", "DISCHARGING", "CHARGING_INTERRUPTED").forEach { assertEquals(true, plugged(it)) }
        assertNull(plugged("NEW_STATE"))
        assertNull(map("""{"vehicle": {}}""").pluggedIn)
    }

    @Test
    fun `fahrenheit targets are converted`() {
        val v = map("""{"vehicle": {"airConditioning": {"state": "HEATING", "targetTemperature": {"value": 70.7, "unit": "FAHRENHEIT"},
            "estimatedReachOfTargetTemperatureAt": "2026-09-23T15:20:00Z"}}}""")
        assertEquals(21.5, v.targetTempC!!, 0.01)
        assertEquals(Instant.parse("2026-09-23T15:20:00Z").toEpochMilli(), v.targetReachedAtEpochMs)
    }

    @Test
    fun `finds an outside temperature field if the car ever reports one`() {
        assertEquals(4.5, map("""{"vehicle": {"airConditioning": {"state": "OFF", "outsideTemperature": {"value": 4.5, "unit": "CELSIUS"}}}}""").outsideTempC!!, 0.0)
        assertEquals(-2.0, map("""{"vehicle": {"status": [{"ambientTemperatureCelsius": -2}]}}""").outsideTempC!!, 0.0)
        assertNull(map(SkodaClientTest.FULL_VEHICLE).outsideTempC)
        assertNull(map("""{"vehicle": {"airConditioning": {"targetTemperature": {"value": 21}}}}""").outsideTempC)
    }

    @Test
    fun `range and charging details`() {
        val charging = map("""{"vehicle": {"charging": {"status": {"state": "CHARGING", "chargePowerInKw": 11.0,
            "remainingTimeToFullyChargedInMinutes": 95, "battery": {"stateOfChargeInPercent": 55, "remainingCruisingRangeInMeters": 231400}}}}}""")
        assertEquals(231, charging.rangeKm)
        assertEquals(11.0, charging.chargePowerKw!!, 0.0)
        assertEquals(95, charging.minutesToFullyCharged)
        val idle = map("""{"vehicle": {"charging": {"status": {"state": "READY_FOR_CHARGING", "chargePowerInKw": 0.0, "remainingTimeToFullyChargedInMinutes": 0}}}}""")
        assertNull(idle.chargePowerKw)
        assertNull(idle.minutesToFullyCharged)
    }

    @Test
    fun `parked or moving`() {
        assertEquals(true, map("""{"vehicle": {"parkingPosition": {"state": "PARKED"}}}""").parked)
        assertEquals(false, map("""{"vehicle": {"parkingPosition": {"state": "IN_MOTION"}}}""").parked)
        assertNull(map("""{"vehicle": {}}""").parked)
    }

    @Test
    fun `empty response is all unknown`() {
        val v = map("{}")
        assertNull(v.socPercent)
        assertEquals(ClimateState.UNKNOWN, v.climate)
        assertTrue(v.unavailable.isEmpty())
    }
}

class FakeCarTest {
    private val clock = MutableClock()
    private val fake = FakeCar(clock)
    private val budget = RateBudget(MemoryBudgetStore(), clock) { BudgetConfig() }

    private val client = SkodaClient(
        Retrofit.Builder()
            .baseUrl(SkodaApiService.BASE_URL)
            .client(OkHttpClient.Builder().addInterceptor(fake).build())
            .addConverterFactory(Json.asConverterFactory("application/json".toMediaType()))
            .build()
            .create(SkodaApiService::class.java),
        budget, { Credentials(TEST_KEY, TEST_VIN) }, RecordingMetaSink(), clock,
    )

    @Test
    fun `fake car behaves like the real API`() = runTest {
        val v = (client.getVehicle(RequestKind.MANUAL) as ApiResult.Success).value.snapshot
        assertEquals(62, v.socPercent)
        assertEquals(ClimateState.OFF, v.climate)
        assertTrue(client.startClimate(22.0, RequestKind.MANUAL) is ApiResult.Success)
        assertEquals("HEATING", fake.state.climateState)
        assertEquals(22.0, fake.state.targetTempC, 0.0)
        assertTrue(client.stopClimate(RequestKind.MANUAL) is ApiResult.Success)
        assertEquals("OFF", fake.state.climateState)
        fake.state = fake.state.copy(pluggedIn = true, charging = true)
        val charging = (client.getVehicle(RequestKind.MANUAL) as ApiResult.Success).value.snapshot
        assertEquals(7.2, charging.chargePowerKw!!, 0.0)
        assertEquals(228, charging.minutesToFullyCharged)
        assertEquals(260, charging.rangeKm)
        assertEquals(16, budget.snapshot().remaining)
        assertTrue(budget.snapshot().fromServer)
    }

    @Test
    fun `fake car scenarios produce the matching errors`() = runTest {
        fun scenario(s: FakeScenario) { fake.state = fake.state.copy(scenario = s) }
        scenario(FakeScenario.KEY_EXPIRED)
        assertTrue((client.getVehicle(RequestKind.MANUAL) as ApiResult.Failure).error is ApiError.KeyExpired)
        scenario(FakeScenario.KEY_NOT_AUTHORIZED)
        assertTrue((client.getVehicle(RequestKind.MANUAL) as ApiResult.Failure).error is ApiError.KeyNotAuthorized)
        scenario(FakeScenario.VEHICLE_BUSY)
        assertTrue((client.startClimate(21.0, RequestKind.MANUAL) as ApiResult.Failure).error is ApiError.VehicleNotAcceptingRequests)
        scenario(FakeScenario.NOT_SUPPORTED)
        assertTrue((client.startClimate(21.0, RequestKind.MANUAL) as ApiResult.Failure).error is ApiError.OperationNotSupported)
        assertTrue(client.getVehicle(RequestKind.MANUAL) is ApiResult.Success)
        scenario(FakeScenario.SERVER_ERROR)
        assertTrue((client.getVehicle(RequestKind.MANUAL) as ApiResult.Failure).error is ApiError.Server)
        scenario(FakeScenario.PARTIAL)
        val partial = (client.getVehicle(RequestKind.MANUAL) as ApiResult.Success).value.snapshot
        assertNull(partial.parkingPosition)
        assertEquals(listOf("PARKING_POSITION_UNAVAILABLE"), partial.unavailable)
        scenario(FakeScenario.RATE_LIMITED)
        assertTrue((client.getVehicle(RequestKind.MANUAL) as ApiResult.Failure).error is ApiError.RateLimited)
    }

    @Test
    fun `fake car enforces its own limit`() = runTest {
        fake.state = fake.state.copy(limit = 2)
        assertTrue(client.getVehicle(RequestKind.MANUAL) is ApiResult.Success)
        // Remaining is now 1; the client's budget honours it and the next call reaches the limit.
        assertTrue(client.getVehicle(RequestKind.MANUAL) is ApiResult.Success)
        assertEquals(ApiError.BudgetExhausted(RequestKind.MANUAL), (client.getVehicle(RequestKind.MANUAL) as ApiResult.Failure).error)
    }
}
