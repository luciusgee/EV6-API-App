package app.elroq.precondition.ui.settings

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import app.elroq.precondition.data.AppSettings
import app.elroq.precondition.engine.AutomationState
import app.elroq.precondition.ui.common.KeyValue
import app.elroq.precondition.ui.common.SectionCard

/** Kia's refresh tokens are 48 upper-case letters and digits. */
private val tokenShape = Regex("^[A-Z0-9]{48}$")

/**
 * Kia Connect has no public API. The app signs in with a refresh token taken from a Kia Connect
 * login in a browser, plus the Kia Connect PIN for climate commands on newer cars.
 */
@Composable
internal fun CredentialsSection(s: AppSettings, auto: AutomationState, vm: SettingsViewModel) {
    var token by remember { mutableStateOf("") }
    var pin by remember { mutableStateOf("") }
    var vin by remember(s.vin) { mutableStateOf(s.vin) }
    val context = LocalContext.current
    fun open(url: String) = context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))

    SectionCard(title = "Kia Connect") {
        Text(
            "Kia has no public API, so this uses the Kia Connect app's own service (Europe). It can stop working " +
                "whenever Kia changes it. Sign in once in a browser to get a refresh token, then paste it here. " +
                "The token and PIN are encrypted with the Android Keystore and never logged or exported.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        KeyValue("Refresh token", if (s.hasApiKey) "saved" else "not set")
        KeyValue("PIN", if (s.hasPin) "saved" else "not set")
        auto.authFailure?.let { Text("Problem: $it", color = MaterialTheme.colorScheme.error) }

        OutlinedTextField(
            value = token, onValueChange = { token = it.trim() },
            label = { Text(if (s.hasApiKey) "Replace refresh token" else "Refresh token") },
            supportingText = if (token.isNotEmpty() && !tokenShape.matches(token)) {
                { Text("Kia tokens are usually 48 capital letters and digits") }
            } else null,
            visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = { vm.saveApiKey(token); token = "" }, enabled = token.isNotBlank()) { Text("Save token") }
            if (s.hasApiKey) TextButton(onClick = { vm.saveApiKey("") }) { Text("Remove") }
        }
        TextButton(onClick = { open(TOKEN_GUIDE) }) { Text("How to get a refresh token") }

        OutlinedTextField(
            value = pin, onValueChange = { v -> pin = v.filter { it.isDigit() }.take(8) },
            label = { Text(if (s.hasPin) "Replace Kia Connect PIN" else "Kia Connect PIN") },
            supportingText = { Text("Needed for climate commands on 2024-on cars; older EV6s don't use it") },
            visualTransformation = PasswordVisualTransformation(), singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword), modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = { vm.savePin(pin); pin = "" }, enabled = pin.length >= 4) { Text("Save PIN") }
            if (s.hasPin) TextButton(onClick = { vm.savePin("") }) { Text("Remove") }
        }

        OutlinedTextField(
            value = vin, onValueChange = { vin = it.uppercase() },
            label = { Text("VIN (optional)") },
            supportingText = { Text("Only if the account has more than one car; otherwise the first EV is used") },
            singleLine = true, modifier = Modifier.fillMaxWidth(),
        )
        Button(onClick = { vm.saveVin(vin) }, enabled = (vin.trim().isEmpty() || vin.trim().length == 17) && vin.trim() != s.vin) { Text("Save VIN") }
    }
}

/** Community guide: "How to get the token (new login method) & battery-safe settings". */
private const val TOKEN_GUIDE = "https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/discussions/987"
