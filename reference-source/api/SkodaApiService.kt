package app.elroq.precondition.api

import okhttp3.ResponseBody
import retrofit2.Response
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.Header
import retrofit2.http.POST
import retrofit2.http.Path
import retrofit2.http.Query

/**
 * Retrofit binding for the MyŠkoda Public API. Only [SkodaClient] may call this: it wraps every
 * request in the rate budget. Responses are kept raw so the client can read headers and error bodies
 * and dump the full vehicle JSON on first run.
 */
interface SkodaApiService {

    @GET("api/v1/vehicles/{vin}")
    suspend fun getVehicle(
        @Header(API_KEY_HEADER) apiKey: String,
        @Path("vin") vin: String,
        @Query("include") include: String = VEHICLE_INCLUDE,
    ): Response<ResponseBody>

    @POST("api/v1/vehicles/{vin}/air-conditioning/start")
    suspend fun startAirConditioning(
        @Header(API_KEY_HEADER) apiKey: String,
        @Path("vin") vin: String,
        @Body body: StartAirConditioningRequest,
    ): Response<ResponseBody>

    @POST("api/v1/vehicles/{vin}/air-conditioning/stop")
    suspend fun stopAirConditioning(
        @Header(API_KEY_HEADER) apiKey: String,
        @Path("vin") vin: String,
    ): Response<ResponseBody>

    companion object {
        const val BASE_URL = "https://public.api.connect.skoda-auto.cz/"
        const val API_KEY_HEADER = "X-API-Key"

        /** Only the sections the rules need; comma-separated as the API expects. */
        const val VEHICLE_INCLUDE = "airConditioning,charging,parkingPosition"
    }
}
