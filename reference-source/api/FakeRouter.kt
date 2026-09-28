package app.elroq.precondition.api

import app.elroq.precondition.api.kia.FakeKia
import app.elroq.precondition.api.kia.KiaConfig
import app.elroq.precondition.weather.FakeWeather
import okhttp3.Interceptor
import okhttp3.Response

/**
 * Sends Škoda, Kia and Open-Meteo traffic to the in-app fakes while fake-car mode is on (debug builds only),
 * and straight through otherwise.
 */
class FakeRouter(private val car: FakeCar, private val weather: FakeWeather, private val kia: FakeKia? = null) : Interceptor {
    @Volatile
    var enabled: Boolean = false

    override fun intercept(chain: Interceptor.Chain): Response {
        if (!enabled) return chain.proceed(chain.request())
        return when (chain.request().url.host) {
            SKODA_HOST -> car.intercept(chain)
            KiaConfig.API_HOST, KiaConfig.IDP_HOST -> kia?.intercept(chain) ?: throw java.io.IOException("no Kia simulator in fake-car mode")
            WEATHER_HOST -> weather.intercept(chain)
            else -> chain.proceed(chain.request())
        }
    }

    private companion object {
        const val SKODA_HOST = "public.api.connect.skoda-auto.cz"
        const val WEATHER_HOST = "api.open-meteo.com"
    }
}
