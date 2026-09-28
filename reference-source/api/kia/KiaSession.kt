package app.elroq.precondition.api.kia

import kotlinx.serialization.Serializable
import java.security.MessageDigest

/**
 * Login state kept between requests. Holds secrets (tokens), so stores must encrypt it and it must
 * never be logged or exported.
 */
@Serializable
data class KiaSession(
    /** Fingerprint of the refresh token the user entered; entering a different one starts over. */
    val enteredTokenHash: String,
    /** Current refresh token. Kia may rotate it, so this can differ from the one entered. */
    val refreshToken: String,
    val accessToken: String? = null,
    val accessExpiresAtMs: Long = 0,
    val deviceId: String? = null,
    val vehicleId: String? = null,
    val vehicleVin: String? = null,
    /** The VIN setting the vehicle was picked for ("" = first EV on the account). */
    val selectedFor: String? = null,
    /** ccuCCS2ProtocolSupport from the vehicle list: 0 for older cars, non-zero for the CCS2 protocol. */
    val ccs2: Int = 0,
    val controlToken: String? = null,
    val controlExpiresAtMs: Long = 0,
) {
    companion object {
        fun fingerprint(token: String): String =
            MessageDigest.getInstance("SHA-256").digest(token.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}

interface KiaSessionStore {
    suspend fun load(): KiaSession?
    suspend fun save(session: KiaSession?)
}

class InMemoryKiaSessionStore(var session: KiaSession? = null) : KiaSessionStore {
    override suspend fun load(): KiaSession? = session
    override suspend fun save(session: KiaSession?) {
        this.session = session
    }
}
