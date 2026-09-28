package app.elroq.precondition.weather

import app.elroq.precondition.api.MutableClock
import app.elroq.precondition.rules.LatLon
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import java.time.Instant

class WeatherRepositoryTest {
    private val server = MockWebServer().apply { start() }
    private val clock = MutableClock(Instant.ofEpochSecond(T0 + 1200))
    private val service = Retrofit.Builder()
        .baseUrl(server.url("/"))
        .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
        .build()
        .create(OpenMeteoService::class.java)
    private val repo = WeatherRepository(service, clock)
    private val here = LatLon(50.08712, 14.42105)

    @After
    fun tearDown() = server.shutdown()

    private fun enqueue() = server.enqueue(
        MockResponse().setBody(
            """{"latitude":50.08,"longitude":14.42,
               "current":{"time":${T0 + 900},"interval":900,"temperature_2m":3.4},
               "hourly":{"time":[$T0,${T0 + 3600},${T0 + 7200}],"temperature_2m":[2.0,4.0,null]}}""",
        ),
    )

    @Test
    fun `current temperature and request parameters`() = runTest {
        enqueue()
        val reading = repo.current(here)!!
        assertEquals(3.4, reading.celsius, 0.0)
        assertEquals("Open-Meteo", reading.source)
        val path = server.takeRequest().path!!
        assertTrue(path, path.startsWith("/v1/forecast?latitude=50.087&longitude=14.421&current=temperature_2m&hourly=temperature_2m"))
        assertTrue(path.contains("timeformat=unixtime"))
    }

    @Test
    fun `forecast interpolates between hours`() = runTest {
        enqueue()
        assertEquals(3.0, repo.forecastAt(here, Instant.ofEpochSecond(T0 + 1800))!!.celsius, 0.001)
        assertEquals(2.0, repo.forecastAt(here, Instant.ofEpochSecond(T0))!!.celsius, 0.001)
        assertEquals(2.0, repo.forecastAt(here, Instant.ofEpochSecond(T0 - 600))!!.celsius, 0.001)
        assertNull(repo.forecastAt(here, Instant.ofEpochSecond(T0 - 7200)))
        // The last hour has no value, so anything past the second point is out of range.
        assertNull(repo.forecastAt(here, Instant.ofEpochSecond(T0 + 5000)))
    }

    @Test
    fun `cached for 15 minutes per location`() = runTest {
        enqueue()
        enqueue()
        repo.current(here)
        repo.current(LatLon(50.0872, 14.4211)) // same ~100 m cell
        repo.forecastAt(here, Instant.ofEpochSecond(T0))
        assertEquals(1, server.requestCount)
        clock.advanceSeconds(15 * 60)
        repo.current(here)
        assertEquals(2, server.requestCount)
    }

    @Test
    fun `failures return null and are remembered`() = runTest {
        server.enqueue(MockResponse().setResponseCode(500))
        assertNull(repo.current(here))
        assertNotNull(repo.lastError)
        enqueue()
        assertNotNull(repo.current(here))
        assertNull(repo.lastError)
    }

    @Test
    fun `missing values are unknown`() = runTest {
        server.enqueue(MockResponse().setBody("""{"current":{"time":$T0},"hourly":{"time":[],"temperature_2m":[]}}"""))
        assertNull(repo.current(here))
        assertNull(repo.forecastAt(here, Instant.ofEpochSecond(T0)))
    }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }
        const val T0 = 1_790_000_000L
    }
}
