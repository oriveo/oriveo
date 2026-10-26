package ai.oriveo.community.feature.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ArrowOutward
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.app.resolve
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.util.openExternalUrl
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceChoice
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngineChooser
import ai.oriveo.community.core.voice.VoiceEngineOption
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.rememberGlobalSnackbarManager
import ai.oriveo.community.ui.theme.OriveoTheme

/**
 * Engine picker sheet: a card with the system option, the cloud options and "add connection", and a footer below it.
 * A tap closes the sheet; cloud engines without consent first raise [VoiceDisclosureSheet]. Agreeing closes both sheets,
 * while "Not now" or swiping down closes only the disclosure.
 * It does not read Koin: the caller supplies the engine-choosing flow through [chooser].
 * When [initialPending] is non-null the disclosure is stacked on open (for screenshots; null = production behavior).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VoiceEngineSheet(
    direction: VoiceDirection,
    model: VoiceEngineSheetModel,
    catalog: VoiceCatalog,
    chooser: VoiceEngineChooser,
    onDismiss: () -> Unit,
    onAddConnection: () -> Unit,
    initialPending: VoiceChoice.NeedsDisclosure? = null,
) {
    var pending by remember { mutableStateOf(initialPending) }

    OriveoModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
        ) {
            Text(
                text = stringResource(
                    when (direction) {
                        VoiceDirection.Stt -> R.string.voice_engine_sheet_title_stt
                        VoiceDirection.Tts -> R.string.voice_engine_sheet_title_tts
                        VoiceDirection.Realtime -> R.string.voice_realtime_engine_title
                    },
                ),
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.padding(bottom = 16.dp),
            )
            Surface(
                shape = RoundedCornerShape(16.dp),
                color = MaterialTheme.colorScheme.surfaceContainerLowest,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column {
                    model.rows.forEach { row ->
                        EngineRow(
                            row = row,
                            systemTitle = model.systemTitle.resolve(LocalContext.current),
                            systemSubtitle = model.systemSubtitle.resolve(LocalContext.current),
                            onClick = {
                                when (val choice = chooser.choose(direction, row.option, catalog)) {
                                    is VoiceChoice.NeedsDisclosure -> pending = choice
                                    else -> onDismiss()
                                }
                            },
                        )
                        HorizontalDivider(modifier = Modifier.padding(start = 64.dp))
                    }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                onDismiss()
                                onAddConnection()
                            }
                            .padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Add,
                            contentDescription = null,
                            modifier = Modifier.size(32.dp),
                            tint = MaterialTheme.colorScheme.primary,
                        )
                        Text(
                            text = stringResource(R.string.voice_add_connection),
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.primary,
                        )
                    }
                }
            }
            footerText(model.footer)?.let { text ->
                Text(
                    text = text,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
        }
    }

    pending?.let { choice ->
        VoiceDisclosureSheet(
            direction = choice.direction,
            providerKind = choice.selection.providerKind,
            onAgree = {
                chooser.accept(choice)
                pending = null
                onDismiss()
            },
            onDecline = {
                chooser.decline(choice)
                pending = null
            },
        )
    }
}

@Composable
private fun EngineRow(row: VoiceEngineSheetRow, systemTitle: String, systemSubtitle: String, onClick: () -> Unit) {
    val tag = when (row.option) {
        VoiceEngineOption.System -> "voice_engine_option_system"
        is VoiceEngineOption.Cloud -> "voice_engine_option_cloud"
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics { selected = row.isChecked }
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        when (val option = row.option) {
            VoiceEngineOption.System -> {
                Icon(
                    imageVector = Icons.Outlined.PhoneAndroid,
                    contentDescription = null,
                    modifier = Modifier.size(32.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = systemTitle,
                        style = MaterialTheme.typography.bodyLarge,
                    )
                    Text(
                        text = systemSubtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            is VoiceEngineOption.Cloud -> {
                // The badge description is not merged into the row semantics: the title already reads the provider name
                ProviderBadgeIcon(kind = option.providerKind, size = 32.dp, modifier = Modifier.clearAndSetSemantics {})
                // Title = provider display name, subtitle = model id (suffixed with the connection name when a provider has several connections).
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = option.providerKind.displayName,
                        style = MaterialTheme.typography.bodyLarge,
                    )
                    Text(
                        text = row.connectionName?.let { "${option.model} · $it" } ?: option.model,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        if (row.isChecked) {
            Icon(
                imageVector = Icons.Filled.Check,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
            )
        }
    }
}

@Composable
private fun footerText(footer: VoiceEngineSheetFooter): String? = when (footer) {
    VoiceEngineSheetFooter.None -> null
    VoiceEngineSheetFooter.CatalogEmpty -> stringResource(R.string.voice_engine_catalog_empty)
    VoiceEngineSheetFooter.LoadFailed -> stringResource(R.string.voice_engine_catalog_load_failed)
    is VoiceEngineSheetFooter.PendingProviders -> {
        val locale = LocalConfiguration.current.locales[0]
        val names = android.icu.text.ListFormatter.getInstance(locale)
            .format(footer.kinds.map { it.displayName })
        stringResource(R.string.voice_engine_pending_providers, names)
    }
}

/** Disclosure for cloud voice: agree -> [onAgree]; "Not now" or swipe down -> [onDecline]. The privacy policy opens in the browser. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VoiceDisclosureSheet(
    direction: VoiceDirection,
    providerKind: ProviderKind,
    onAgree: () -> Unit,
    onDecline: () -> Unit,
) {
    val context = LocalContext.current
    val snackbar = rememberGlobalSnackbarManager()
    val providerName = providerKind.displayName
    val privacyPolicyUrl = providerKind.privacyPolicyUrl

    OriveoModalBottomSheet(
        onDismissRequest = onDecline,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        contentWindowInsets = { WindowInsets(0, 0, 0, 0) },
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // When large fonts or long copy exceed the screen height only the title and body scroll; the button row stays pinned below so it is always tappable
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f, fill = false)
                    .verticalScroll(rememberScrollState()),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                ProviderBadgeIcon(kind = providerKind, size = 44.dp)

                Spacer(Modifier.height(16.dp))

                Text(
                    text = stringResource(
                        when (direction) {
                            VoiceDirection.Stt -> R.string.voice_disclosure_title_stt
                            VoiceDirection.Tts -> R.string.voice_disclosure_title_tts
                            VoiceDirection.Realtime -> R.string.voice_realtime_disclosure_title
                        },
                        providerName,
                    ),
                    style = MaterialTheme.typography.titleLarge,
                    textAlign = TextAlign.Center,
                )

                Spacer(Modifier.height(12.dp))

                Text(
                    text = stringResource(
                        when (direction) {
                            VoiceDirection.Stt -> R.string.voice_disclosure_body_stt
                            VoiceDirection.Tts -> R.string.voice_disclosure_body_tts
                            VoiceDirection.Realtime -> R.string.voice_realtime_disclosure_body
                        },
                        providerName,
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )

                if (privacyPolicyUrl != null) {
                    Spacer(Modifier.height(16.dp))
                    TextButton(
                        onClick = {
                            if (!openExternalUrl(context, privacyPolicyUrl)) {
                                snackbar?.show(
                                    GlobalSnackbarMessage(UiText.Resource(R.string.link_open_failed_message), style = GlobalToastStyle.Error),
                                )
                            }
                        },
                    ) {
                        Text(
                            text = stringResource(R.string.voice_privacy_policy),
                            style = MaterialTheme.typography.labelLarge,
                            color = OriveoTheme.colors.primaryTextSafe,
                        )
                        Spacer(Modifier.size(4.dp))
                        Icon(
                            imageVector = Icons.Outlined.ArrowOutward,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                            tint = OriveoTheme.colors.primaryTextSafe,
                        )
                    }
                }
            }

            Spacer(Modifier.height(20.dp))

            Button(
                onClick = onAgree,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
                shape = RoundedCornerShape(14.dp),
                contentPadding = PaddingValues(vertical = 14.dp),
                colors = ButtonDefaults.buttonColors(
                    // A solid button carrying text uses primaryTextSafe so it does not turn too light in dark mode
                    containerColor = OriveoTheme.colors.primaryTextSafe,
                    contentColor = MaterialTheme.colorScheme.onPrimary,
                ),
            ) {
                Text(
                    text = stringResource(R.string.voice_disclosure_agree),
                    style = MaterialTheme.typography.titleMedium,
                )
            }

            Spacer(Modifier.height(8.dp))

            TextButton(
                onClick = onDecline,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    text = stringResource(R.string.voice_dictation_not_now),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
