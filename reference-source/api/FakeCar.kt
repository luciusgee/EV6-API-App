package app.elroq.precondition.api

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.time.Clock
import java.time.Duration
import java.time.Instant

/** Error the fake car answers with on its next requests, for exercising failure paths. */
enum class FakeScenario { NONE, KEY_EXPIRED, KEY_NOT_AUTHORIZED, RATE_LIMITED, VEHICLE_BUSY, NOT_SUPPORTED, SERVER_ERROR, PARTIAL }

data class FakeCarState(
    val socPercent: Int = 62,
    val pluggedIn: Boolean = false,
    /** Only meaningful when plugged in. */
    val charging: Boolean = false,
    val climateState: String = "OFF",
    val targetTempC: Double = 21.0,
    val latitude: Double = 50.4113,
    val longitude: Double = 14.9053,
    val scenario: FakeScenario = FakeScenario.NONE,
    val limit: Int = 20,
)

/**
 * Debug-only stand-in for the Škoda API, installed as an OkHttp interceptor so the real client,
 * budget and error mapping all run unchanged. Rate-limit headers are simulated per hour.
 */
class FakeCar(private val clock: Clock, initial: FakeCarState = FakeCarState()) : Interceptor {
    @Volatile
    var state: FakeCarState = initial

    private val lock = Any()
    private var windowStart: Instant = clock.instant()
    private var used = 0

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val path = request.url.encodedPath
        val now = clock.instant()
        // 401/403 don't count against the limit; everything else, errors included, does.
        val (limited, remaining, resetSeconds) = synchronized(lock) {
            if (Duration.between(windowStart, now) >= Duration.ofHours(1)) {
                windowStart = now
                used = 0
            }
            val scenario = state.scenario
            val over = used >= state.limit
            if (!over && scenario != FakeScenario.KEY_EXPIRED && scenario != FakeScenario.KEY_NOT_AUTHORIZED) used++
            Triple(over, (state.limit - used).coerceAtLeast(0), (3600 - Duration.between(windowStart, now).seconds).coerceAtLeast(0))
        }

        fun respond(code: Int, body: String = "", extra: Map<String, String> = emptyMap()): Response {
            val builder = Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(code)
                .message(if (code < 400) "OK" else "Error")
                .header(HeaderParser.RATE_LIMIT, state.limit.toString())
                .header(HeaderParser.RATE_REMAINING, remaining.toString())
                .header(HeaderParser.RATE_RESET, resetSeconds.toString())
                .header(HeaderParser.KEY_EXPIRES_AT, now.plus(Duration.ofDays(90)).toString())
                .body(body.toResponseBody(JSON))
            extra.forEach { (k, v) -> builder.header(k, v) }
            return builder.build()
        }

        if (limited) {
            return respond(429, problem("rate-limit-exceeded"), mapOf(HeaderParser.RETRY_AFTER to resetSeconds.toString()))
        }
        when (state.scenario) {
            FakeScenario.KEY_EXPIRED -> return respond(401, problem("api-key-expired"))
            FakeScenario.KEY_NOT_AUTHORIZED -> return respond(403, problem("api-key-not-authorized"))
            FakeScenario.RATE_LIMITED -> return respond(429, problem("rate-limit-exceeded"), mapOf(HeaderParser.RETRY_AFTER to "600"))
            FakeScenario.VEHICLE_BUSY -> return respond(429, problem("vehicle-not-accepting-requests"))
            FakeScenario.NOT_SUPPORTED -> if (request.method == "POST") return respond(422, problem("operation-not-supported"))
            FakeScenario.SERVER_ERROR -> return respond(503, problem("service-unavailable"))
            FakeScenario.NONE, FakeScenario.PARTIAL -> Unit
        }

        return when {
            request.method == "GET" && path.matches(Regex(".*/api/v1/vehicles/[^/]+")) -> respond(200, vehicleJson(now))
            request.method == "POST" && path.endsWith("/air-conditioning/start") -> {
                val target = readTarget(request) ?: state.targetTempC
                state = state.copy(climateState = if (target >= 20.0) "HEATING" else "COOLING", targetTempC = target)
                respond(202)
            }
            request.method == "POST" && path.endsWith("/air-conditioning/stop") -> {
                state = state.copy(climateState = "OFF")
                respond(202)
            }
            else -> respond(404, problem("not-found"))
        }
    }

    private fun readTarget(request: okhttp3.Request): Double? = runCatching {
        val buffer = Buffer()
        request.body?.writeTo(buffer)
        Json.parseToJsonElement(buffer.readUtf8()).jsonObject["targetTemperature"]!!
            .jsonObject["value"]!!.jsonPrimitive.double
    }.getOrNull()

    private fun vehicleJson(now: Instant): String {
        val s = state
        val partial = s.scenario == FakeScenario.PARTIAL
        val root: JsonObject = buildJsonObject {
            putJsonObject("vehicle") {
                put("vin", FAKE_VIN)
                put("name", "Elroq (fake)")
                putJsonObject("airConditioning") {
                    put("state", s.climateState)
                    putJsonObject("targetTemperature") {
                        put("value", s.targetTempC)
                        put("unit", "CELSIUS")
                    }
                    put("airConditioningWithoutExternalPower", true)
                    put("carCapturedTimestamp", now.minusSeconds(120).toString())
                }
                putJsonObject("charging") {
                    put("isVehicleInSavedLocation", true)
                    putJsonObject("status") {
                        put("state", if (!s.pluggedIn) "CONNECT_CABLE" else if (s.charging) "CHARGING" else "READY_FOR_CHARGING")
                        if (s.pluggedIn && s.charging) {
                            put("chargePowerInKw", 7.2)
                            put("remainingTimeToFullyChargedInMinutes", (100 - s.socPercent) * 6)
                        }
                        putJsonObject("battery") {
                            put("stateOfChargeInPercent", s.socPercent)
                            put("remainingCruisingRangeInMeters", s.socPercent * 4200)
                        }
                    }
                    put("carCapturedTimestamp", now.minusSeconds(120).toString())
                }
                if (!partial) {
                    putJsonObject("parkingPosition") {
                        put("state", "PARKED")
                        putJsonObject("gpsCoordinates") {
                            put("latitude", s.latitude)
                            put("longitude", s.longitude)
                        }
                    }
                }
            }
            put("errors", buildJsonArray {
                if (partial) {
                    add(buildJsonObject {
                        put("type", "PARKING_POSITION_UNAVAILABLE")
                        put("description", "Parking position is temporarily unavailable")
                    })
                }
            })
        }
        return root.toString()
    }

    private fun problem(code: String) = buildJsonObject {
        put("type", code)
        put("title", code.replace('-', ' '))
    }.toString()

    companion object {
        const val FAKE_VIN = "TMBFAKE0000000001"
        private val JSON = "application/json".toMediaType()
    }
}
