package app.elroq.precondition.engine

import app.elroq.precondition.api.ApiError
import app.elroq.precondition.api.ApiMetaSink
import app.elroq.precondition.api.ResponseMeta
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Watches every car-API response: stores the key expiry, warns 7 days ahead, and stops automation
 * the moment a 401/403 arrives, whichever code path made the request.
 */
class ApiMonitor(
    private val state: AutomationStateStore,
    private val notifier: Notifier,
    private val log: EventLog,
    private val clock: Clock,
    /** How to fix a rejected login, shown in the notification. Brand-specific. */
    private val authHelp: String = "Create a new API key in the MyŠkoda app and paste it in Settings.",
    private val zone: () -> ZoneId = { ZoneId.systemDefault() },
) : ApiMetaSink {

    override suspend fun onResponse(meta: ResponseMeta, error: ApiError?) {
        if (error != null && error.isAuthFailure) {
            onAuthFailure(error)
            return
        }
        val before = state.load()
        val after = state.update { s ->
            s.copy(
                apiKeyExpiresAtMs = meta.apiKeyExpiresAt?.toEpochMilli() ?: s.apiKeyExpiresAtMs,
                // Any request that got past authentication proves the key works again.
                authFailure = if (meta.httpCode in 200..299) null else s.authFailure,
            )
        }
        if (before.authFailure != null && after.authFailure == null) {
            log.append(LogEntry(clock.instant(), LogKind.INFO, "resumed", "API key accepted again; automation resumed"))
        }
        checkKeyExpiry()
    }

    suspend fun onAuthFailure(error: ApiError) {
        val before = state.load()
        state.update { it.copy(authFailure = error.message) }
        if (before.authFailure == null) {
            log.append(
                LogEntry(clock.instant(), LogKind.ERROR, "stopped", "${error.message}; all automation stopped", httpCode = error.httpCode),
            )
            notifier.problem(
                title = "Automation stopped",
                text = "${error.message.replaceFirstChar { it.uppercase() }}. $authHelp",
                openSettings = true,
            )
        }
    }

    /** Notifies once per expiry date when the key expires within [WARN_BEFORE]. */
    suspend fun checkKeyExpiry() {
        val s = state.load()
        val expiresAt = s.apiKeyExpiresAtMs?.let(Instant::ofEpochMilli) ?: return
        if (s.keyExpiryWarnedForMs == s.apiKeyExpiresAtMs) return
        val now = clock.instant()
        if (Duration.between(now, expiresAt) > WARN_BEFORE) return
        state.update { it.copy(keyExpiryWarnedForMs = s.apiKeyExpiresAtMs) }
        val date = expiresAt.atZone(zone()).format(DateTimeFormatter.ofPattern("EEE d MMM HH:mm"))
        val text = if (expiresAt.isAfter(now)) "Your MyŠkoda API key expires $date. Create a new one and paste it in Settings."
        else "Your MyŠkoda API key expired $date."
        log.append(LogEntry(now, LogKind.INFO, "key expiry", text))
        notifier.problem("API key expiring", text, openSettings = true)
    }

    companion object {
        val WARN_BEFORE: Duration = Duration.ofDays(7)
    }
}
