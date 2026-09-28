package app.elroq.precondition.weather

import app.elroq.precondition.api.FakeCar
import app.elroq.precondition.api.FakeRouter
import app.elroq.precondition.api.MutableClock
import app.elroq.precondition.rules.LatLon
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Test
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

class FakeWeatherTest {
    private val clock = MutableClock()
    private var temp = -4.5
    private val router = FakeRouter(FakeCar(clock), FakeWeather(clock) { temp })
    private val http = OkHttpClient.Builder().addInterceptor(router).build()

    @Test
    fun `fake weather serves the simulator temperature`() = runTest {
        router.enabled = true
        val service = Retrofit.Builder()
            .baseUrl(OpenMeteoService.BASE_URL)
            .client(http)
            .addConverterFactory(Json { ignoreUnknownKeys = true }.asConverterFactory("application/json".toMediaType()))
            .build()
            .create(OpenMeteoService::class.java)
        val repo = WeatherRepository(service, clock)
        assertEquals(-4.5, repo.current(LatLon(50.0, 14.0))!!.celsius, 0.0)
        assertEquals(-4.5, repo.forecastAt(LatLon(50.0, 14.0), clock.instant().plusSeconds(3600))!!.celsius, 0.0)
    }

    @Test
    fun `router routes by host and passes through when off`() {
        val server = MockWebServer().apply { start() }
        server.enqueue(MockResponse().setBody("real"))
        server.enqueue(MockResponse().setBody("other"))
        fun get(url: String) = http.newCall(Request.Builder().url(url).build()).execute().use { it.body!!.string() }

        router.enabled = false
        assertEquals("real", get(server.url("/v1/forecast").toString()))
        router.enabled = true
        assertEquals("other", get(server.url("/elsewhere").toString())) // unknown host goes to the network
        val skoda = get("https://public.api.connect.skoda-auto.cz/api/v1/vehicles/X")
        assertEquals(true, skoda.contains("\"vehicle\""))
        server.shutdown()
    }
}
