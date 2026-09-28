package app.elroq.precondition.api.kia

import app.elroq.precondition.api.ApiError
import app.elroq.precondition.api.ApiMetaSink
import app.elroq.precondition.api.ApiResult
import app.elroq.precondition.api.Credentials
import app.elroq.precondition.api.CredentialsProvider
import app.elroq.precondition.api.RateBudget
import app.elroq.precondition.api.RequestKind
import app.elroq.precondition.api.ResponseMeta
import app.elroq.precondition.api.VehicleApi
import app.elroq.precondition.api.VehicleFetch
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import okhttp3.FormBody
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.time.Clock
import java.util.UUID
import kotlin.random.Random
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes

/**
 * Kia Connect Europe, behind the same [VehicleApi] as the Škoda client. Unofficial: it speaks the
 * Kia app's own protocol, so it can break whenever Kia changes it.
 *
 * Only cached state is read (`status/latest`, `location/park`), which never wakes the car, so
 * automation cannot drain the 12 V battery by polling. Each call takes one slot from [RateBudget],
 * even though it may make several HTTP requests (login refresh, vehicle list, status + position).
 */
class KiaClient(
    private val http: OkHttpClient,
    private val budget: RateBudget,
    private val credentials: CredentialsProvider,
    private val sessions: KiaSessionStore,
    private val metaSink: ApiMetaSink,
    private val clock: Clock,
    private val config: KiaConfig = KiaConfig(),
    private val random: Random = Random.Default,
) : VehicleApi {
    private val mutex = Mutex()
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    override suspend fun getVehicle(kind: RequestKind): ApiResult<VehicleFetch> = call(kind) { s, _ ->
        val path = if (s.ccs2 != 0) "ccs2/carstatus/latest" else "status/latest"
        val status = get("${config.spa}/vehicles/${s.vehicleId}/$path", authHeaders(s))
        // The position inside the status can be old; the parked position is current and also doesn't wake the car.
        val park = try {
            get("${config.spa}/vehicles/${s.vehicleId}/location/park", authHeaders(s, ccs2 = 0))
        } catch (e: KiaApiException) {
            null
        }
        val raw = buildJsonObject {
            put("status", status)
            park?.let { put("park", it) }
        }
        VehicleFetch(KiaMapper.toSnapshot(status, park, s.ccs2 != 0, clock.instant()), raw.toString())
    }

    override suspend fun startClimate(targetC: Double, kind: RequestKind, withoutExternalPower: Boolean): ApiResult<Unit> =
        call(kind) { s, creds ->
            val target = roundToHalf(targetC.coerceIn(KiaConfig.MIN_TEMP_C, KiaConfig.MAX_TEMP_C))
            if (s.ccs2 == 0) {
                val body = buildJsonObject {
                    put("action", "start")
                    put("hvacType", 0)
                    putJsonObject("options") {
                        put("defrost", false)
                        put("heating1", 0)
                        put("igniOnDuration", config.climateMinutes)
                    }
                    put("tempCode", KiaMapper.legacyTempCode(target))
                    put("unit", "C")
                }
                post("${config.spa}/vehicles/${s.vehicleId}/control/temperature", authHeaders(s), body)
            } else {
                val body = buildJsonObject {
                    put("command", "start")
                    put("ignitionDuration", config.climateMinutes)
                    put("strgWhlHeating", 0)
                    put("hvacTempType", 1)
                    put("hvacTemp", target)
                    put("sideRearMirrorHeating", 1)
                    put("drvSeatLoc", "L")
                    putJsonObject("seatClimateInfo") {
                        put("drvSeatClimateState", 0)
                        put("psgSeatClimateState", 0)
                        put("rrSeatClimateState", 0)
                        put("rlSeatClimateState", 0)
                    }
                    put("tempUnit", "C")
                    put("windshieldFrontDefogState", false)
                }
                post("${config.spaV2}/vehicles/${s.vehicleId}/ccs2/control/temperature", controlHeaders(s, creds), body)
            }
            Unit
        }

    override suspend fun stopClimate(kind: RequestKind): ApiResult<Unit> = call(kind) { s, creds ->
        if (s.ccs2 == 0) {
            val body = buildJsonObject {
                put("action", "stop")
                put("hvacType", 0)
                putJsonObject("options") {
                    put("defrost", true)
                    put("heating1", 1)
                }
                put("tempCode", "10H")
                put("unit", "C")
            }
            post("${config.spa}/vehicles/${s.vehicleId}/control/temperature", authHeaders(s), body)
        } else {
            post("${config.spaV2}/vehicles/${s.vehicleId}/ccs2/control/temperature", controlHeaders(s, creds), buildJsonObject { put("command", "stop") })
        }
        Unit
    }

    /** Clears the stored login, e.g. when the user enters a new token. */
    suspend fun reset() = mutex.withLock { sessions.save(null) }

    // ---- Budget, retries, error mapping ---------------------------------------------------------

    private suspend fun <T> call(kind: RequestKind, op: suspend (KiaSession, Credentials) -> T): ApiResult<T> = mutex.withLock {
        val creds = credentials.credentials() ?: return ApiResult.Failure(ApiError.NotConfigured)
        val ticket = budget.tryAcquire(kind) ?: return ApiResult.Failure(ApiError.BudgetExhausted(kind))
        try {
            val value = withSession(creds, op)
            val meta = ResponseMeta(200, clock.instant())
            budget.complete(ticket, meta)
            metaSink.onResponse(meta, null)
            ApiResult.Success(value, meta)
        } catch (e: CancellationException) {
            budget.complete(ticket, null)
            throw e
        } catch (e: KiaFailure) {
            val meta = ResponseMeta(e.httpCode, clock.instant(), retryAfter = (e.error as? ApiError.RateLimited)?.retryAfter)
            budget.complete(ticket, meta, e.error)
            metaSink.onResponse(meta, e.error)
            ApiResult.Failure(e.error, meta)
        } catch (e: KiaApiException) {
            val error = map(e)
            val meta = ResponseMeta(metaCode(e, error), clock.instant(), retryAfter = (error as? ApiError.RateLimited)?.retryAfter)
            budget.complete(ticket, meta, error)
            metaSink.onResponse(meta, error)
            ApiResult.Failure(error, meta)
        } catch (e: IOException) {
            budget.complete(ticket, null)
            ApiResult.Failure(ApiError.Network(e.message ?: e.javaClass.simpleName))
        } catch (e: RuntimeException) {
            budget.complete(ticket, null)
            ApiResult.Failure(ApiError.Network(e.message ?: e.javaClass.simpleName))
        }
    }

    /** Runs [op] with a working session: refreshes an expired login and re-registers a dropped device once each. */
    private suspend fun <T> withSession(creds: Credentials, op: suspend (KiaSession, Credentials) -> T): T {
        var refreshed = false
        var reRegistered = false
        while (true) {
            try {
                return op(ensureSession(creds), creds)
            } catch (e: KiaApiException) {
                val session = sessions.load() ?: throw e
                when {
                    e.isLoginExpired && !refreshed -> {
                        refreshed = true
                        sessions.save(session.copy(accessToken = null, controlToken = null))
                    }
                    e.isDeviceRejected && !reRegistered -> {
                        reRegistered = true
                        sessions.save(session.copy(deviceId = null, controlToken = null))
                    }
                    else -> throw e
                }
            }
        }
    }

    private suspend fun ensureSession(creds: Credentials): KiaSession {
        val hash = KiaSession.fingerprint(creds.apiKey)
        var s = sessions.load()?.takeIf { it.enteredTokenHash == hash } ?: KiaSession(hash, creds.apiKey)
        if (s.accessToken == null || clock.millis() >= s.accessExpiresAtMs - REFRESH_MARGIN_MS) s = save(refreshLogin(s))
        if (s.deviceId == null) s = save(registerDevice(s))
        val wanted = creds.vin.trim().uppercase()
        if (s.vehicleId == null || s.selectedFor != wanted) s = save(selectVehicle(s, wanted))
        return s
    }

    private suspend fun save(s: KiaSession): KiaSession = s.also { sessions.save(it) }

    // ---- Login ----------------------------------------------------------------------------------

    private suspend fun refreshLogin(s: KiaSession): KiaSession {
        val form = FormBody.Builder()
            .add("grant_type", "refresh_token")
            .add("refresh_token", s.refreshToken)
            .add("client_id", config.serviceId)
            .add("client_secret", config.serviceSecret)
            .build()
        val request = Request.Builder().url("${config.idpBase}/auth/api/v2/user/oauth2/token")
            .header("User-Agent", KiaConfig.USER_AGENT).post(form).build()
        val (code, text) = exchange(request)
        val body = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull()
        val access = body?.get("access_token").str()
        if (body == null || code !in 200..299 || access == null) {
            if (code in 500..599) throw KiaFailure(ApiError.Server(code, "login"), code)
            throw KiaFailure(ApiError.LoginFailed("Kia rejected the refresh token", 401), 401)
        }
        val type = body["token_type"].str() ?: "Bearer"
        val expiresIn = body["expires_in"].num()?.toLong() ?: 3600
        return s.copy(
            refreshToken = body["refresh_token"].str() ?: s.refreshToken,
            accessToken = "$type $access",
            accessExpiresAtMs = clock.millis() + expiresIn * 1000,
            controlToken = null,
        )
    }

    private suspend fun registerDevice(s: KiaSession): KiaSession {
        val pushId = (1..64).map { HEX[random.nextInt(16)] }.joinToString("")
        val body = buildJsonObject {
            put("pushRegId", pushId)
            put("pushType", "APNS")
            put("uuid", UUID(random.nextLong(), random.nextLong()).toString())
        }
        val headers = Headers.Builder()
            .add("ccsp-service-id", config.serviceId)
            .add("ccsp-application-id", config.appId)
            .add("Stamp", config.stamp(clock.instant().epochSecond))
            .add("User-Agent", KiaConfig.USER_AGENT)
            .build()
        val res = post("${config.spa}/notifications/register", headers, body)
        val deviceId = res.path("resMsg.deviceId").str() ?: throw KiaApiException(200, null, "no deviceId")
        return s.copy(deviceId = deviceId, controlToken = null)
    }

    private suspend fun selectVehicle(s: KiaSession, wantedVin: String): KiaSession {
        val res = get("${config.spa}/vehicles", authHeaders(s, ccs2 = 0))
        val vehicles = (res.path("resMsg.vehicles") as? JsonArray).orEmpty()
        val chosen = if (wantedVin.isNotEmpty()) {
            vehicles.firstOrNull { it.path("vin").str().equals(wantedVin, ignoreCase = true) }
        } else {
            vehicles.firstOrNull { it.path("type").str() == "EV" } ?: vehicles.firstOrNull()
        } ?: throw KiaFailure(ApiError.VehicleNotFound(null), 404)
        return s.copy(
            vehicleId = chosen.path("vehicleId").str() ?: throw KiaApiException(200, null, "no vehicleId"),
            vehicleVin = chosen.path("vin").str(),
            selectedFor = wantedVin,
            ccs2 = chosen.path("ccuCCS2ProtocolSupport").num()?.toInt() ?: 0,
        )
    }

    /** CCS2 commands need a short-lived control token, obtained with the Kia Connect PIN. */
    private suspend fun controlHeaders(s: KiaSession, creds: Credentials): Headers {
        val pin = creds.pin?.takeIf { it.isNotBlank() }
            ?: throw KiaFailure(ApiError.LoginFailed("this car needs your Kia Connect PIN for climate commands", 401), 401)
        var session = s
        if (session.controlToken == null || clock.millis() >= session.controlExpiresAtMs - 30_000) {
            val request = Request.Builder().url("${config.user}/pin?token=")
                .header("Authorization", s.accessToken!!)
                .header("User-Agent", KiaConfig.USER_AGENT)
                .put(buildJsonObject { put("deviceId", s.deviceId); put("pin", pin) }.toString().toRequestBody(JSON))
                .build()
            val (code, text) = exchange(request)
            val body = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull()
            val token = body?.get("controlToken").str()
            if (body == null || token == null) {
                if (code == 401 || (body != null && KiaApiException.from(code, body).isLoginExpired)) throw KiaApiException(401, "7501", "login expired")
                throw KiaFailure(ApiError.LoginFailed("Kia Connect PIN rejected", 401), 401)
            }
            val expires = body["expiresTime"].num()?.toLong() ?: 600
            session = save(s.copy(controlToken = "Bearer $token", controlExpiresAtMs = clock.millis() + expires * 1000))
        }
        return authHeaders(session).newBuilder()
            .set("Authorization", session.controlToken!!)
            .set("AuthorizationCCSP", session.controlToken!!)
            .build()
    }

    private fun authHeaders(s: KiaSession, ccs2: Int = s.ccs2): Headers = Headers.Builder()
        .add("Authorization", s.accessToken!!)
        .add("ccsp-service-id", config.serviceId)
        .add("ccsp-application-id", config.appId)
        .add("Stamp", config.stamp(clock.instant().epochSecond))
        .add("ccsp-device-id", s.deviceId!!)
        .add("Ccuccs2protocolsupport", ccs2.toString())
        .add("User-Agent", KiaConfig.USER_AGENT)
        .build()

    // ---- HTTP -----------------------------------------------------------------------------------

    private suspend fun get(url: String, headers: Headers): JsonObject =
        parse(exchange(Request.Builder().url(url).headers(headers).get().build()))

    private suspend fun post(url: String, headers: Headers, body: JsonObject): JsonObject =
        parse(exchange(Request.Builder().url(url).headers(headers).post(body.toString().toRequestBody(JSON)).build()))

    private suspend fun exchange(request: Request): Pair<Int, String> = withContext(Dispatchers.IO) {
        http.newCall(request).execute().use { it.code to (it.body?.string() ?: "") }
    }

    /** Kia signals failure with retCode "F" (often on HTTP 200 or 400), or an OAuth-style "error" field. */
    private fun parse(response: Pair<Int, String>): JsonObject {
        val (code, text) = response
        val body = runCatching { json.parseToJsonElement(text) as? JsonObject }.getOrNull()
        if (body == null) {
            if (code in 200..299) throw KiaFailure(ApiError.BadResponse(code, "not JSON"), code)
            throw KiaApiException(code, null, null)
        }
        val e = KiaApiException.from(code, body)
        if (code !in 200..299 || body["retCode"].str() == "F" || e.isLoginExpired) throw e
        return body
    }

    private fun map(e: KiaApiException): ApiError = when {
        e.isLoginExpired -> ApiError.LoginFailed("Kia Connect login no longer accepted", 401)
        e.resCode == "5091" -> ApiError.RateLimited(1.hours)
        e.resCode in BUSY_CODES -> ApiError.VehicleNotAcceptingRequests(2.minutes)
        e.resCode == "4005" -> ApiError.OperationNotSupported(e.resCode)
        e.httpCode == 404 -> ApiError.VehicleNotFound(e.resCode)
        e.httpCode in 500..599 -> ApiError.Server(e.httpCode, e.resCode)
        else -> ApiError.Http(e.httpCode, e.resCode ?: e.detail?.take(60))
    }

    /** The status to record: auth failures as 401 so they don't count against the budget, Kia's limit as 429. */
    private fun metaCode(e: KiaApiException, error: ApiError): Int = when (error) {
        is ApiError.LoginFailed -> 401
        is ApiError.RateLimited -> 429
        else -> e.httpCode
    }

    companion object {
        private val JSON = "application/json;charset=UTF-8".toMediaType()
        private const val HEX = "0123456789abcdef"
        private const val REFRESH_MARGIN_MS = 5 * 60_000L

        /** Remote control temporarily unavailable, request timeout, undefined/response timeout, duplicate request. */
        private val BUSY_CODES = setOf("5031", "4081", "9999", "4004")

        fun roundToHalf(c: Double): Double = Math.round(c * 2) / 2.0
    }
}

/** An error Kia returned, before mapping. */
internal class KiaApiException(val httpCode: Int, val resCode: String?, val detail: String?) : Exception("Kia $httpCode $resCode") {
    val isLoginExpired: Boolean
        get() = resCode == "7501" || httpCode == 401 ||
            detail?.lowercase()?.let { "token is expired" in it || "token has expired" in it || "unexpected statuscode" in it } == true

    /** The server dropped the registered device (it does this when push delivery fails). */
    val isDeviceRejected: Boolean get() = resCode == "4002"

    companion object {
        fun from(code: Int, body: JsonObject): KiaApiException {
            val error = body["error"]
            val detail = body["resMsg"].str() ?: body["retMsg"].str() ?: error.str() ?: (error as? JsonObject)?.toString()
            return KiaApiException(code, body["resCode"].str(), detail)
        }
    }
}

/** A failure already mapped to an [ApiError]. */
internal class KiaFailure(val error: ApiError, val httpCode: Int) : Exception(error.message)
