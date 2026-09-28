package app.elroq.precondition.weather

import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import java.time.Clock
import java.time.temporal.ChronoUnit

/** Debug stand-in for Open-Meteo: a flat forecast at whatever temperature the simulator sets. */
class FakeWeather(private val clock: Clock, private val celsius: () -> Double) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val now = clock.instant()
        val t = celsius()
        val start = now.truncatedTo(ChronoUnit.DAYS).epochSecond
        val hours = (0 until 48).map { start + it * 3600L }
        val body = """{"current":{"time":${now.epochSecond},"temperature_2m":$t},""" +
            """"hourly":{"time":[${hours.joinToString(",")}],"temperature_2m":[${hours.joinToString(",") { t.toString() }}]}}"""
        return Response.Builder()
            .request(chain.request())
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }
}
