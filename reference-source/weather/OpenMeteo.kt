package app.elroq.precondition.weather

import app.elroq.precondition.rules.LatLon
import app.elroq.precondition.rules.TempReading
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import retrofit2.http.GET
import retrofit2.http.Query
import java.time.Clock
import java.time.Instant
import java.util.Locale
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes

interface OpenMeteoService {
    @GET("v1/forecast")
    suspend fun forecast(
        @Query("latitude") latitude: String,
        @Query("longitude") longitude: String,
        @Query("current") current: String = "temperature_2m",
        @Query("hourly") hourly: String = "temperature_2m",
        @Query("forecast_days") forecastDays: Int = 2,
        @Query("timeformat") timeFormat: String = "unixtime",
        @Query("timezone") timezone: String = "GMT",
    ): OpenMeteoResponse

    companion object {
        const val BASE_URL = "https://api.open-meteo.com/"
    }
}

@Serializable
data class OpenMeteoResponse(
    val current: Current? = null,
    val hourly: Hourly? = null,
) {
    @Serializable
    data class Current(
        val time: Long,
        @SerialName("temperature_2m") val temperature: Double? = null,
    )

    @Serializable
    data class Hourly(
        val time: List<Long> = emptyList(),
        @SerialName("temperature_2m") val temperature: List<Double?> = emptyList(),
    )
}

/** Weather at a point, with a cache so rules evaluated close together share one call. */
interface WeatherSource {
    suspend fun current(at: LatLon): TempReading?
    suspend fun forecastAt(at: LatLon, time: Instant): TempReading?
}

class WeatherRepository(
    private val service: OpenMeteoService,
    private val clock: Clock,
    private val ttl: Duration = 15.minutes,
) : WeatherSource {
    private data class Entry(val fetchedAt: Instant, val response: OpenMeteoResponse)

    private val mutex = Mutex()
    private val cache = mutableMapOf<String, Entry>()

    /** Last failure, for logging when a reading comes back null. */
    @Volatile
    var lastError: String? = null
        private set

    override suspend fun current(at: LatLon): TempReading? {
        val entry = fetch(at) ?: return null
        val c = entry.response.current ?: return null
        val temp = c.temperature ?: return null
        return TempReading(temp, "Open-Meteo", Instant.ofEpochSecond(c.time))
    }

    /** Linear interpolation between the two hourly values around [time]. */
    override suspend fun forecastAt(at: LatLon, time: Instant): TempReading? {
        val hourly = fetch(at)?.response?.hourly ?: return null
        val t = time.epochSecond
        val points = hourly.time.zip(hourly.temperature)
            .mapNotNull { (ts, temp) -> temp?.let { ts to it } }
            .sortedBy { it.first }
        if (points.isEmpty()) return null
        val after = points.indexOfFirst { it.first >= t }
        val value = when {
            after == -1 -> return null // beyond the forecast range
            after == 0 -> if (points[0].first - t <= 3600) points[0].second else return null
            else -> {
                val (t0, v0) = points[after - 1]
                val (t1, v1) = points[after]
                if (t1 == t0) v1 else v0 + (v1 - v0) * (t - t0).toDouble() / (t1 - t0)
            }
        }
        return TempReading(value, "Open-Meteo forecast", time)
    }

    private suspend fun fetch(at: LatLon): Entry? = mutex.withLock {
        val key = key(at)
        val now = clock.instant()
        cache[key]?.takeIf { now.isBefore(it.fetchedAt.plusMillis(ttl.inWholeMilliseconds)) }?.let { return it }
        try {
            val response = service.forecast(coord(at.lat), coord(at.lon))
            lastError = null
            Entry(now, response).also { cache[key] = it }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            lastError = e.message ?: e.javaClass.simpleName
            null
        }
    }

    /** ~100 m grid: nearby points share a cache entry, and Open-Meteo's grid is coarser anyway. */
    private fun key(at: LatLon) = coord(at.lat) + "," + coord(at.lon)

    private fun coord(d: Double) = String.format(Locale.ROOT, "%.3f", d)
}
