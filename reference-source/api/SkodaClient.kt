package app.elroq.precondition.api

import app.elroq.precondition.rules.VehicleSnapshot
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import okhttp3.ResponseBody
import retrofit2.Response
import java.io.IOException
import java.time.Clock
import kotlin.math.roundToInt

/**
 * What the user entered. For Škoda: API key and VIN. For Kia: refresh token (as [apiKey]), optional VIN
 * to pick the car, and the Kia Connect PIN needed for some remote commands.
 */
data class Credentials(val apiKey: String, val vin: String, val pin: String? = null)

fun interface CredentialsProvider {
    suspend fun credentials(): Credentials?
}

/** Receives metadata from every response that arrived (key expiry, rate headers, auth failures). */
fun interface ApiMetaSink {
    suspend fun onResponse(meta: ResponseMeta, error: ApiError?)
}

sealed interface ApiResult<out T> {
    val meta: ResponseMeta?

    data class Success<T>(val value: T, override val meta: ResponseMeta) : ApiResult<T>
    data class Failure(val error: ApiError, override val meta: ResponseMeta? = null) : ApiResult<Nothing>
}

data class VehicleFetch(val snapshot: VehicleSnapshot, val rawJson: String)

/**
 * A car's remote API as the engine sees it. Every call goes through a [RateBudget] and reports
 * back an [ApiResult]; implementations exist for Škoda ([SkodaClient]) and Kia (`KiaClient`).
 */
interface VehicleApi {
    suspend fun getVehicle(kind: RequestKind): ApiResult<VehicleFetch>
    suspend fun startClimate(targetC: Double, kind: RequestKind, withoutExternalPower: Boolean = true): ApiResult<Unit>
    suspend fun stopClimate(kind: RequestKind): ApiResult<Unit>
}

/**
 * The only way into the Škoda API. Every call takes a slot from [RateBudget] first and reports the
 * response headers back to it, so the budget is right even when requests fail.
 */
class SkodaClient(
    private val service: SkodaApiService,
    private val budget: RateBudget,
    private val credentials: CredentialsProvider,
    private val metaSink: ApiMetaSink,
    private val clock: Clock,
    private val json: Json = defaultJson,
) : VehicleApi {
    override suspend fun getVehicle(kind: RequestKind): ApiResult<VehicleFetch> =
        call(kind, { c -> service.getVehicle(c.apiKey, c.vin) }) { meta, body ->
            val text = body ?: throw IllegalStateException("empty body")
            val element = json.parseToJsonElement(text)
            val dto = json.decodeFromJsonElement(VehicleResponseDto.serializer(), element)
            VehicleFetch(VehicleMapper.toSnapshot(dto, element, meta.receivedAt), text)
        }

    override suspend fun startClimate(targetC: Double, kind: RequestKind, withoutExternalPower: Boolean): ApiResult<Unit> {
        val request = StartAirConditioningRequest(
            targetTemperature = TemperatureDto(roundToHalf(targetC), "CELSIUS"),
            airConditioningWithoutExternalPower = withoutExternalPower,
        )
        return call(kind, { c -> service.startAirConditioning(c.apiKey, c.vin, request) }) { _, _ -> }
    }

    override suspend fun stopClimate(kind: RequestKind): ApiResult<Unit> =
        call(kind, { c -> service.stopAirConditioning(c.apiKey, c.vin) }) { _, _ -> }

    private suspend fun <T> call(
        kind: RequestKind,
        request: suspend (Credentials) -> Response<ResponseBody>,
        onSuccess: (ResponseMeta, String?) -> T,
    ): ApiResult<T> {
        val creds = credentials.credentials() ?: return ApiResult.Failure(ApiError.NotConfigured)
        val ticket = budget.tryAcquire(kind) ?: return ApiResult.Failure(ApiError.BudgetExhausted(kind))

        val response = try {
            request(creds)
        } catch (e: CancellationException) {
            budget.complete(ticket, null)
            throw e
        } catch (e: IOException) {
            budget.complete(ticket, null)
            return ApiResult.Failure(ApiError.Network(e.message ?: e.javaClass.simpleName))
        } catch (e: RuntimeException) {
            budget.complete(ticket, null)
            return ApiResult.Failure(ApiError.Network(e.message ?: e.javaClass.simpleName))
        }

        val meta = HeaderParser.parse(response.code(), { response.headers()[it] }, clock.instant())
        val body = try {
            (if (response.isSuccessful) response.body() else response.errorBody())?.use { it.string() }
        } catch (e: IOException) {
            null
        }

        if (!response.isSuccessful) {
            val error = ErrorMapper.map(meta, body)
            budget.complete(ticket, meta, error)
            metaSink.onResponse(meta, error)
            return ApiResult.Failure(error, meta)
        }

        budget.complete(ticket, meta)
        metaSink.onResponse(meta, null)
        return try {
            ApiResult.Success(onSuccess(meta, body?.takeIf { it.isNotBlank() }), meta)
        } catch (e: Exception) {
            ApiResult.Failure(ApiError.BadResponse(meta.httpCode, e.message ?: e.javaClass.simpleName), meta)
        }
    }

    companion object {
        val defaultJson = Json {
            ignoreUnknownKeys = true
            explicitNulls = false
            coerceInputValues = true
            isLenient = true
        }

        /** MyŠkoda offers target temperatures in 0.5 °C steps; round to match. */
        fun roundToHalf(c: Double): Double = (c * 2).roundToInt() / 2.0
    }
}
