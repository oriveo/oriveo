package ai.oriveo.community.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import ai.oriveo.community.R
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.repository.ProviderRepository
import ai.oriveo.community.core.model.LanguageOption
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.RecognitionLanguageRow
import ai.oriveo.community.core.voice.SystemTtsVoiceProbe
import ai.oriveo.community.core.voice.recognitionLanguageRows
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
import ai.oriveo.community.core.voice.VoiceRealtimeEntry
import ai.oriveo.community.core.voice.VoiceNoticeSite
import ai.oriveo.community.core.voice.VoiceTtsEntry
import ai.oriveo.community.core.voice.realtime.HomeRealtimeSelectionStore
import ai.oriveo.community.core.voice.realtime.RealtimeModel
import ai.oriveo.community.feature.modelpicker.RealtimePickerDisclosure
import ai.oriveo.community.feature.modelpicker.acceptRealtimeDisclosure
import ai.oriveo.community.feature.modelpicker.pickRealtimeModel
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

/** One row of the "Realtime voice" group: official connection x catalog realtime model; [checked] = current home-store selection. */
data class RealtimeSettingsRow(
    val providerId: String,
    val providerKind: ProviderKind,
    val connectionName: String,
    val entry: VoiceRealtimeEntry,
    val checked: Boolean,
)

/** The four states of the "Realtime voice" group: catalog not yet loaded / fetch failed / no listable model (including no voice catalog on the server) / rows. */
sealed interface RealtimeSectionState {
    data object Loading : RealtimeSectionState
    data object Failed : RealtimeSectionState
    data object Empty : RealtimeSectionState
    data class Rows(val rows: List<RealtimeSettingsRow>) : RealtimeSectionState
}

data class VoiceSettingsUiState(
    val header: UiText = UiText.Resource(R.string.voice_settings_header),
    val realtime: RealtimeSectionState = RealtimeSectionState.Loading,
    /** Realtime group footnote: rows = regular note, empty state = empty-state copy, no footnote while loading or on failure (same as iOS). */
    val realtimeFooter: UiText? = null,
    val dictation: DictationSectionState,
    val readAloud: ReadAloudSectionState,
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
    private val realtimeSelectionStore: HomeRealtimeSelectionStore = HomeRealtimeSelectionStore.shared,
) : ViewModel() {

    /** The same chooser the engine sheet uses: picking an engine and the cloud disclosure both write settings through it. */
    val chooser = VoiceEngineChooser(settings, settings.disclosure)

    private var catalogState: VoiceCatalogState? = null
    /** The realtime group shows a loading state from tapping "Retry" until the fetch returns. */
    private var realtimeRetrying = false
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
        // The home selection changed elsewhere (home / picker / provider detail); the check mark follows it
        viewModelScope.launch {
            realtimeSelectionStore.selection.collect { publish() }
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

    /** "Retry" after the realtime catalog fetch failed. */
    fun retryRealtimeCatalog() {
        // Go back to the loading state (spinner) before fetching; when the result equals the current state the StateFlow does not re-emit, so re-publish on return
        realtimeRetrying = true
        publish()
        viewModelScope.launch {
            try {
                catalogClient.refresh()
            } finally {
                realtimeRetrying = false
                publish()
            }
        }
    }

    /**
     * Tapping a realtime row: if this provider's Realtime direction was already consented to, write the home selection directly and return null (the caller goes back to home);
     * if not yet consented, write nothing and return the pending choice so the UI shows the disclosure.
     */
    internal fun onRealtimeRow(row: RealtimeSettingsRow): RealtimePickerDisclosure? = pickRealtimeModel(
        providerId = row.providerId,
        providerKind = row.providerKind,
        modelId = row.entry.model,
        store = settings.disclosure,
        select = realtimeSelectionStore::set,
    )

    /** The disclosure was accepted: record consent and write the home selection. */
    internal fun acceptRealtimeDisclosure(pending: RealtimePickerDisclosure) {
        acceptRealtimeDisclosure(pending, settings.disclosure, realtimeSelectionStore::set)
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
        // The settings page only has the dictation and read-aloud groups; the legacy conversation-engine key is kept for migration reads and is neither parsed nor rewritten here.
        for (direction in SETTINGS_DIRECTIONS) {
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
        val language = settings.recognitionLanguage()
        publishedSelections[VoiceDirection.Stt] = stt
        publishedSelections[VoiceDirection.Tts] = tts
        val realtime = realtimeSection()
        return VoiceSettingsUiState(
            realtime = realtime,
            realtimeFooter = when (realtime) {
                is RealtimeSectionState.Rows -> UiText.Resource(R.string.voice_realtime_settings_footer)
                RealtimeSectionState.Empty -> UiText.Resource(R.string.voice_realtime_settings_empty)
                RealtimeSectionState.Loading, RealtimeSectionState.Failed -> null
            },
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
            recognitionLanguages = recognitionLanguageRows(language),
        )
    }

    private fun realtimeSection(): RealtimeSectionState {
        if (realtimeRetrying) return RealtimeSectionState.Loading
        val state = catalogState
        val available = when (state) {
            null -> return RealtimeSectionState.Loading
            VoiceCatalogState.LoadFailed -> return RealtimeSectionState.Failed
            // No voice catalog on the server (404) shows the empty state, not a failure
            VoiceCatalogState.Unavailable -> return RealtimeSectionState.Empty
            is VoiceCatalogState.Available -> state.catalog
        }
        val entries = providers.map { it.kind }.distinct().associateWith { kind ->
            available.entries(kind, VoiceDirection.Realtime).filterIsInstance<VoiceRealtimeEntry>()
        }
        // Same source as the picker: catalog realtime[] x official apiKey connections, isDefault first, the rest in catalog order
        val result = RealtimeModel.pickerRows(
            context = RealtimeModel.CONTEXT_HOME,
            connections = providers.map {
                RealtimeModel.Connection(
                    id = it.id,
                    providerKind = it.kind.rawValue,
                    auth = RealtimeModel.connectionAuth(it.kind, it.authMode),
                )
            },
            realtimeCatalog = entries.entries.associate { (kind, list) ->
                kind.rawValue to list.map { RealtimeModel.RealtimeCatalogEntry(it.model, it.isDefault) }
            },
        )
        val byId = providers.associateBy { it.id }
        val selected = realtimeSelectionStore.selection.value
        val rows = result.groups.flatMap { group ->
            val provider = byId[group.connectionId] ?: return@flatMap emptyList()
            val byModel = entries[provider.kind].orEmpty().associateBy { it.model }
            group.rows.mapNotNull { row ->
                byModel[row.model]?.let { entry ->
                    RealtimeSettingsRow(
                        providerId = provider.id,
                        providerKind = provider.kind,
                        connectionName = provider.displayName,
                        entry = entry,
                        checked = selected == (provider.id to entry.model),
                    )
                }
            }
        }
        return if (rows.isEmpty()) RealtimeSectionState.Empty else RealtimeSectionState.Rows(rows)
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

    private fun languageLabel(tag: String?): UiText {
        if (tag == null) return UiText.Resource(R.string.voice_language_automatic)
        val option = LanguageOption.entries.firstOrNull { it.localeTag == tag }
        if (option != null) return UiText.Dynamic(option.displayName)
        val locale = Locale.forLanguageTag(tag)
        return UiText.Dynamic(locale.getDisplayName(locale).ifEmpty { tag })
    }

    private fun engineLabel(selection: VoiceEngineSelection): UiText = voiceEngineLabel(selection)

    private fun billedTo(selection: VoiceEngineSelection): UiText = when (selection) {
        VoiceEngineSelection.System -> UiText.Resource(R.string.voice_engine_system_subtitle)
        is VoiceEngineSelection.Cloud ->
            UiText.Resource(R.string.voice_engine_billed_to_connection, listOf(selection.model))
    }

    private fun noticeText(direction: VoiceDirection): UiText? =
        notices[direction]?.let { UiText.Resource(R.string.voice_engine_fallback_settings) }

    private fun capitalized(id: String): String =
        id.replaceFirstChar { if (it.isLowerCase()) it.titlecase(Locale.ROOT) else it.toString() }

    private companion object {
        val SETTINGS_DIRECTIONS = listOf(VoiceDirection.Stt, VoiceDirection.Tts)
    }
}

/**
 * Value of the engine row: System -> "System", cloud -> the provider display name (not the connection name). Matches iOS VoiceSettingsModel.row(for:);
 * the "Voice" cell on the settings home takes the same value for the read-aloud (TTS) direction.
 */
internal fun voiceEngineLabel(selection: VoiceEngineSelection): UiText = when (selection) {
    VoiceEngineSelection.System -> UiText.Resource(R.string.voice_engine_system)
    is VoiceEngineSelection.Cloud -> UiText.Dynamic(selection.providerKind.displayName)
}
