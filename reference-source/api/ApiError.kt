package app.elroq.precondition.api

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlin.time.Duration

sealed interface ApiError {
    val message: String
    val httpCode: Int? get() = null

    /** Stops all automation until the user fixes the key. */
    val isAuthFailure: Boolean get() = this is KeyExpired || this is KeyNotAuthorized || this is LoginFailed

    /** No credentials saved yet; no request was made. */
    data object NotConfigured : ApiError {
        override val message = "API key or VIN not set"
    }

    /** Refused locally because the rate budget has nothing left for this kind of request. */
    data class BudgetExhausted(val kind: RequestKind) : ApiError {
        override val message = "rate budget exhausted for ${kind.name.lowercase()} requests"
    }

    data class KeyExpired(val code: String?) : ApiError {
        override val message = "API key expired"
        override val httpCode = 401
    }

    data class KeyNotAuthorized(override val httpCode: Int, val code: String?) : ApiError {
        override val message = if (httpCode == 401) "API key rejected (${code ?: "invalid"})" else "API key not authorised for this vehicle"
    }

    /** Account login rejected (e.g. Kia refresh token invalid, or PIN wrong). */
    data class LoginFailed(val reason: String, override val httpCode: Int? = null) : ApiError {
        override val message = reason
    }

    data class VehicleNotFound(val code: String?) : ApiError {
        override val message = "vehicle not found — check the VIN"
        override val httpCode = 404
    }

    data class OperationNotSupported(val code: String?) : ApiError {
        override val message = "operation not supported by this vehicle"
        override val httpCode = 422
    }

    data class OperationDisabled(val code: String?) : ApiError {
        override val message = "operation disabled for this vehicle"
        override val httpCode = 422
    }

    data class RateLimited(val retryAfter: Duration?) : ApiError {
        override val message = "rate limit reached" + (retryAfter?.let { ", retry after $it" } ?: "")
        override val httpCode = 429
    }

    /** 429 vehicle-not-accepting-requests: the car is busy or its 12 V battery is low. */
    data class VehicleNotAcceptingRequests(val retryAfter: Duration?) : ApiError {
        override val message = "vehicle not accepting requests"
        override val httpCode = 429
    }

    data class Server(override val httpCode: Int, val code: String?) : ApiError {
        override val message = "server error $httpCode" + (code?.let { " ($it)" } ?: "")
    }

    data class Http(override val httpCode: Int, val code: String?) : ApiError {
        override val message = "HTTP $httpCode" + (code?.let { " ($it)" } ?: "")
    }

    data class Network(val cause: String) : ApiError {
        override val message = "network error: $cause"
    }

    data class BadResponse(override val httpCode: Int, val cause: String) : ApiError {
        override val message = "could not read response: $cause"
    }
}

object ErrorMapper {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /** Known error codes from the API docs, as they appear in error bodies. */
    private val knownCodes = listOf(
        "api-key-expired",
        "api-key-not-authorized",
        "operation-not-supported",
        "operation-disabled",
        "vehicle-not-accepting-requests",
        "rate-limit-exceeded",
    )

    fun map(meta: ResponseMeta, body: String?): ApiError {
        val code = errorCode(body)
        return when (meta.httpCode) {
            401 -> if (code?.contains("expired") == true) ApiError.KeyExpired(code) else ApiError.KeyNotAuthorized(401, code)
            403 -> ApiError.KeyNotAuthorized(403, code)
            404 -> ApiError.VehicleNotFound(code)
            422 -> if (code?.contains("disabled") == true) ApiError.OperationDisabled(code) else ApiError.OperationNotSupported(code)
            429 -> if (code?.contains("vehicle-not-accepting") == true) {
                ApiError.VehicleNotAcceptingRequests(meta.retryAfter)
            } else {
                ApiError.RateLimited(meta.retryAfter)
            }
            in 500..599 -> ApiError.Server(meta.httpCode, code)
            else -> ApiError.Http(meta.httpCode, code)
        }
    }

    /**
     * The error body format is not pinned down yet (likely RFC 7807 problem+json), so look for a known
     * code in the usual fields, then anywhere in the body, then fall back to the first short string field.
     */
    fun errorCode(body: String?): String? {
        if (body.isNullOrBlank()) return null
        val lower = body.lowercase()
        val element = runCatching { json.parseToJsonElement(body) }.getOrNull()
        val candidates = element?.let { stringsIn(it) }.orEmpty()
        candidates.map { it.lowercase() }.forEach { s ->
            knownCodes.firstOrNull { s.contains(it) }?.let { return it }
        }
        knownCodes.firstOrNull { lower.contains(it) }?.let { return it }
        val obj = element as? JsonObject ?: return null
        return listOf("code", "errorCode", "error", "type")
            .firstNotNullOfOrNull { (obj[it] as? JsonPrimitive)?.contentOrNull }
            ?.takeIf { it.length <= 80 }
    }

    private fun stringsIn(e: JsonElement): List<String> = when (e) {
        is JsonPrimitive -> listOfNotNull(e.contentOrNull.takeIf { e.isString })
        is JsonObject -> e.values.flatMap { stringsIn(it) }
        is JsonArray -> e.flatMap { stringsIn(it) }
    }
}
