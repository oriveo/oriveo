package ai.oriveo.community.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.SystemTtsVoiceProbe
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogClient
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceConnection
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngineChooser
import ai.oriveo.community.core.voice.VoiceEngineResolver
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceFallbackReason
import ai.oriveo.community.core.voice.VoiceNoticeSite
import ai.oriveo.community.core.voice.VoiceTtsEntry
import java.util.Locale
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/** Input needed to open the engine sheet; [catalog] is an empty catalog until the real one arrives. */
data class VoiceEngineSheetInput(
    val model: VoiceEngineSheetModel,
    val catalog: VoiceCatalog,
)

/** One row of the recognition language panel; a null [tag] means automatic. */
data class RecognitionLanguageRow(
    val tag: String?,
    val label: UiText,
    val selected: Boolean,
)

/** One row of the voice panel. */
data class VoiceOptionRow(
    val id: String,
    val label: String,
    val selected: Boolean,
)

data class DictationSectionState(
    val engineValue: UiText,
    /** Engine row icon: the provider for cloud, null = system. */
    val engineKind: ProviderKind? = null,
    /** Small text under the engine row: "built in, free" for system, "model · billed to connection" for cloud. */
    val billedTo: UiText? = null,
    /** Warning text under the engine row when a fallback notice is pending. */
    val fallbackNotice: UiText? = null,
    val languageValue: UiText,
    val footer: UiText,
)

data class ReadAloudSectionState(
    val engineValue: UiText,
    val engineKind: ProviderKind? = null,
    val billedTo: UiText? = null,
    val fallbackNotice: UiText? = null,
    /** Voice row value (voice id with the first letter capitalized); null = hide the voice row (system engine or no voices). */
    val voiceValue: String? = null,
    val voices: List<VoiceOptionRow> = emptyList(),
    val speed: Double = VoiceEngineSettings.DEFAULT_SPEECH_RATE,
    val speedEnabled: Boolean = true,
    /** Footer shown when the speed control is disabled. */
    val speedFooter: UiText? = null,
    /** Hint row for system read-aloud when the voice check applies (tappable, opens the system TTS settings). */
    val ttsHint: UiText? = null,
    val footer: UiText,
)

/** Voice conversation group: a single engine row titled "follow the current model" or the provider name; the cloud subtitle is "provider name · model". */
data class ConversationSectionState(
    val engineSubtitle: UiText,
    val engineKind: ProviderKind? = null,
    val fallbackNotice: UiText? = null,
    val footer: UiText = UiText.Resource(R.string.voice_realtime_group_footer),
)

data class VoiceSettingsUiState(
    val header: UiText = UiText.Resource(R.string.voice_settings_header),
    val dictation: DictationSectionState,
    val readAloud: ReadAloudSectionState,
    val conversation: ConversationSectionState,
    val recognitionLanguages: List<RecognitionLanguageRow>,
)

/**
 * State and actions of the Settings > Voice page.
 *
 * The screen calls [onEnter] on entry: it refreshes the catalog on the first call and probes the system voice hint for the app UI language;
 * every catalog or connection change is resolved once on the settings page (site = Settings).
 * Without a catalog nothing is resolved or rewritten, and a pending notice stays visible; a notice is cleared once taken and shows only once per visit.
 */
class VoiceSettingsViewModel(
    private val settings: VoiceEngineSettings,
    private val catalogClient: VoiceCatalogClient,
    private val ttsVoiceProbe: SystemTtsVoiceProbe,
    private val providerRepository: ProviderRepository,
) : ViewModel() {

    /** The same chooser the engine sheet uses: picking an engine and the cloud disclosure both write settings through it. */
    val chooser = VoiceEngineChooser(settings, settings.disclosure)

    private var catalogState: VoiceCatalogState? = null
    private var catalog: VoiceCatalog? = null
    private var providers: List<Provider> = emptyList()
    private val notices = mutableMapOf<VoiceDirection, VoiceFallbackReason>()
    private var ttsHintNeeded = false
    /** Per-direction selections at the last publish, used to tell whether the engine changed when the sheet closes. */
    private val publishedSelections = mutableMapOf<VoiceDirection, VoiceEngineSelection>()
    private var entered = false
    private var probeJob: Job? = null

    private val _uiState = MutableStateFlow(buildState())
    val uiState: StateFlow<VoiceSettingsUiState> = _uiState.asStateFlow()

    /**
     * Incremented each time the catalog or the connections arrive. The sheet input (option rows, footer) depends on both, while [uiState]
     * does not contain connections, so it may stay unchanged when connections arrive late; an open sheet re-reads [engineSheetInput] keyed on this value instead of keeping the first one.
     */
    private val _sheetSourcesRevision = MutableStateFlow(0)
    val sheetSourcesRevision: StateFlow<Int> = _sheetSourcesRevision.asStateFlow()

    init {
        viewModelScope.launch {
            combine(catalogClient.state, providerRepository.observeAll()) { state, list -> state to list }
                .collect { (state, list) ->
                    catalogState = state
                    catalog = (state as? VoiceCatalogState.Available)?.catalog
                    providers = list
                    applyResolutions()
                    publish()
                    _sheetSourcesRevision.value += 1
                }
        }
    }

    /**
     * Called when the screen is entered; [uiLocale] is the app UI language (Compose LocalConfiguration, which reflects the language chosen in the app).
     * The first call force-refreshes the catalog (not throttled); repeated calls only re-probe the voice hint for the new locale.
     */
    fun onEnter(uiLocale: Locale) {
        if (!entered) {
            entered = true
            viewModelScope.launch { catalogClient.refresh() }
        }
        probeJob?.cancel()
        probeJob = viewModelScope.launch {
            ttsHintNeeded = runCatching { ttsVoiceProbe.hintNeeded(uiLocale) }.getOrDefault(false)
            publish()
        }
    }

    /** Input for opening the engine sheet of [direction]. */
    fun engineSheetInput(direction: VoiceDirection): VoiceEngineSheetInput = VoiceEngineSheetInput(
        model = VoiceEngineSheetModels.build(
            catalogState = catalogState,
            direction = direction,
            selection = settings.selection(direction),
            connections = connections(),
            connectionNames = providers.associate { it.id to it.displayName },
        ),
        catalog = catalog ?: VoiceCatalog(),
    )

    /** The engine sheet closed (a choice, agreeing to the disclosure, or swiping down): republish, and clear the pending notice of that direction if the engine changed. */
    fun onEngineSheetDismissed(direction: VoiceDirection) {
        if (settings.selection(direction) != publishedSelections[direction]) notices.remove(direction)
        publish()
    }

    /** null = automatic. */
    fun setRecognitionLanguage(tag: String?) {
        settings.setRecognitionLanguage(tag)
        publish()
    }

    fun setVoice(id: String) {
        val cloud = settings.selection(VoiceDirection.Tts) as? VoiceEngineSelection.Cloud ?: return
        settings.setSelection(VoiceDirection.Tts, cloud.copy(voice = id))
        publish()
    }

    fun setSpeed(rate: Double) {
        settings.setSpeechRate(rate)
        publish()
    }

    private fun connections(): List<VoiceConnection> = providers.map(VoiceConnection::from)

    private fun applyResolutions() {
        val current = catalog
        for (direction in VoiceDirection.entries) {
            val resolution = current?.let {
                VoiceEngineResolver.resolve(it, direction, settings.selection(direction), connections())
            }
            val reason = settings.applyResolution(direction, resolution, VoiceNoticeSite.Settings)
                ?: settings.takePendingNotice(direction, VoiceNoticeSite.Settings)
            if (reason != null) notices[direction] = reason
        }
    }

    private fun publish() {
        _uiState.value = buildState()
    }

    private fun buildState(): VoiceSettingsUiState {
        val stt = settings.selection(VoiceDirection.Stt)
        val tts = settings.selection(VoiceDirection.Tts)
        val realtime = settings.selection(VoiceDirection.Realtime)
        val language = settings.recognitionLanguage()
        publishedSelections[VoiceDirection.Stt] = stt
        publishedSelections[VoiceDirection.Tts] = tts
        publishedSelections[VoiceDirection.Realtime] = realtime
        return VoiceSettingsUiState(
            dictation = DictationSectionState(
                engineValue = engineLabel(stt),
                engineKind = (stt as? VoiceEngineSelection.Cloud)?.providerKind,
                billedTo = billedTo(stt),
                fallbackNotice = noticeText(VoiceDirection.Stt),
                languageValue = languageLabel(language),
                footer = UiText.Resource(
                    if (stt is VoiceEngineSelection.Cloud) {
                        R.string.voice_dictation_footer_cloud
                    } else {
                        R.string.voice_dictation_footer_system
                    },
                ),
            ),
            readAloud = readAloudSection(tts),
            conversation = ConversationSectionState(
                engineSubtitle = realtimeLabel(realtime),
                engineKind = (realtime as? VoiceEngineSelection.Cloud)?.providerKind,
                fallbackNotice = noticeText(VoiceDirection.Realtime),
            ),
            recognitionLanguages = recognitionLanguageRows(language),
        )
    }

    private fun readAloudSection(tts: VoiceEngineSelection): ReadAloudSectionState {
        val cloud = tts as? VoiceEngineSelection.Cloud
        val entry = cloud?.let { catalog?.entry(it.providerKind, VoiceDirection.Tts, it.model) as? VoiceTtsEntry }
        val currentVoice = when {
            cloud == null -> null
            entry != null -> entry.voices.firstOrNull { it.id == cloud.voice }?.id ?: entry.defaultVoice.id
            else -> cloud.voice
        }
        val speedEnabled = cloud == null || entry?.speedRange != null
        return ReadAloudSectionState(
            engineValue = engineLabel(tts),
            engineKind = cloud?.providerKind,
            billedTo = billedTo(tts),
            fallbackNotice = noticeText(VoiceDirection.Tts),
            voiceValue = currentVoice?.let(::capitalized),
            voices = entry?.voices.orEmpty().map {
                VoiceOptionRow(id = it.id, label = capitalized(it.id), selected = it.id == currentVoice)
            },
            speed = settings.speechRate(),
            speedEnabled = speedEnabled,
            speedFooter = if (speedEnabled) null else UiText.Resource(R.string.voice_speed_unsupported),
            ttsHint = if (cloud == null && ttsHintNeeded) UiText.Resource(R.string.voice_tts_voice_hint) else null,
            footer = UiText.Resource(R.string.voice_read_aloud_footer),
        )
    }

    private fun recognitionLanguageRows(current: String?): List<RecognitionLanguageRow> {
        val automatic = RecognitionLanguageRow(
            tag = null,
            label = UiText.Resource(R.string.voice_language_automatic),
            selected = current == null,
        )
        return listOf(automatic) + LanguageOption.entries.mapNotNull { option ->
            val tag = option.localeTag ?: return@mapNotNull null
            RecognitionLanguageRow(tag = tag, label = UiText.Dynamic(option.displayName), selected = tag == current)
        }
    }

    private fun languageLabel(tag: String?): UiText {
        if (tag == null) return UiText.Resource(R.string.voice_language_automatic)
        val option = LanguageOption.entries.firstOrNull { it.localeTag == tag }
        if (option != null) return UiText.Dynamic(option.displayName)
        val locale = Locale.forLanguageTag(tag)
        return UiText.Dynamic(locale.getDisplayName(locale).ifEmpty { tag })
    }

    // The cloud value is the provider display name (not the connection name); the small text carries the model id.
    private fun engineLabel(selection: VoiceEngineSelection): UiText = when (selection) {
        VoiceEngineSelection.System -> UiText.Resource(R.string.voice_engine_system)
        is VoiceEngineSelection.Cloud -> UiText.Dynamic(selection.providerKind.displayName)
    }

    private fun realtimeLabel(selection: VoiceEngineSelection): UiText = when (selection) {
        VoiceEngineSelection.System -> UiText.Resource(R.string.voice_realtime_follow_model)
        is VoiceEngineSelection.Cloud -> UiText.Dynamic("${selection.providerKind.displayName} · ${selection.model}")
    }

    private fun billedTo(selection: VoiceEngineSelection): UiText = when (selection) {
        VoiceEngineSelection.System -> UiText.Resource(R.string.voice_engine_system_subtitle)
        is VoiceEngineSelection.Cloud ->
            UiText.Resource(R.string.voice_engine_billed_to_connection, listOf(selection.model))
    }

    private fun noticeText(direction: VoiceDirection): UiText? =
        notices[direction]?.let {
            UiText.Resource(
                if (direction == VoiceDirection.Realtime) {
                    R.string.voice_realtime_engine_fallback_settings
                } else {
                    R.string.voice_engine_fallback_settings
                },
            )
        }

    private fun capitalized(id: String): String =
        id.replaceFirstChar { if (it.isLowerCase()) it.titlecase(Locale.ROOT) else it.toString() }
}
