package app.elroq.precondition.api.kia

import app.elroq.precondition.api.FakeCar
import app.elroq.precondition.api.FakeScenario
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
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
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Debug-only stand-in for Kia Connect (login, device registration, vehicle list, cached status,
 * parked position, climate control), driven by the same [FakeCar] state and error scenarios as the
 * Škoda fake. Kia sends no rate headers; it answers 5091 once a day's requests run out.
 */
class FakeKia(private val car: FakeCar, private val clock: Clock) : Interceptor {
    private val lock = Any()
    private var windowStart: Instant = clock.instant()
    private var used = 0

    /** Kia's EU limit is per day and much larger than Škoda's hourly one. */
    private val dailyLimit: Int get() = car.state.limit * 10

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val path = request.url.encodedPath
        val s = car.state

        fun respond(code: Int, body: String): Response = Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(code)
            .message(if (code < 400) "OK" else "Error")
            .body(body.toResponseBody(JSON))
            .build()

        fun fail(code: Int, resCode: String, msg: String) = respond(code, buildJsonObject {
            put("retCode", "F")
            put("resCode", resCode)
            put("resMsg", msg)
        }.toString())

        fun ok(resMsg: JsonObject = JsonObject(emptyMap()), msgId: Boolean = false) = respond(200, buildJsonObject {
            put("retCode", "S")
            put("resCode", "0000")
            put("resMsg", resMsg)
            if (msgId) put("msgId", "fake-${clock.millis()}")
        }.toString())

        if (request.url.host == KiaConfig.IDP_HOST) {
            if (s.scenario == FakeScenario.KEY_EXPIRED) {
                return respond(400, """{"error":"invalid_grant","error_description":"Invalid refresh token"}""")
            }
            return respond(200, """{"token_type":"Bearer","access_token":"fake-access","refresh_token":"FAKEREFRESH","expires_in":86400}""")
        }

        val over = synchronized(lock) {
            val now = clock.instant()
            if (Duration.between(windowStart, now) >= Duration.ofDays(1)) {
                windowStart = now
                used = 0
            }
            val over = used >= dailyLimit
            if (!over) used++
            over
        }
        if (over) return fail(400, "5091", "Exceeds number of requests")

        when (s.scenario) {
            FakeScenario.KEY_NOT_AUTHORIZED -> if (!path.endsWith("/notifications/register")) {
                return respond(401, """{"error":"Key not authorized: Token is expired"}""")
            }
            FakeScenario.RATE_LIMITED -> return fail(400, "5091", "Exceeds number of requests")
            FakeScenario.VEHICLE_BUSY -> return fail(400, "5031", "Unavailable remote control - Service Temporary Unavailable")
            FakeScenario.NOT_SUPPORTED -> if (path.contains("/control/")) return fail(400, "4005", "Unsupported control")
            FakeScenario.SERVER_ERROR -> return respond(503, """{"error":"service unavailable"}""")
            else -> Unit
        }

        return when {
            path.endsWith("/notifications/register") -> ok(buildJsonObject { put("deviceId", "fake-device") })
            path.endsWith("/spa/vehicles") -> ok(buildJsonObject {
                put("vehicles", buildJsonArray {
                    add(buildJsonObject {
                        put("vehicleId", VEHICLE_ID)
                        put("nickname", "EV6 (fake)")
                        put("vehicleName", "EV6")
                        put("vin", FakeCar.FAKE_VIN)
                        put("type", "EV")
                        put("regDate", "2022-03-01 00:00:00.000")
                        put("ccuCCS2ProtocolSupport", 0)
                    })
                })
            })
            path.endsWith("/status/latest") -> ok(status())
            path.endsWith("/location/park") -> if (s.scenario == FakeScenario.PARTIAL) {
                fail(400, "5921", "No Data Found v2")
            } else {
                ok(buildJsonObject {
                    putJsonObject("coord") {
                        put("lat", s.latitude)
                        put("lon", s.longitude)
                        put("type", 0)
                    }
                    put("time", berlinTime(clock.instant().minusSeconds(600)))
                })
            }
            path.endsWith("/control/temperature") -> {
                val body = readJson(request)
                if (body?.get("action").str() == "stop") {
                    car.state = car.state.copy(climateState = "OFF")
                } else {
                    val target = KiaMapper.legacyTemp(body?.get("tempCode").str(), 0) ?: s.targetTempC
                    car.state = car.state.copy(climateState = if (target >= 20.0) "HEATING" else "COOLING", targetTempC = target)
                }
                ok(msgId = true)
            }
            else -> fail(404, "4040", "not found")
        }
    }

    private fun status(): JsonObject {
        val s = car.state
        val now = clock.instant()
        return buildJsonObject {
            putJsonObject("vehicleStatusInfo") {
                putJsonObject("vehicleStatus") {
                    put("time", berlinTime(now.minusSeconds(120)))
                    put("airCtrlOn", s.climateState != "OFF")
                    put("engine", false)
                    putJsonObject("airTemp") {
                        put("value", KiaMapper.legacyTempCode(s.targetTempC))
                        put("unit", 0)
                    }
                    putJsonObject("battery") { put("batSoc", 81) }
                    putJsonObject("evStatus") {
                        put("batteryStatus", s.socPercent)
                        put("batteryCharge", s.pluggedIn && s.charging)
                        put("batteryPlugin", if (s.pluggedIn) 2 else 0)
                        putJsonObject("batteryPower") {
                            put("batteryStndChrgPower", if (s.pluggedIn && s.charging) 10.9 else 0.0)
                            put("batteryFstChrgPower", 0.0)
                        }
                        putJsonObject("remainTime2") {
                            putJsonObject("atc") {
                                put("value", if (s.pluggedIn && s.charging) (100 - s.socPercent) * 5 else 0)
                                put("unit", 1)
                            }
                        }
                        put("drvDistance", buildJsonArray {
                            add(buildJsonObject {
                                putJsonObject("rangeByFuel") {
                                    putJsonObject("evModeRange") {
                                        put("value", s.socPercent * 5)
                                        put("unit", 1)
                                    }
                                }
                            })
                        })
                    }
                }
                if (s.scenario != FakeScenario.PARTIAL) {
                    putJsonObject("vehicleLocation") {
                        putJsonObject("coord") {
                            put("lat", s.latitude)
                            put("lon", s.longitude)
                        }
                        put("time", berlinTime(now.minusSeconds(3600)))
                    }
                }
                putJsonObject("odometer") {
                    put("value", 18234.5)
                    put("unit", 1)
                }
            }
        }
    }

    private fun readJson(request: okhttp3.Request): JsonObject? = runCatching {
        val buffer = Buffer()
        request.body?.writeTo(buffer)
        Json.parseToJsonElement(buffer.readUtf8()) as? JsonObject
    }.getOrNull()

    private fun berlinTime(at: Instant): String = at.atZone(ZoneId.of("Europe/Berlin")).format(DateTimeFormatter.ofPattern("yyyyMMddHHmmss"))

    companion object {
        const val VEHICLE_ID = "00000000-fake-4000-8000-000000000ev6"
        private val JSON = "application/json".toMediaType()
    }
}
