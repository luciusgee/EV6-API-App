package app.elroq.precondition.api

import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset

class MutableClock(var now: Instant = Instant.parse("2026-09-23T15:00:00Z")) : Clock() {
    override fun getZone(): ZoneId = ZoneOffset.UTC
    override fun withZone(zone: ZoneId?): Clock = this
    override fun instant(): Instant = now
    fun advanceSeconds(s: Long) {
        now = now.plusSeconds(s)
    }
}

class MemoryBudgetStore(var state: RateBudgetState = RateBudgetState()) : RateBudgetStore {
    override suspend fun load() = state
    override suspend fun save(state: RateBudgetState) {
        this.state = state
    }
}

class RecordingMetaSink : ApiMetaSink {
    val seen = mutableListOf<Pair<ResponseMeta, ApiError?>>()
    override suspend fun onResponse(meta: ResponseMeta, error: ApiError?) {
        seen += meta to error
    }
}

const val TEST_VIN = "TMBJB9NY0RF000123"
const val TEST_KEY = "secret-key"
