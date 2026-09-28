package app.elroq.precondition.api

import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** What every car-API response tells us beyond its body. */
data class ResponseMeta(
    val httpCode: Int,
    val receivedAt: Instant,
    val rateLimit: Int? = null,
    val rateRemaining: Int? = null,
    val rateResetAt: Instant? = null,
    val retryAfter: Duration? = null,
    val apiKeyExpiresAt: Instant? = null,
)

object HeaderParser {
    const val RATE_LIMIT = "RateLimit-Limit"
    const val RATE_REMAINING = "RateLimit-Remaining"
    const val RATE_RESET = "RateLimit-Reset"
    const val RETRY_AFTER = "Retry-After"
    const val KEY_EXPIRES_AT = "X-API-Key-Expires-At"

    /** Values above this are epoch seconds rather than delta seconds. */
    private const val EPOCH_THRESHOLD = 1_000_000_000L

    fun parse(httpCode: Int, header: (String) -> String?, now: Instant): ResponseMeta = ResponseMeta(
        httpCode = httpCode,
        receivedAt = now,
        rateLimit = header(RATE_LIMIT)?.let(::firstInt),
        rateRemaining = header(RATE_REMAINING)?.let(::firstInt),
        rateResetAt = header(RATE_RESET)?.let { resetAt(it, now) },
        retryAfter = header(RETRY_AFTER)?.let { retryAfter(it, now) },
        apiKeyExpiresAt = header(KEY_EXPIRES_AT)?.let(::instant),
    )

    /**
     * RateLimit headers may carry a policy suffix ("20;w=3600") or, in the combined draft form,
     * a list; the first integer is the value we want.
     */
    private fun firstInt(raw: String): Int? = Regex("-?\\d+").find(raw)?.value?.toIntOrNull()

    /** RateLimit-Reset is delta seconds per the IETF draft; tolerate epoch seconds too. */
    fun resetAt(raw: String, now: Instant): Instant? {
        val n = Regex("\\d+").find(raw)?.value?.toLongOrNull() ?: return null
        return if (n >= EPOCH_THRESHOLD) Instant.ofEpochSecond(n) else now.plusSeconds(n)
    }

    /** Retry-After is delta seconds or an HTTP date. */
    fun retryAfter(raw: String, now: Instant): Duration? {
        raw.trim().toLongOrNull()?.let { return it.coerceAtLeast(0).seconds }
        return try {
            val date = ZonedDateTime.parse(raw.trim(), DateTimeFormatter.RFC_1123_DATE_TIME).toInstant()
            (date.epochSecond - now.epochSecond).coerceAtLeast(0).seconds
        } catch (e: Exception) {
            null
        }
    }

    fun instant(raw: String): Instant? {
        val text = raw.trim()
        runCatching { return Instant.parse(text) }
        runCatching { return OffsetDateTime.parse(text).toInstant() }
        runCatching { return ZonedDateTime.parse(text, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant() }
        text.toLongOrNull()?.let { return if (it > 100_000_000_000L) Instant.ofEpochMilli(it) else Instant.ofEpochSecond(it) }
        return null
    }
}
