package ai.oriveo.community.core.voice

import ai.oriveo.community.R
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.transport.EndpointResolver
import io.ktor.client.HttpClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Engine for previews: built from the selected cloud entry and [voiceId]; null if it cannot be built (treated as a preview failure, no fallback to system). */
fun interface VoicePreviewEngineSource {
    suspend fun engine(voiceId: String): SpeechEngine?
}

/**
 * Production [VoicePreviewEngineSource]: builds the cloud engine like [SettingsReadAloudEngineSource], but
 * does not rewrite settings, announce a fallback, or pass a fallback factory; returns null if disclosure is not accepted, the catalog is unavailable, or the endpoint cannot be built.
 */
class SettingsVoicePreviewEngineSource(
    private val httpClient: HttpClient,
    private val cache: SpeechAudioCache,
    private val settings: VoiceEngineSettings,
    private val catalogState: () -> VoiceCatalogState?,
    private val providers: suspend () -> List<Provider>,
    private val disclosure: VoiceDisclosureStore = settings.disclosure,
) : VoicePreviewEngineSource {
    override suspend fun engine(voiceId: String): SpeechEngine? {
        val selection = settings.selection(VoiceDirection.Tts) as? VoiceEngineSelection.Cloud ?: return null
        val catalog = (catalogState() as? VoiceCatalogState.Available)?.catalog ?: return null
        val connections = providers()
        val resolution = VoiceEngineResolver.resolve(
            catalog = catalog,
            direction = VoiceDirection.Tts,
            selection = selection.copy(voice = voiceId),
            connections = connections.map(VoiceConnection::from),
        )
        val resolved = resolution.engine as? VoiceEngine.Cloud ?: return null
        if (!disclosure.isAccepted(resolved.providerKind, VoiceDirection.Tts)) return null
        val provider = connections.firstOrNull { it.id == resolved.connectionId } ?: return null
        val entry = catalog.entry(resolved.providerKind, VoiceDirection.Tts, resolved.model) as? VoiceTtsEntry
            ?: return null
        val baseUrl = EndpointResolver.resolveBaseUrl(provider)
        if (CloudReadAloudRules.requestUrl(baseUrl, entry) == null) return null
        return CloudSpeechEngine(
            httpClient = httpClient,
            entry = entry,
            providerKind = resolved.providerKind,
            baseUrl = baseUrl,
            apiKey = ProviderCredentialResolver.apiKey(provider, null),
            voice = resolved.voice,
            slider = settings.speechRate().toFloat(),
            cache = cache,
            playerFactory = { MediaChunkPlayer() },
            fallbackFactory = null,
            providerDisplayName = provider.displayName,
        )
    }
}

/**
 * Voice preview in settings: only one voice is previewed at a time; tapping the same voice again stops it, tapping another stops first then plays. Public methods are called on the main thread.
 *
 * The sample sentence [sampleText] is voice_preview_sample in the UI language and the speech locale is the UI locale;
 * read-aloud is stopped via [stopReadAloud] before starting; stops on background / focus loss / headphones unplugged; failure shows voice_preview_failed in Error style, with no fallback to the system engine.
 */
class VoicePreviewController(
    private val engineSource: VoicePreviewEngineSource,
    private val environment: ReadAloudEnvironment,
    private val sampleText: () -> String,
    private val stopReadAloud: () -> Unit,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) {
    private val _previewing = MutableStateFlow<String?>(null)

    /** Id of the voice being previewed; null when none. */
    val previewing: StateFlow<String?> = _previewing.asStateFlow()

    private class Session(val voiceId: String) {
        var job: Job? = null
        var engine: SpeechEngine? = null
        var environmentActive = false
    }

    private var session: Session? = null

    fun toggle(voiceId: String) {
        val current = session
        if (current != null) {
            end(current)
            if (current.voiceId == voiceId) return
        }
        start(voiceId)
    }

    fun stop() {
        session?.let(::end)
    }

    private fun start(voiceId: String) {
        stopReadAloud()
        val s = Session(voiceId)
        session = s
        _previewing.value = voiceId
        s.job = scope.launch {
            val engine = runCatching { engineSource.engine(voiceId) }.getOrNull()
            if (session !== s) return@launch
            if (engine == null) {
                fail(s)
                return@launch
            }
            s.engine = engine
            val locale = environment.uiLocale()
            val text = sampleText()
            val granted = environment.beginSession(sessionListener(s))
            s.environmentActive = true
            if (!granted) {
                fail(s)
                return@launch
            }
            engine.speak(listOf(text), locale, engineListener(s))
        }
    }

    private fun sessionListener(s: Session) = object : ReadAloudEnvironment.SessionListener {
        override fun onInterrupted() = onMain(s) { end(s) }
        override fun onBackgrounded() = onMain(s) { end(s) }
    }

    private fun engineListener(s: Session) = object : SpeechEngine.Listener {
        override fun onStart(index: Int) = Unit
        override fun onDoneAll() = onMain(s) { end(s) }
        override fun onError(error: SpeechError) = onMain(s) { fail(s) }
    }

    private fun fail(s: Session) {
        if (session !== s) return
        end(s)
        environment.showMessage(R.string.voice_preview_failed)
    }

    /** Engine / platform callbacks hop back to the controller scope; late callbacks from an ended preview are dropped. */
    private fun onMain(s: Session, block: () -> Unit) {
        scope.launch { if (session === s) block() }
    }

    private fun end(s: Session) {
        if (session !== s) return
        session = null
        s.job?.cancel()
        s.engine?.stop()
        if (s.environmentActive) environment.endSession()
        _previewing.value = null
    }
}
