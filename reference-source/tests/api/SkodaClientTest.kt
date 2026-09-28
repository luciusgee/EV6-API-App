package app.elroq.precondition.api

import app.elroq.precondition.rules.ClimateState
import app.elroq.precondition.rules.LatLon
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlin.time.Duration.Companion.seconds

class SkodaClientTest {
    private val server = MockWebServer()
    private val clock = MutableClock()
    private val store = MemoryBudgetStore()
    private val budget = RateBudget(store, clock) { BudgetConfig() }
    private val sink = RecordingMetaSink()
    private var creds: Credentials? = Credentials(TEST_KEY, TEST_VIN)
    private lateinit var client: SkodaClient

    @Before
    fun setUp() {
        server.start()
        val http = OkHttpClient.Builder().readTimeout(2, TimeUnit.SECONDS).build()
        val service = Retrofit.Builder()
            .baseUrl(server.url("/"))
            .client(http)
            .addConverterFactory(SkodaClient.defaultJson.asConverterFactory("application/json".toMediaType()))
            .build()
            .create(SkodaApiService::class.java)
        client = SkodaClient(service, budget, { creds }, sink, clock)
    }

    @After
    fun tearDown() = server.shutdown()

    private fun rateHeaders(r: MockResponse, remaining: Int = 17) = r
        .addHeader("RateLimit-Limit", "20")
        .addHeader("RateLimit-Remaining", remaining.toString())
        .addHeader("RateLimit-Reset", "1800")
        .addHeader("X-API-Key-Expires-At", "2026-12-01T00:00:00Z")

    @Test
    fun `reads vehicle state and sends the key`() = runTest {
        server.enqueue(rateHeaders(MockResponse().setBody(FULL_VEHICLE)))
        val result = client.getVehicle(RequestKind.AUTOMATION) as ApiResult.Success
        val v = result.value.snapshot

        assertEquals(72, v.socPercent)
        assertEquals(true, v.pluggedIn)
        assertEquals(ClimateState.OFF, v.climate)
        assertEquals(21.5, v.targetTempC)
        assertEquals(LatLon(50.08, 14.42), v.parkingPosition)
        assertEquals(null, v.outsideTempC)
        assertEquals(Instant.parse("2026-09-23T14:55:00Z").toEpochMilli(), v.carCapturedAtEpochMs)
        assertTrue(result.value.rawJson.contains("airConditioning"))

        val request = server.takeRequest()
        assertEquals("/api/v1/vehicles/$TEST_VIN?include=airConditioning%2Ccharging%2CparkingPosition", request.path)
        assertEquals(TEST_KEY, request.getHeader("X-API-Key"))

        assertEquals(Instant.parse("2026-12-01T00:00:00Z"), sink.seen.single().first.apiKeyExpiresAt)
        assertEquals(17, budget.snapshot().remaining)
    }

    @Test
    fun `partial 200 marks missing sections unknown, not failed`() = runTest {
        server.enqueue(rateHeaders(MockResponse().setBody(PARTIAL_VEHICLE)))
        val v = (client.getVehicle(RequestKind.AUTOMATION) as ApiResult.Success).value.snapshot
        assertNull(v.parkingPosition)
        assertEquals(ClimateState.UNKNOWN, v.climate)
        assertEquals(40, v.socPercent)
        assertEquals(false, v.pluggedIn)
        assertEquals(listOf("PARKING_POSITION_UNSUPPORTED", "AIR_CONDITIONING_UNAVAILABLE"), v.unavailable)
    }

    @Test
    fun `start sends target temperature rounded to half a degree`() = runTest {
        server.enqueue(rateHeaders(MockResponse().setResponseCode(202)))
        val result = client.startClimate(21.3, RequestKind.AUTOMATION, withoutExternalPower = false)
        assertTrue(result is ApiResult.Success)
        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/api/v1/vehicles/$TEST_VIN/air-conditioning/start", request.path)
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals(21.5, body["targetTemperature"]!!.jsonObject["value"]!!.jsonPrimitive.double, 0.0)
        assertEquals("CELSIUS", body["targetTemperature"]!!.jsonObject["unit"]!!.jsonPrimitive.content)
        assertEquals("false", body["airConditioningWithoutExternalPower"]!!.jsonPrimitive.content)
    }

    @Test
    fun `stop posts to the stop command`() = runTest {
        server.enqueue(MockResponse().setResponseCode(202))
        assertTrue(client.stopClimate(RequestKind.MANUAL) is ApiResult.Success)
        assertEquals("/api/v1/vehicles/$TEST_VIN/air-conditioning/stop", server.takeRequest().path)
    }

    @Test
    fun `401 key expired`() = runTest {
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"type":"api-key-expired"}"""))
        val result = client.getVehicle(RequestKind.AUTOMATION) as ApiResult.Failure
        assertTrue(result.error is ApiError.KeyExpired)
        assertTrue(sink.seen.single().second!!.isAuthFailure)
        assertEquals(20, budget.snapshot().remaining) // 401 does not count
    }

    @Test
    fun `403 key not authorised`() = runTest {
        server.enqueue(MockResponse().setResponseCode(403).setBody("""{"type":"api-key-not-authorized"}"""))
        val result = client.startClimate(21.0, RequestKind.AUTOMATION) as ApiResult.Failure
        assertEquals(ApiError.KeyNotAuthorized(403, "api-key-not-authorized"), result.error)
        assertEquals(20, budget.snapshot().remaining)
    }

    @Test
    fun `422 operation not supported`() = runTest {
        server.enqueue(MockResponse().setResponseCode(422).setBody("""{"type":"operation-not-supported"}"""))
        val result = client.startClimate(21.0, RequestKind.AUTOMATION) as ApiResult.Failure
        assertTrue(result.error is ApiError.OperationNotSupported)
    }

    @Test
    fun `429 rate limit honours retry-after and exhausts the budget`() = runTest {
        server.enqueue(
            rateHeaders(MockResponse().setResponseCode(429).setBody("""{"type":"rate-limit-exceeded"}"""), remaining = 0)
                .addHeader("Retry-After", "600"),
        )
        val result = client.getVehicle(RequestKind.AUTOMATION) as ApiResult.Failure
        assertEquals(ApiError.RateLimited(600.seconds), result.error)
        assertEquals(clock.instant().plusSeconds(1800), budget.snapshot().exhaustedUntil)
        // The next call is refused locally without touching the network.
        assertEquals(ApiError.BudgetExhausted(RequestKind.MANUAL), (client.getVehicle(RequestKind.MANUAL) as ApiResult.Failure).error)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `429 vehicle not accepting requests`() = runTest {
        server.enqueue(MockResponse().setResponseCode(429).setBody("""{"type":"vehicle-not-accepting-requests"}"""))
        val result = client.startClimate(21.0, RequestKind.AUTOMATION) as ApiResult.Failure
        assertTrue(result.error is ApiError.VehicleNotAcceptingRequests)
        assertNull(budget.snapshot().exhaustedUntil)
    }

    @Test
    fun `5xx counts against the budget`() = runTest {
        server.enqueue(MockResponse().setResponseCode(500))
        val result = client.getVehicle(RequestKind.AUTOMATION) as ApiResult.Failure
        assertEquals(ApiError.Server(500, null), result.error)
        assertEquals(19, budget.snapshot().remaining)
    }

    @Test
    fun `network failure is reported and still counted`() = runTest {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
        val result = client.getVehicle(RequestKind.AUTOMATION) as ApiResult.Failure
        assertTrue(result.error is ApiError.Network)
        assertNull(result.meta)
        assertEquals(19, budget.snapshot().remaining)
    }

    @Test
    fun `unreadable body is a bad response`() = runTest {
        server.enqueue(MockResponse().setBody("{not json"))
        assertTrue((client.getVehicle(RequestKind.AUTOMATION) as ApiResult.Failure).error is ApiError.BadResponse)
    }

    @Test
    fun `no credentials means no request`() = runTest {
        creds = null
        assertEquals(ApiError.NotConfigured, (client.getVehicle(RequestKind.MANUAL) as ApiResult.Failure).error)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `exhausted automation budget refuses without a request`() = runTest {
        store.state = RateBudgetState(limit = 20, remaining = 4, resetAtEpochMs = clock.millis() + 60_000, observedAtEpochMs = clock.millis())
        assertEquals(ApiError.BudgetExhausted(RequestKind.AUTOMATION), (client.getVehicle(RequestKind.AUTOMATION) as ApiResult.Failure).error)
        assertEquals(0, server.requestCount)
        server.enqueue(MockResponse().setBody(FULL_VEHICLE))
        assertTrue(client.getVehicle(RequestKind.MANUAL) is ApiResult.Success)
    }

    companion object {
        val FULL_VEHICLE = """
            {"vehicle": {
              "vin": "$TEST_VIN", "name": "Elroq",
              "airConditioning": {"state": "OFF", "targetTemperature": {"value": 21.5, "unit": "CELSIUS"},
                "airConditioningWithoutExternalPower": true, "carCapturedTimestamp": "2026-09-23T14:50:00Z",
                "windowHeating": {"front": "OFF", "rear": "OFF"}},
              "charging": {"isVehicleInSavedLocation": true, "carCapturedTimestamp": "2026-09-23T14:55:00Z",
                "status": {"state": "READY_FOR_CHARGING", "battery": {"stateOfChargeInPercent": 72, "remainingCruisingRangeInMeters": 301000}}},
              "parkingPosition": {"state": "PARKED", "gpsCoordinates": {"latitude": 50.08, "longitude": 14.42}, "formattedAddress": "Praha"}
            }, "errors": []}
        """.trimIndent()

        val PARTIAL_VEHICLE = """
            {"vehicle": {"vin": "$TEST_VIN",
              "charging": {"isVehicleInSavedLocation": false, "status": {"state": "CONNECT_CABLE", "battery": {"stateOfChargeInPercent": 40}}}},
             "errors": [{"type": "PARKING_POSITION_UNSUPPORTED", "description": "needs licence"},
                        {"type": "AIR_CONDITIONING_UNAVAILABLE", "description": "try later"}]}
        """.trimIndent()
    }
}
