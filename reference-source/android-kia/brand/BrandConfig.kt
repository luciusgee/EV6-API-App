package app.elroq.precondition.brand

import app.elroq.precondition.api.BudgetConfig
import kotlin.time.Duration

/**
 * Everything that differs between the Škoda and Kia apps apart from the API client, credentials
 * screen and colours. Each flavour defines one as `CurrentBrand` (src/skoda, src/kia).
 */
data class BrandConfig(
    val appName: String,
    /** Short name of the car, as in "My Elroq". */
    val carName: String,
    /** "not affiliated with …" */
    val maker: String,
    /** The manufacturer's app or service the credentials come from. */
    val service: String,
    /** What the saved secret is called in messages ("API key", "refresh token"). */
    val secretName: String,
    val vinRequired: Boolean,
    /** Whether the API has a "climatise without external power" switch. */
    val hasWithoutExternalPower: Boolean,
    val setupBanner: String,
    /** How to fix a rejected login, after "Automation stopped: …". */
    val authHelp: String,
    val rateLimitHelp: String,
    /** Label of the budget-size setting. */
    val rateLimitLabel: String,
    val defaultRateLimit: Int,
    val defaultManualReserve: Int,
    val budgetWindow: Duration,
    /** Label for the budget window on the dashboard, e.g. "Requests this hour". */
    val budgetLabel: String,
    /** Folder under Downloads for the automatic rules backup. */
    val backupFolder: String,
    /** File name stem for backups and exports, e.g. "elroq" → elroq-rules-backup.json. */
    val fileStem: String,
) {
    fun budgetConfig(limit: Int, reserve: Int) = BudgetConfig(fallbackLimit = limit, manualReserve = reserve, window = budgetWindow)
}
