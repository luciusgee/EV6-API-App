package app.elroq.precondition.api

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import kotlin.time.Duration.Companion.seconds

class HeaderParserTest {
    private val now = Instant.parse("2026-09-23T15:00:00Z")

    private fun parse(vararg headers: Pair<String, String>, code: Int = 200): ResponseMeta {
        val map = headers.associate { it.first.lowercase() to it.second }
        return HeaderParser.parse(code, { map[it.lowercase()] }, now)
    }

    @Test
    fun `parses rate limit headers`() {
        val meta = parse("RateLimit-Limit" to "20", "RateLimit-Remaining" to "13", "RateLimit-Reset" to "1200")
        assertEquals(20, meta.rateLimit)
        assertEquals(13, meta.rateRemaining)
        assertEquals(now.plusSeconds(1200), meta.rateResetAt)
    }

    @Test
    fun `tolerates policy suffixes and epoch resets`() {
        val meta = parse("RateLimit-Limit" to "20;w=3600", "RateLimit-Reset" to "1790000000")
        assertEquals(20, meta.rateLimit)
        assertEquals(Instant.ofEpochSecond(1_790_000_000), meta.rateResetAt)
    }

    @Test
    fun `missing headers are null`() {
        val meta = parse()
        assertNull(meta.rateLimit)
        assertNull(meta.rateRemaining)
        assertNull(meta.rateResetAt)
        assertNull(meta.retryAfter)
        assertNull(meta.apiKeyExpiresAt)
    }

    @Test
    fun `parses retry-after as seconds or date`() {
        assertEquals(120.seconds, parse("Retry-After" to "120").retryAfter)
        assertEquals(60.seconds, parse("Retry-After" to "Wed, 23 Sep 2026 15:01:00 GMT").retryAfter)
        assertNull(parse("Retry-After" to "soon").retryAfter)
    }

    @Test
    fun `parses key expiry in several formats`() {
        val expected = Instant.parse("2026-12-01T00:00:00Z")
        assertEquals(expected, parse("X-API-Key-Expires-At" to "2026-12-01T00:00:00Z").apiKeyExpiresAt)
        assertEquals(expected, parse("X-API-Key-Expires-At" to "2026-12-01T01:00:00+01:00").apiKeyExpiresAt)
        assertEquals(expected, parse("X-API-Key-Expires-At" to "Tue, 1 Dec 2026 00:00:00 GMT").apiKeyExpiresAt)
        assertEquals(expected, parse("X-API-Key-Expires-At" to expected.epochSecond.toString()).apiKeyExpiresAt)
        assertEquals(expected, parse("X-API-Key-Expires-At" to expected.toEpochMilli().toString()).apiKeyExpiresAt)
        assertNull(parse("X-API-Key-Expires-At" to "never").apiKeyExpiresAt)
    }
}

class ErrorMapperTest {
    private fun meta(code: Int) = ResponseMeta(code, Instant.EPOCH, retryAfter = 30.seconds)

    @Test
    fun `maps auth errors`() {
        val expired = ErrorMapper.map(meta(401), """{"type":"api-key-expired","title":"API key expired"}""")
        assertTrue(expired is ApiError.KeyExpired)
        assertTrue(expired.isAuthFailure)
        val invalid = ErrorMapper.map(meta(401), """{"code":"api-key-invalid"}""")
        assertEquals(ApiError.KeyNotAuthorized(401, "api-key-invalid"), invalid)
        assertTrue(invalid.isAuthFailure)
        val forbidden = ErrorMapper.map(meta(403), """{"error":{"code":"api-key-not-authorized"}}""")
        assertEquals(ApiError.KeyNotAuthorized(403, "api-key-not-authorized"), forbidden)
        assertTrue(forbidden.message.contains("not authorised"))
    }

    @Test
    fun `maps unsupported and disabled operations`() {
        assertTrue(ErrorMapper.map(meta(422), """{"type":"operation-not-supported"}""") is ApiError.OperationNotSupported)
        assertTrue(ErrorMapper.map(meta(422), """{"detail":"operation-disabled for vehicle"}""") is ApiError.OperationDisabled)
        assertTrue(ErrorMapper.map(meta(422), null) is ApiError.OperationNotSupported)
    }

    @Test
    fun `tells the two 429s apart`() {
        val rate = ErrorMapper.map(meta(429), """{"type":"rate-limit-exceeded"}""")
        assertEquals(ApiError.RateLimited(30.seconds), rate)
        val busy = ErrorMapper.map(meta(429), """{"type":"https://example/errors/vehicle-not-accepting-requests"}""")
        assertEquals(ApiError.VehicleNotAcceptingRequests(30.seconds), busy)
        assertFalse(busy.isAuthFailure)
        // Not JSON at all: fall back to searching the text.
        assertTrue(ErrorMapper.map(meta(429), "vehicle-not-accepting-requests") is ApiError.VehicleNotAcceptingRequests)
    }

    @Test
    fun `maps everything else`() {
        assertTrue(ErrorMapper.map(meta(404), null) is ApiError.VehicleNotFound)
        assertEquals(ApiError.Server(503, "unavailable"), ErrorMapper.map(meta(503), """{"code":"unavailable"}"""))
        assertEquals(ApiError.Http(400, null), ErrorMapper.map(meta(400), "<html>"))
        assertEquals(null, ErrorMapper.errorCode("""{"code":"${"x".repeat(100)}"}"""))
    }

    @Test
    fun `messages are readable`() {
        listOf(
            ApiError.NotConfigured, ApiError.BudgetExhausted(RequestKind.MANUAL), ApiError.KeyExpired(null),
            ApiError.VehicleNotFound(null), ApiError.OperationDisabled(null), ApiError.RateLimited(null),
            ApiError.VehicleNotAcceptingRequests(null), ApiError.Server(500, null), ApiError.Http(418, "teapot"),
            ApiError.Network("timeout"), ApiError.BadResponse(200, "eof"),
        ).forEach { assertTrue(it.toString(), it.message.isNotBlank()) }
        assertEquals("rate budget exhausted for manual requests", ApiError.BudgetExhausted(RequestKind.MANUAL).message)
    }
}

class MaskingTest {
    @Test
    fun `masks all but the last four characters`() {
        assertEquals("*************0123", maskVin(TEST_VIN))
        assertEquals("abc", maskVin("abc"))
        assertEquals("""{"vin":"*************0123"}""", redactVin("""{"vin":"$TEST_VIN"}""", TEST_VIN))
        assertEquals("text", redactVin("text", null))
    }
}
