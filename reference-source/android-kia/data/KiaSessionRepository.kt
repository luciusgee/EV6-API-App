package app.elroq.precondition.data

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import app.elroq.precondition.api.kia.KiaSession
import app.elroq.precondition.api.kia.KiaSessionStore
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Named
import javax.inject.Singleton

/**
 * The Kia login (tokens, device id, chosen car), encrypted with the Keystore like the refresh token.
 * Fake-car mode keeps its own slot so trying the simulator never throws away a rotated real token.
 */
@Singleton
class KiaSessionRepository @Inject constructor(
    @Named("settings") private val store: DataStore<Preferences>,
    private val keyStore: SecureKeyStore,
    private val settings: SettingsRepository,
) : KiaSessionStore {
    private val json = Json { ignoreUnknownKeys = true }

    private suspend fun key() = stringPreferencesKey(if (settings.current().fakeCar) "kia_session_fake" else "kia_session_encrypted")

    override suspend fun load(): KiaSession? {
        val encrypted = store.data.first()[key()] ?: return null
        val text = keyStore.decrypt(encrypted) ?: return null
        return runCatching { json.decodeFromString(KiaSession.serializer(), text) }.getOrNull()
    }

    override suspend fun save(session: KiaSession?) {
        val k = key()
        val encrypted = session?.let { keyStore.encrypt(json.encodeToString(KiaSession.serializer(), it)) }
        store.edit { prefs ->
            if (encrypted == null) {
                prefs.remove(k)
                return@edit
            }
            prefs[k] = encrypted
        }
    }
}
