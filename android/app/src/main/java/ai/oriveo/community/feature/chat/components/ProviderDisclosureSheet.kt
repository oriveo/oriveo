package ai.oriveo.community.feature.chat.components

import android.widget.Toast
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowOutward
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.util.openExternalUrl
import ai.oriveo.community.feature.chat.ProviderDisclosurePrompt

/**
 * Consent sheet shown before the first message is sent to a given provider, so the user knows what
 * leaves the device. Required by the Apple and Google Play generative AI content policies.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProviderDisclosureSheet(
    prompt: ProviderDisclosurePrompt,
    onAccept: () -> Unit,
    onCancel: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val context = LocalContext.current

    ModalBottomSheet(
        onDismissRequest = onCancel,
        sheetState = sheetState,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        contentWindowInsets = { androidx.compose.foundation.layout.WindowInsets(0, 0, 0, 0) },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(
                imageVector = Icons.Outlined.PanTool,
                contentDescription = null,
                modifier = Modifier.size(44.dp),
                tint = MaterialTheme.colorScheme.primary,
            )

            Spacer(Modifier.height(16.dp))

            Text(
                text = stringResource(R.string.provider_disclosure_title, prompt.displayName),
                style = MaterialTheme.typography.titleLarge,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.height(12.dp))

            Text(
                text = disclosureBody(prompt),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )

            if (prompt.privacyPolicyUrl != null) {
                Spacer(Modifier.height(16.dp))
                TextButton(onClick = {
                    if (!openExternalUrl(context, prompt.privacyPolicyUrl)) {
                        Toast.makeText(context, R.string.link_open_failed_message, Toast.LENGTH_LONG).show()
                    }
                }) {
                    Text(
                        text = stringResource(R.string.provider_disclosure_view_policy, prompt.displayName),
                        style = MaterialTheme.typography.labelLarge,
                    )
                    Spacer(Modifier.size(4.dp))
                    Icon(
                        imageVector = Icons.Outlined.ArrowOutward,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }

            Spacer(Modifier.height(20.dp))

            Button(
                onClick = onAccept,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
                shape = RoundedCornerShape(14.dp),
                contentPadding = PaddingValues(vertical = 14.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = MaterialTheme.colorScheme.onPrimary,
                ),
            ) {
                Text(
                    text = stringResource(R.string.provider_disclosure_continue),
                    style = MaterialTheme.typography.titleMedium,
                )
            }

            Spacer(Modifier.height(8.dp))

            TextButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = stringResource(R.string.provider_disclosure_cancel),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun disclosureBody(prompt: ProviderDisclosurePrompt): String = when (prompt.kind) {
    ProviderKind.Relay -> stringResource(R.string.provider_disclosure_body_relay)
    else -> stringResource(R.string.provider_disclosure_body_default, prompt.displayName)
}
