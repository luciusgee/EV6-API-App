package app.elroq.precondition.api.kia

import java.util.Base64

/**
 * Kia Connect (UVO) Europe. Nothing here is a published API: the values are those the Kia app
 * uses, as documented by the hyundai_kia_connect_api project (v4.23), and Kia can change them.
 */
data class KiaConfig(
    val apiBase: String = "https://$API_HOST:8080",
    val idpBase: String = "https://$IDP_HOST",
    val serviceId: String = "fdc85c00-0a2f-4c64-bcb4-2cfb1500730a",
    val serviceSecret: String = "secret",
    val appId: String = "a2b8469b-30a3-4361-8e13-6fceea8fbe74",
    private val cfbBase64: String = "wLTVxwidmH8CfJYBWSnHD6E0huk0ozdiuygB4hLkM5XCgzAL1Dk5sE36d/bx5PFMbZs=",
    /** How long the car climatises for; Kia requires a duration. */
    val climateMinutes: Int = 10,
) {
    val spa: String get() = "$apiBase/api/v1/spa"
    val spaV2: String get() = "$apiBase/api/v2/spa"
    val user: String get() = "$apiBase/api/v1/user"

    /** The "Stamp" header: "appId:epochSeconds" XORed with a fixed key, base64. */
    fun stamp(epochSeconds: Long): String {
        val cfb = Base64.getDecoder().decode(cfbBase64)
        val raw = "$appId:$epochSeconds".toByteArray()
        val out = ByteArray(minOf(cfb.size, raw.size)) { i -> (cfb[i].toInt() xor raw[i].toInt()).toByte() }
        return Base64.getEncoder().encodeToString(out)
    }

    companion object {
        const val API_HOST = "prd.eu-ccapi.kia.com"
        const val IDP_HOST = "idpconnect-eu.kia.com"
        const val USER_AGENT = "okhttp/3.12.0"

        /** Target temperatures the EU cars accept (non-CCS2 cars send them as an index into this range). */
        const val MIN_TEMP_C = 14.0
        const val MAX_TEMP_C = 29.5
    }
}
