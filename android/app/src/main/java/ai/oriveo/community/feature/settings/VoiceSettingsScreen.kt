package ai.oriveo.community.feature.settings

import android.content.Context
import android.content.Intent
import android.speech.tts.TextToSpeech
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.app.resolve
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.util.ExternalActivityLaunchOutcome
import ai.oriveo.community.core.util.launchExternalActivitySafely
import ai.oriveo.community.core.voice.VoiceChoice
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoicePreviewController
import ai.oriveo.community.ui.component.FlatGroup
import ai.oriveo.community.ui.component.FlatSectionHeader
import ai.oriveo.community.ui.component.InsetHairline
import ai.oriveo.community.ui.component.OriveoBackButton
import ai.oriveo.community.ui.component.OriveoModalBottomSheet
import ai.oriveo.community.ui.component.OriveoSettingsRow
import ai.oriveo.community.ui.component.ProviderBadgeIcon
import ai.oriveo.community.ui.component.rememberGlobalSnackbarManager
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.ui.theme.OriveoTheme
import java.text.NumberFormat
import java.util.Locale
import org.koin.androidx.compose.koinViewModel
import org.koin.compose.koinInject

private const val SPEED_MIN = 0.5f
private const val SPEED_MAX = 2f

/** Speed slider ticks: 0.5–2.0 in 0.1 steps (15 intervals → 14 intermediate stops). */
private const val SPEED_STEPS = 14

/** Settings action for the system text-to-speech screen (not a public SDK constant). */
private const val ACTION_TTS_SETTINGS = "com.android.settings.TTS_SETTINGS"

/** Row scrolled into view when the Settings > Voice page opens. */
enum class VoiceSettingsScrollTarget {
    RealtimeEngine,
}

/**
 * Settings › Voice: dictation group (engine, recognition language), read-aloud group
 * (engine, voice, speed, system voice hint) and voice conversation group (engine), each with its footer.
 *
 * [initialEngineSheet] opens the engine sheet of that direction right away, [initialDisclosure] stacks the provider disclosure on top of it,
 * and [initialScrollTarget] scrolls that row into view; the defaults are a normal page entry (the overrides exist for screenshots).
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun VoiceSettingsScreen(
    onBack: () -> Unit = {},
    onAddConnection: () -> Unit = {},
    viewModel: VoiceSettingsViewModel = koinViewModel(),
    previewController: VoicePreviewController = koinInject(),
    initialEngineSheet: VoiceDirection? = null,
    initialDisclosure: VoiceChoice.NeedsDisclosure? = null,
    initialScrollTarget: VoiceSettingsScrollTarget? = null,
) {
    val colors = OriveoTheme.colors
    val context = LocalContext.current
    val snackbar = rememberGlobalSnackbarManager()
    val locale = LocalConfiguration.current.locales[0]
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val sheetSourcesRevision by viewModel.sheetSourcesRevision.collectAsStateWithLifecycle()
    val previewing by previewController.previewing.collectAsStateWithLifecycle()

    var engineSheet by remember { mutableStateOf(initialEngineSheet) }
    val realtimeRowRequester = remember { BringIntoViewRequester() }
    var languageSheet by remember { mutableStateOf(false) }
    var voiceSheet by remember { mutableStateOf(false) }

    LaunchedEffect(locale) { viewModel.onEnter(locale) }
    LaunchedEffect(initialScrollTarget) {
        when (initialScrollTarget) {
            null -> Unit
            VoiceSettingsScrollTarget.RealtimeEngine -> {
                // Wait for the first layout so the row has a position inside the scroll container before scrolling.
                withFrameNanos {}
                realtimeRowRequester.bringIntoView()
            }
        }
    }
    DisposableEffect(previewController) {
        onDispose { previewController.stop() }
    }

    Box(modifier = Modifier.fillMaxSize().testTag("voice_settings_screen")) {
        OriveoScreenBackground()
        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            text = stringResource(R.string.voice_settings_title),
                            style = OriveoTheme.typography.title3,
                            color = colors.textPrimary,
                        )
                    },
                    navigationIcon = {
                        OriveoBackButton(onClick = onBack, modifier = Modifier.testTag("settings_voice_back_button"))
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent,
                    ),
                )
            },
        ) { padding ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = OriveoTheme.spacing.lg, vertical = OriveoTheme.spacing.md),
                verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.sm),
            ) {
                Footnote(text = state.header.text())
                DictationGroup(
                    state = state.dictation,
                    onEngine = { engineSheet = VoiceDirection.Stt },
                    onLanguage = { languageSheet = true },
                )
                ReadAloudGroup(
                    state = state.readAloud,
                    locale = locale,
                    onEngine = { engineSheet = VoiceDirection.Tts },
                    onVoice = { voiceSheet = true },
                    onSpeed = viewModel::setSpeed,
                    onTtsHint = { openSystemTtsSettings(context, snackbar) },
                )
                ConversationGroup(
                    state = state.conversation,
                    onEngine = { engineSheet = VoiceDirection.Realtime },
                    modifier = Modifier.bringIntoViewRequester(realtimeRowRequester),
                )
            }
        }
    }

    engineSheet?.let { direction ->
        val input = remember(direction, state, sheetSourcesRevision) { viewModel.engineSheetInput(direction) }
        VoiceEngineSheet(
            direction = direction,
            model = input.model,
            catalog = input.catalog,
            chooser = viewModel.chooser,
            initialPending = initialDisclosure?.takeIf { it.direction == direction },
            onDismiss = {
                engineSheet = null
                viewModel.onEngineSheetDismissed(direction)
            },
            onAddConnection = onAddConnection,
        )
    }

    if (languageSheet) {
        PickerSheet(onDismiss = { languageSheet = false }) {
            state.recognitionLanguages.forEachIndexed { index, row ->
                if (index > 0) InsetHairline()
                CheckRow(
                    title = row.label.text(),
                    checked = row.selected,
                    tag = "voice_settings_recognition_language_option",
                    onClick = {
                        viewModel.setRecognitionLanguage(row.tag)
                        languageSheet = false
                    },
                )
            }
        }
    }

    if (voiceSheet) {
        PickerSheet(onDismiss = { voiceSheet = false }) {
            state.readAloud.voices.forEachIndexed { index, row ->
                if (index > 0) InsetHairline()
                CheckRow(
                    title = row.label,
                    checked = row.selected,
                    tag = "voice_settings_voice_option",
                    onClick = { viewModel.setVoice(row.id) },
                    trailing = {
                        val playing = previewing == row.id
                        IconButton(
                            onClick = { previewController.toggle(row.id) },
                        ) {
                            Icon(
                                imageVector = if (playing) Icons.Filled.Stop else Icons.Filled.PlayArrow,
                                contentDescription = stringResource(if (playing) R.string.stop else R.string.voice_preview),
                                tint = colors.primary,
                            )
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun DictationGroup(
    state: DictationSectionState,
    onEngine: () -> Unit,
    onLanguage: () -> Unit,
) {
    FlatSectionHeader(title = stringResource(R.string.voice_section_dictation))
    FlatGroup {
        EngineRow(
            direction = stringResource(R.string.voice_engine_sheet_title_stt),
            engineName = state.engineValue.text(),
            engineKind = state.engineKind,
            subtitle = state.billedTo?.text(),
            tag = "voice_settings_stt_engine_row",
            onClick = onEngine,
        )
        state.fallbackNotice?.let { WarningLine(it.text()) }
        InsetHairline()
        ValueRow(
            title = stringResource(R.string.voice_recognition_language),
            value = state.languageValue.text(),
            tag = "voice_settings_recognition_language_row",
            onClick = onLanguage,
        )
    }
    Footnote(text = state.footer.text())
}

@Composable
private fun ReadAloudGroup(
    state: ReadAloudSectionState,
    locale: Locale,
    onEngine: () -> Unit,
    onVoice: () -> Unit,
    onSpeed: (Double) -> Unit,
    onTtsHint: () -> Unit,
) {
    val colors = OriveoTheme.colors
    FlatSectionHeader(title = stringResource(R.string.voice_read_aloud))
    FlatGroup {
        EngineRow(
            direction = stringResource(R.string.voice_engine_sheet_title_tts),
            engineName = state.engineValue.text(),
            engineKind = state.engineKind,
            subtitle = state.billedTo?.text(),
            tag = "voice_settings_tts_engine_row",
            onClick = onEngine,
        )
        state.fallbackNotice?.let { WarningLine(it.text()) }
        state.voiceValue?.let { voice ->
            InsetHairline()
            ValueRow(
                title = stringResource(R.string.voice_speaking_voice),
                value = voice,
                tag = "voice_settings_voice_row",
                onClick = onVoice,
            )
        }
        InsetHairline()
        Column(modifier = Modifier.padding(horizontal = OriveoTheme.spacing.lg, vertical = 9.dp)) {
            OriveoSettingsRow(
                title = stringResource(R.string.voice_speed),
                value = speedLabel(state.speed, locale),
                showChevron = false,
            )
            Slider(
                value = state.speed.toFloat(),
                onValueChange = { onSpeed(it.toDouble()) },
                valueRange = SPEED_MIN..SPEED_MAX,
                steps = SPEED_STEPS,
                enabled = state.speedEnabled,
            )
        }
        state.ttsHint?.let { hint ->
            InsetHairline()
            Text(
                text = hint.text(),
                style = OriveoTheme.typography.footnote,
                color = colors.primary,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onTtsHint)
                    .padding(horizontal = OriveoTheme.spacing.lg, vertical = 12.dp),
            )
        }
    }
    state.speedFooter?.let { Footnote(text = it.text()) }
    Footnote(text = state.footer.text())
}

@Composable
private fun ConversationGroup(
    state: ConversationSectionState,
    onEngine: () -> Unit,
    modifier: Modifier = Modifier,
) {
    FlatSectionHeader(title = stringResource(R.string.voice_realtime_group_header))
    FlatGroup {
        // The title is always "Conversation engine"; the subtitle is "follow the current model" for system and "provider name · model" for cloud.
        val subtitle = state.engineSubtitle.text()
        val direction = stringResource(R.string.voice_realtime_engine_title)
        EngineRow(
            direction = direction,
            engineName = direction,
            engineKind = state.engineKind,
            subtitle = subtitle,
            tag = "voice_settings_realtime_engine_row",
            onClick = onEngine,
            modifier = modifier,
        )
        state.fallbackNotice?.let { WarningLine(it.text()) }
    }
    Footnote(text = state.footer.text())
}

/** Engine icon + title = current engine name + subtitle; the direction title is only joined into the accessibility description (e.g. "Dictation Engine, OpenAI"). */
@Composable
private fun EngineRow(
    direction: String,
    engineName: String,
    engineKind: ProviderKind?,
    subtitle: String?,
    tag: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // With the system engine the title is the direction name; de-duplicate so it is not read twice
    val description = listOfNotNull(direction, engineName, subtitle).distinct().joinToString(", ")
    Row(
        modifier = modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) { contentDescription = description }
            .clickable(onClick = onClick)
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
    ) {
        if (engineKind != null) {
            // The badge description is not merged into the row semantics: the row description already has the provider name
            ProviderBadgeIcon(kind = engineKind, size = 32.dp, modifier = Modifier.clearAndSetSemantics {})
        } else {
            Icon(
                imageVector = Icons.Outlined.PhoneAndroid,
                contentDescription = null,
                modifier = Modifier.size(32.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        OriveoSettingsRow(
            title = engineName,
            subtitle = subtitle,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun ValueRow(title: String, value: String, tag: String, onClick: () -> Unit) {
    OriveoSettingsRow(
        title = title,
        value = value,
        onClick = onClick,
        modifier = Modifier
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = 9.dp),
    )
}

@Composable
private fun WarningLine(text: String) {
    Text(
        text = text,
        style = OriveoTheme.typography.footnote,
        color = OriveoTheme.colors.warning,
        modifier = Modifier.padding(horizontal = OriveoTheme.spacing.lg).padding(bottom = 9.dp),
    )
}

@Composable
private fun Footnote(text: String) {
    Text(
        text = text,
        style = OriveoTheme.typography.footnote,
        color = OriveoTheme.colors.textSecondary,
        modifier = Modifier.padding(horizontal = OriveoTheme.spacing.sm),
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PickerSheet(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    OriveoModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 24.dp),
        ) {
            FlatGroup { content() }
        }
    }
}

@Composable
private fun CheckRow(
    title: String,
    checked: Boolean,
    tag: String,
    onClick: () -> Unit,
    trailing: @Composable (() -> Unit)? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics { selected = checked }
            .clickable(onClick = onClick)
            .padding(horizontal = OriveoTheme.spacing.lg, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.bodyLarge,
            color = OriveoTheme.colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        trailing?.invoke()
        if (checked) {
            Icon(imageVector = Icons.Filled.Check, contentDescription = null, tint = OriveoTheme.colors.primary)
        }
    }
}

@Composable
private fun UiText.text(): String = resolve(LocalContext.current)

/** "1.0×" with the decimal separator of [locale]. */
private fun speedLabel(speed: Double, locale: Locale): String {
    val format = NumberFormat.getNumberInstance(locale).apply {
        minimumFractionDigits = 1
        maximumFractionDigits = 1
    }
    return "${format.format(speed)}×"
}

/** System TTS settings -> TTS data install screen -> toast. */
private fun openSystemTtsSettings(context: Context, snackbar: GlobalSnackbarManager?) {
    val settings = launchExternalActivitySafely { context.startActivity(Intent(ACTION_TTS_SETTINGS)) }
    if (settings == ExternalActivityLaunchOutcome.LAUNCHED) return
    val install = launchExternalActivitySafely {
        context.startActivity(Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA))
    }
    if (install == ExternalActivityLaunchOutcome.UNAVAILABLE) {
        snackbar?.show(
            GlobalSnackbarMessage(UiText.Resource(R.string.external_app_unavailable), style = GlobalToastStyle.Error),
        )
    }
}
