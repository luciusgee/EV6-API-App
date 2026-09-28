package app.elroq.precondition.api.kia

import app.elroq.precondition.api.ApiError
import app.elroq.precondition.api.ApiResult
import app.elroq.precondition.api.BudgetConfig
import app.elroq.precondition.api.Credentials
import app.elroq.precondition.api.MemoryBudgetStore
import app.elroq.precondition.api.MutableClock
import app.elroq.precondition.api.RateBudget
import app.elroq.precondition.api.RecordingMetaSink
import app.elroq.precondition.api.RequestKind
import app.elroq.precondition.api.VehicleFetch
import app.elroq.precondition.rules.ClimateState
import app.elroq.precondition.rules.LatLon
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.TimeUnit
import kotlin.random.Random
import kotlin.time.Duration.Companion.hours

class KiaClientTest {
    private val server = MockWebServer()
    private val clock = MutableClock(Instant.parse("2026-09-23T15:00:00Z"))
    private val budgetStore = MemoryBudgetStore()
    private val budget = RateBudget(budgetStore, clock) { BudgetConfig(fallbackLimit = 80, manualReserve = 8, window = 24.hours) }
    private val sink = RecordingMetaSink()
    private val sessions = InMemoryKiaSessionStore()
    private var creds: Credentials? = Credentials(REFRESH, "")
    private lateinit var client: KiaClient

    /** Responses by path suffix; each queue is used up before falling back to [defaults]. */
    private val scripted = ConcurrentHashMap<String, ConcurrentLinkedQueue<MockResponse>>()
    private val defaults = ConcurrentHashMap<String, MockResponse>()
    private val seen = ConcurrentLinkedQueue<RecordedRequest>()

    private fun respond(pathSuffix: String, vararg responses: MockResponse) {
        scripted.getOrPut(pathSuffix) { ConcurrentLinkedQueue() }.addAll(responses)
    }

    @Before
    fun setUp() {
        defaults["/oauth2/token"] = json(TOKEN_OK)
        defaults["/notifications/register"] = ok("""{"deviceId":"dev-1"}""")
        defaults["/spa/vehicles"] = ok(VEHICLES_LEGACY)
        defaults["/status/latest"] = ok(LEGACY_STATUS)
        defaults["/ccs2/carstatus/latest"] = ok(CCS2_STATUS)
        defaults["/location/park"] = ok(PARK)
        defaults["/control/temperature"] = json("""{"retCode":"S","resCode":"0000","resMsg":{},"msgId":"m1"}""")
        defaults["/user/pin"] = json("""{"controlToken":"ctl-1","expiresTime":600}""")
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                seen += request
                val path = request.requestUrl!!.encodedPath
                scripted.entries.firstOrNull { path.endsWith(it.key) && it.value.isNotEmpty() }?.let { return it.value.poll()!! }
                return defaults.entries.firstOrNull { path.endsWith(it.key) }?.value ?: MockResponse().setResponseCode(404)
            }
        }
        server.start()
        val base = server.url("/").toString().trimEnd('/')
        client = KiaClient(
            OkHttpClient.Builder().readTimeout(2, TimeUnit.SECONDS).build(),
            budget, { creds }, sessions, sink, clock,
            KiaConfig(apiBase = base, idpBase = base),
            Random(1),
        )
    }

    @After
    fun tearDown() = server.shutdown()

    private fun paths() = seen.map { it.requestUrl!!.encodedPath.substringAfterLast("/api/") }
    private fun last(suffix: String) = seen.last { it.requestUrl!!.encodedPath.endsWith(suffix) }
    private fun body(r: RecordedRequest): JsonObject = Json.parseToJsonElement(r.body.readUtf8()).jsonObject

    private suspend fun fetch(): VehicleFetch {
        val result = client.getVehicle(RequestKind.MANUAL)
        assertTrue(result.toString(), result is ApiResult.Success)
        return (result as ApiResult.Success).value
    }

    // ---- Login and session ----------------------------------------------------------------------

    @Test
    fun `first read logs in, registers, picks the EV and reads cached status and parked position`() = runTest {
        val v = fetch().snapshot
        assertEquals(
            listOf("v2/user/oauth2/token", "v1/spa/notifications/register", "v1/spa/vehicles", "v1/spa/vehicles/veh-ev/status/latest", "v1/spa/vehicles/veh-ev/location/park"),
            paths(),
        )
        val token = seen.first().body.readUtf8()
        assertTrue(token.contains("grant_type=refresh_token"))
        assertTrue(token.contains("refresh_token=$REFRESH"))

        val status = last("/status/latest")
        assertEquals("Bearer acc-1", status.getHeader("Authorization"))
        assertEquals("dev-1", status.getHeader("ccsp-device-id"))
        assertEquals("0", status.getHeader("Ccuccs2protocolsupport"))
        assertNotNull(status.getHeader("Stamp"))

        assertEquals(74, v.socPercent)
        assertEquals(312, v.rangeKm)
        assertEquals(true, v.pluggedIn)
        assertEquals("CHARGING", v.chargingState)
        assertEquals(10.9, v.chargePowerKw!!, 0.0)
        assertEquals(95, v.minutesToFullyCharged)
        assertEquals(ClimateState.OFF, v.climate)
        assertEquals(21.0, v.targetTempC!!, 0.0)
        assertEquals(true, v.parked)
        // location/park wins over the older position inside the status
        assertEquals(LatLon(50.1, 14.4), v.parkingPosition)
        // 17:58:00 in Berlin (CEST) = 15:58 UTC
        assertEquals(Instant.parse("2026-09-23T15:58:00Z").toEpochMilli(), v.carCapturedAtEpochMs)
        assertEquals(clock.millis(), v.fetchedAtEpochMs)
        assertTrue(sink.seen.single().second == null)
    }

    @Test
    fun `later reads reuse the session and cost one budget slot each`() = runTest {
        fetch()
        seen.clear()
        fetch()
        assertEquals(listOf("v1/spa/vehicles/veh-ev/status/latest", "v1/spa/vehicles/veh-ev/location/park"), paths())
        assertEquals(2, budgetStore.state.sent.size)
    }

    @Test
    fun `a rotated refresh token is kept and the access token is renewed before it expires`() = runTest {
        respond("/oauth2/token", json(TOKEN_OK.replace("\"expires_in\":3600", "\"expires_in\":3600,\"refresh_token\":\"NEWREFRESH\"")))
        fetch()
        assertEquals("NEWREFRESH", sessions.session!!.refreshToken)
        assertEquals(KiaSession.fingerprint(REFRESH), sessions.session!!.enteredTokenHash)

        clock.advanceSeconds(3600 - 60)
        seen.clear()
        fetch()
        assertTrue(seen.first().body.readUtf8().contains("refresh_token=NEWREFRESH"))
    }

    @Test
    fun `entering a different token starts a new session`() = runTest {
        fetch()
        creds = Credentials("B".repeat(48), "")
        seen.clear()
        fetch()
        assertEquals("v2/user/oauth2/token", paths().first())
        assertTrue(seen.first().body.readUtf8().contains("refresh_token=" + "B".repeat(48)))
    }

    @Test
    fun `a rejected refresh token stops automation and does not count against the budget`() = runTest {
        respond("/oauth2/token", MockResponse().setResponseCode(400).setBody("""{"error":"invalid_grant"}"""))
        val result = client.getVehicle(RequestKind.AUTOMATION)
        val error = (result as ApiResult.Failure).error
        assertTrue(error is ApiError.LoginFailed)
        assertTrue(error.isAuthFailure)
        assertTrue(sink.seen.single().second!!.isAuthFailure)
        assertTrue(budgetStore.state.sent.isEmpty())
    }

    @Test
    fun `an expired access token is refreshed once and the call retried`() = runTest {
        fetch()
        respond("/status/latest", MockResponse().setResponseCode(401).setBody("""{"error":"Key not authorized: Token is expired"}"""))
        respond("/oauth2/token", json(TOKEN_OK.replace("acc-1", "acc-2")))
        seen.clear()
        fetch()
        assertEquals("v2/user/oauth2/token", paths()[1])
        assertEquals("Bearer acc-2", last("/status/latest").getHeader("Authorization"))
    }

    @Test
    fun `a login that keeps failing after a refresh is an auth failure`() = runTest {
        respond("/status/latest", *Array(2) { json("""{"retCode":"F","resCode":"7501","resMsg":"expired"}""") })
        val error = (client.getVehicle(RequestKind.MANUAL) as ApiResult.Failure).error
        assertTrue(error.toString(), error is ApiError.LoginFailed)
    }

    @Test
    fun `a dropped device id is re-registered once`() = runTest {
        fetch()
        respond("/status/latest", MockResponse().setResponseCode(400).setBody("""{"retCode":"F","resCode":"4002","resMsg":"Invalid request body - invalid deviceId"}"""))
        respond("/notifications/register", ok("""{"deviceId":"dev-2"}"""))
        seen.clear()
        fetch()
        assertEquals("dev-2", last("/status/latest").getHeader("ccsp-device-id"))
    }

    @Test
    fun `a VIN picks that car and an unknown VIN is reported`() = runTest {
        respond("/spa/vehicles", ok(VEHICLES_TWO))
        creds = Credentials(REFRESH, "KNAC381ABN5000002")
        fetch()
        assertTrue(last("/status/latest").requestUrl!!.encodedPath.contains("veh-two"))

        creds = Credentials(REFRESH, "KNAC381ABN5999999")
        respond("/spa/vehicles", ok(VEHICLES_TWO))
        val error = (client.getVehicle(RequestKind.MANUAL) as ApiResult.Failure).error
        assertTrue(error is ApiError.VehicleNotFound)
    }

    @Test
    fun `missing credentials make no request`() = runTest {
        creds = null
        assertEquals(ApiError.NotConfigured, (client.getVehicle(RequestKind.MANUAL) as ApiResult.Failure).error)
        assertTrue(seen.isEmpty())
    }

    // ---- Errors -----------------------------------------------------------------------------------

    @Test
    fun `Kia's request limit blocks the budget for an hour`() = runTest {
        respond("/status/latest", json("""{"retCode":"F","resCode":"5091","resMsg":"Exceeds number of requests"}"""))
        val error = (client.getVehicle(RequestKind.AUTOMATION) as ApiResult.Failure).error
        assertTrue(error is ApiError.RateLimited)
        assertEquals(clock.millis() + 3600_000, budgetStore.state.exhaustedUntilEpochMs)
    }

    @Test
    fun `a busy car is reported as not accepting requests`() = runTest {
        respond("/control/temperature", MockResponse().setResponseCode(400).setBody("""{"retCode":"F","resCode":"5031","resMsg":"Unavailable remote control"}"""))
        val error = (client.startClimate(21.0, RequestKind.MANUAL) as ApiResult.Failure).error
        assertTrue(error is ApiError.VehicleNotAcceptingRequests)
    }

    @Test
    fun `unsupported control and server errors are mapped`() = runTest {
        respond("/control/temperature", json("""{"retCode":"F","resCode":"4005","resMsg":"Unsupported"}"""))
        assertTrue((client.startClimate(21.0, RequestKind.MANUAL) as ApiResult.Failure).error is ApiError.OperationNotSupported)
        respond("/status/latest", MockResponse().setResponseCode(502).setBody("bad gateway"))
        assertTrue((client.getVehicle(RequestKind.MANUAL) as ApiResult.Failure).error is ApiError.Server)
    }

    @Test
    fun `a failed parked-position read still returns the status`() = runTest {
        respond("/location/park", json("""{"retCode":"F","resCode":"5921","resMsg":"No Data Found v2"}"""))
        assertEquals(LatLon(50.0, 14.0), fetch().snapshot.parkingPosition)
    }

    // ---- Climate ----------------------------------------------------------------------------------

    @Test
    fun `start and stop climate on an older car`() = runTest {
        assertTrue(client.startClimate(21.2, RequestKind.MANUAL) is ApiResult.Success)
        val start = body(last("/control/temperature"))
        assertEquals("\"start\"", start["action"].toString())
        assertEquals("\"0EH\"", start["tempCode"].toString())
        assertEquals("10", start["options"]!!.jsonObject["igniOnDuration"].toString())
        assertEquals("Bearer acc-1", last("/control/temperature").getHeader("Authorization"))

        assertTrue(client.stopClimate(RequestKind.MANUAL) is ApiResult.Success)
        assertEquals("\"stop\"", body(last("/control/temperature"))["action"].toString())
    }

    @Test
    fun `CCS2 cars map the new status format`() = runTest {
        respond("/spa/vehicles", ok(VEHICLES_LEGACY.replace("\"ccuCCS2ProtocolSupport\":0", "\"ccuCCS2ProtocolSupport\":1")))
        val v = fetch().snapshot
        assertTrue(paths().contains("v1/spa/vehicles/veh-ev/ccs2/carstatus/latest"))
        assertEquals("1", last("/ccs2/carstatus/latest").getHeader("Ccuccs2protocolsupport"))
        assertEquals(58, v.socPercent)
        assertEquals(false, v.pluggedIn)
        assertEquals("UNPLUGGED", v.chargingState)
        assertEquals(ClimateState.RUNNING, v.climate)
        assertEquals(22.0, v.targetTempC!!, 0.0)
        assertEquals(4.5, v.outsideTempC!!, 0.0)
        assertEquals(402, v.rangeKm)
        assertEquals(true, v.parked)
        assertEquals(Instant.parse("2026-09-23T14:30:05Z").toEpochMilli(), v.carCapturedAtEpochMs)
    }

    @Test
    fun `CCS2 climate needs the PIN and uses a control token`() = runTest {
        respond("/spa/vehicles", ok(VEHICLES_LEGACY.replace("\"ccuCCS2ProtocolSupport\":0", "\"ccuCCS2ProtocolSupport\":1")))
        val noPin = (client.startClimate(21.0, RequestKind.MANUAL) as ApiResult.Failure).error
        assertTrue(noPin is ApiError.LoginFailed)
        assertFalse(seen.any { it.requestUrl!!.encodedPath.endsWith("/control/temperature") })

        creds = Credentials(REFRESH, "", pin = "1234")
        assertTrue(client.startClimate(21.0, RequestKind.MANUAL) is ApiResult.Success)
        val pin = body(last("/user/pin"))
        assertEquals("\"1234\"", pin["pin"].toString())
        assertEquals("\"dev-1\"", pin["deviceId"].toString())
        val command = last("/ccs2/control/temperature")
        assertTrue(command.requestUrl!!.encodedPath.contains("/api/v2/spa/"))
        assertEquals("Bearer ctl-1", command.getHeader("Authorization"))
        assertEquals("Bearer ctl-1", command.getHeader("AuthorizationCCSP"))
        val start = body(command)
        assertEquals("\"start\"", start["command"].toString())
        assertEquals("21.0", start["hvacTemp"].toString())

        // The control token is reused while valid.
        seen.clear()
        assertTrue(client.stopClimate(RequestKind.MANUAL) is ApiResult.Success)
        assertFalse(seen.any { it.requestUrl!!.encodedPath.endsWith("/user/pin") })
    }

    @Test
    fun `a wrong PIN is an auth failure`() = runTest {
        respond("/spa/vehicles", ok(VEHICLES_LEGACY.replace("\"ccuCCS2ProtocolSupport\":0", "\"ccuCCS2ProtocolSupport\":1")))
        respond("/user/pin", MockResponse().setResponseCode(400).setBody("""{"errCode":"4001","errMsg":"invalid pin"}"""))
        creds = Credentials(REFRESH, "", pin = "9999")
        val error = (client.startClimate(21.0, RequestKind.MANUAL) as ApiResult.Failure).error
        assertTrue(error is ApiError.LoginFailed)
        assertTrue(error.message.contains("PIN"))
    }

    // ---- Encoding ---------------------------------------------------------------------------------

    @Test
    fun `stamp is the app id and time XORed with the fixed key`() {
        val config = KiaConfig()
        val stamp = Base64.getDecoder().decode(config.stamp(1_700_000_000))
        val key = Base64.getDecoder().decode("wLTVxwidmH8CfJYBWSnHD6E0huk0ozdiuygB4hLkM5XCgzAL1Dk5sE36d/bx5PFMbZs=")
        val plain = String(ByteArray(stamp.size) { (stamp[it].toInt() xor key[it].toInt()).toByte() })
        assertEquals("${config.appId}:1700000000", plain)
    }

    @Test
    fun `temperature codes round trip`() {
        assertEquals("0EH", KiaMapper.legacyTempCode(21.0))
        assertEquals("00H", KiaMapper.legacyTempCode(10.0))
        assertEquals("1FH", KiaMapper.legacyTempCode(35.0))
        assertEquals(21.0, KiaMapper.legacyTemp("0EH", 0)!!, 0.0)
        assertEquals(29.5, KiaMapper.legacyTemp("1fH", 0)!!, 0.0)
        assertNull(KiaMapper.legacyTemp("20H", 0))
        assertNull(KiaMapper.legacyTemp("0EH", 1))
        assertNull(KiaMapper.legacyTemp("xx", 0))
    }

    companion object {
        const val REFRESH = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCDEFGHIJKL"

        fun json(body: String) = MockResponse().setHeader("Content-Type", "application/json").setBody(body)
        fun ok(resMsg: String) = json("""{"retCode":"S","resCode":"0000","resMsg":$resMsg,"msgId":"x"}""")

        const val TOKEN_OK = """{"token_type":"Bearer","access_token":"acc-1","expires_in":3600}"""

        val VEHICLES_LEGACY = """
            {"vehicles":[
              {"vehicleId":"veh-ice","nickname":"Ceed","vehicleName":"CEED","vin":"U5YH000000000001","type":"GN","ccuCCS2ProtocolSupport":0},
              {"vehicleId":"veh-ev","nickname":"EV6","vehicleName":"EV6","vin":"KNAC381ABN5000001","type":"EV","ccuCCS2ProtocolSupport":0}
            ]}
        """.trimIndent()

        val VEHICLES_TWO = """
            {"vehicles":[
              {"vehicleId":"veh-one","vin":"KNAC381ABN5000001","type":"EV","ccuCCS2ProtocolSupport":0},
              {"vehicleId":"veh-two","vin":"KNAC381ABN5000002","type":"EV","ccuCCS2ProtocolSupport":0}
            ]}
        """.trimIndent()

        val LEGACY_STATUS = """
            {"vehicleStatusInfo":{
              "vehicleStatus":{
                "time":"20260923175800","airCtrlOn":false,"engine":false,
                "airTemp":{"value":"0EH","unit":0},
                "evStatus":{
                  "batteryStatus":74,"batteryCharge":true,"batteryPlugin":2,
                  "batteryPower":{"batteryStndChrgPower":10.9,"batteryFstChrgPower":0},
                  "remainTime2":{"atc":{"value":95,"unit":1}},
                  "drvDistance":[{"rangeByFuel":{"evModeRange":{"value":312,"unit":1},"totalAvailableRange":{"value":312,"unit":1}}}]
                }
              },
              "vehicleLocation":{"coord":{"lat":50.0,"lon":14.0},"time":"20260922120000"},
              "odometer":{"value":18234.5,"unit":1}
            }}
        """.trimIndent()

        const val PARK = """{"coord":{"lat":50.1,"lon":14.4,"type":0},"time":"20260923170000"}"""

        val CCS2_STATUS = """
            {"state":{"Vehicle":{
              "Date":"20260923143005.123",
              "DrivingReady":0,
              "Green":{
                "BatteryManagement":{"BatteryRemain":{"Ratio":58}},
                "ChargingInformation":{"ConnectorFastening":{"State":0},"Charging":{"RemainTime":0}}
              },
              "Drivetrain":{"FuelSystem":{"DTE":{"Total":250,"Unit":2}}},
              "Cabin":{"HVAC":{
                "Row1":{"Driver":{"Temperature":{"Value":"22","Unit":0},"Blower":{"SpeedLevel":3}}},
                "OutsideTemperature":{"Value":"4.5","Unit":0}
              }},
              "Location":{"GeoCoord":{"Latitude":50.2,"Longitude":14.2}}
            }}}
        """.trimIndent()
    }
}
