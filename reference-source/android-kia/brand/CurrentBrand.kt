package app.elroq.precondition.brand

import kotlin.time.Duration.Companion.hours

val CurrentBrand = BrandConfig(
    appName = "EV6 Precondition",
    carName = "EV6",
    maker = "Kia",
    service = "Kia Connect",
    secretName = "refresh token",
    vinRequired = false,
    hasWithoutExternalPower = false,
    setupBanner = "Add your Kia Connect refresh token to connect your car.",
    authHelp = "Get a new Kia Connect refresh token (and check your PIN) and paste it in Settings.",
    rateLimitHelp = "Kia allows roughly 200 requests a day per account, and one read here makes about two. " +
        "The app counts its own reads and commands against this daily budget and always leaves the reserve for you.",
    rateLimitLabel = "Requests per 24 hours",
    defaultRateLimit = 80,
    defaultManualReserve = 8,
    budgetWindow = 24.hours,
    budgetLabel = "Requests in the last 24 h",
    backupFolder = "EV6Precondition",
    fileStem = "ev6",
)
