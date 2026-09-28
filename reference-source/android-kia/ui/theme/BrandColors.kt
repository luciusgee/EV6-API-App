package app.elroq.precondition.ui.theme

import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.graphics.Color

/** Palette in the spirit of the Kia app: midnight black and cool greys with an electric-cyan accent. */
object Brand {
    val Midnight = Color(0xFF05141F)
    val MidnightDeep = Color(0xFF020B12)
    val MidnightLight = Color(0xFF1D3242)
    val Cyan = Color(0xFF5CE1E6)
    val OnCyan = Color(0xFF032329)
    val Amber = Color(0xFFF2B33D)
    val Red = Color(0xFFE5484D)
}

internal val BrandLightExtra = ExtraColors(
    heroStart = Brand.Midnight,
    heroEnd = Brand.MidnightLight,
    onHero = Color.White,
    onHeroMuted = Color(0xB3FFFFFF),
    accent = Brand.Cyan,
    onAccent = Brand.OnCyan,
    success = Color(0xFF0E7C86),
    warning = Color(0xFFB7791F),
    cardBorder = Color(0xFFE0E5EA),
)

internal val BrandDarkExtra = ExtraColors(
    heroStart = Color(0xFF14283A),
    heroEnd = Brand.MidnightDeep,
    onHero = Color.White,
    onHeroMuted = Color(0xB3FFFFFF),
    accent = Brand.Cyan,
    onAccent = Brand.OnCyan,
    success = Brand.Cyan,
    warning = Brand.Amber,
    cardBorder = Color(0xFF1E2C38),
)

internal val BrandLightScheme = lightColorScheme(
    primary = Brand.Midnight,
    onPrimary = Color.White,
    primaryContainer = Brand.Cyan,
    onPrimaryContainer = Brand.OnCyan,
    secondary = Color(0xFF45566A),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFDCE6EF),
    onSecondaryContainer = Brand.Midnight,
    tertiary = Color(0xFF0E7C86),
    background = Color(0xFFF3F5F7),
    onBackground = Color(0xFF0D141A),
    surface = Color.White,
    onSurface = Color(0xFF0D141A),
    surfaceVariant = Color(0xFFE7ECF0),
    onSurfaceVariant = Color(0xFF55616C),
    surfaceContainer = Color(0xFFF3F5F7),
    surfaceContainerHigh = Color(0xFFEAEEF2),
    outline = Color(0xFFC2CBD3),
    outlineVariant = Color(0xFFE0E5EA),
    error = Color(0xFFB3261E),
    errorContainer = Color(0xFFFCE4E2),
    onErrorContainer = Color(0xFF5F1410),
)

internal val BrandDarkScheme = darkColorScheme(
    primary = Brand.Cyan,
    onPrimary = Brand.OnCyan,
    primaryContainer = Color(0xFF1D3242),
    onPrimaryContainer = Brand.Cyan,
    secondary = Color(0xFFAFC2D3),
    onSecondary = Color(0xFF17293A),
    secondaryContainer = Color(0xFF1B2B3A),
    onSecondaryContainer = Color(0xFFD2E2F0),
    tertiary = Color(0xFF8FD8DE),
    background = Color(0xFF070D12),
    onBackground = Color(0xFFE5ECF2),
    surface = Color(0xFF0F1820),
    onSurface = Color(0xFFE5ECF2),
    surfaceVariant = Color(0xFF18242E),
    onSurfaceVariant = Color(0xFF9CAAB6),
    surfaceContainer = Color(0xFF0C141B),
    surfaceContainerHigh = Color(0xFF15212B),
    outline = Color(0xFF3A4A57),
    outlineVariant = Color(0xFF1E2C38),
    error = Color(0xFFFF8A80),
    errorContainer = Color(0xFF4A1512),
    onErrorContainer = Color(0xFFFFDAD6),
)
