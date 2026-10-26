package ai.oriveo.community.core.voice

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.ProviderCredentialResolver
import ai.oriveo.community.core.provider.transport.EndpointResolver
import io.ktor.client.HttpClient

/**
 * The engine chosen for one read-aloud. [providerKind] is the provider kind of the chosen engine (providerKind rawValue for cloud, "system" for system);
 * [fallbackReason] is the fallback reason [VoiceEngineSettings.applyResolution] (site = Use) wants shown right now.
 */
data class ReadAloudEngineChoice(
    val engine: SpeechEngine,
    val providerKind: String,
    val fallbackReason: VoiceFallbackReason? = null,
)

/** Picks the engine when read-aloud starts; called in the controller scope. */
fun interface ReadAloudEngineSource {
    suspend fun pick(): ReadAloudEngineChoice

    companion object {
        /** Fixed single engine (for tests and the legacy constructor). */
        fun fixed(engine: SpeechEngine): ReadAloudEngineSource =
            ReadAloudEngineSource { ReadAloudEngineChoice(engine, engine.engineName) }
    }
}

/** Read-aloud engine construction: the system engine shares one instance, a cloud engine is created each time. */
interface ReadAloudEngineFactory {
    fun system(): SpeechEngine

    fun cloud(
        entry: VoiceTtsEntry,
        providerKind: ProviderKind,
        baseUrl: String,
        apiKey: String,
        voice: String?,
        providerDisplayName: String,
    ): SpeechEngine
}

class DefaultReadAloudEngineFactory(
    private val httpClient: HttpClient,
    private val cache: SpeechAudioCache,
    private val systemEngine: SpeechEngine,
    private val speechRate: () -> Double,
) : ReadAloudEngineFactory {
    override fun system(): SpeechEngine = systemEngine

    override fun cloud(
        entry: VoiceTtsEntry,
        providerKind: ProviderKind,
        baseUrl: String,
        apiKey: String,
        voice: String?,
        providerDisplayName: String,
    ): SpeechEngine = CloudSpeechEngine(
        httpClient = httpClient,
        entry = entry,
        providerKind = providerKind,
        baseUrl = baseUrl,
        apiKey = apiKey,
        voice = voice,
        slider = speechRate().toFloat(),
        cache = cache,
        playerFactory = { MediaChunkPlayer() },
        fallbackFactory = { systemEngine },
        providerDisplayName = providerDisplayName,
    )
}

/**
 * Picks the read-aloud engine from settings and the catalog snapshot: cloud when resolution lands on cloud, the (providerKind, tts) disclosure is accepted and the endpoint can be built; otherwise system.
 *
 * With a cloud selection, first calls [refreshCatalog] each time (production: background ensureFresh, which decides staleness itself), then synchronously reads [catalogState]
 * (production: VoiceCatalogClient.state.value): with no usable conclusion, use system without rewriting or notifying.
 */
class SettingsReadAloudEngineSource(
    private val engines: ReadAloudEngineFactory,
    private val settings: VoiceEngineSettings,
    private val catalogState: () -> VoiceCatalogState?,
    private val refreshCatalog: () -> Unit,
    private val providers: suspend () -> List<Provider>,
    private val disclosure: VoiceDisclosureStore = settings.disclosure,
) : ReadAloudEngineSource {
    override suspend fun pick(): ReadAloudEngineChoice {
        val selection = settings.selection(VoiceDirection.Tts) as? VoiceEngineSelection.Cloud
        if (selection == null) {
            // The stored selection is system: take a fallback first discovered elsewhere here.
            return system(apply(VoiceEngineResolution(VoiceEngine.System)))
        }
        // Called every time: ensureFresh decides staleness and dedupes itself; the result is not awaited.
        refreshCatalog()
        val state = catalogState()
        val catalog = (state as? VoiceCatalogState.Available)?.catalog
            ?: return system(apply(null))
        val connections = providers()
        val resolution = VoiceEngineResolver.resolve(
            catalog = catalog,
            direction = VoiceDirection.Tts,
            selection = selection,
            connections = connections.map(VoiceConnection::from),
        )
        val reason = apply(resolution)
        val resolved = resolution.engine as? VoiceEngine.Cloud ?: return system(reason)
        // Resolved to cloud but disclosure not accepted: use system this time, without rewriting or notifying.
        if (!disclosure.isAccepted(resolved.providerKind, VoiceDirection.Tts)) return system(reason)
        val provider = connections.first { it.id == resolved.connectionId }
        val entry = catalog.entry(resolved.providerKind, VoiceDirection.Tts, resolved.model) as? VoiceTtsEntry
            ?: return system(reason)
        val baseUrl = EndpointResolver.resolveBaseUrl(provider)
        if (CloudReadAloudRules.requestUrl(baseUrl, entry) == null) return system(reason)
        val engine = engines.cloud(
            entry = entry,
            providerKind = resolved.providerKind,
            baseUrl = baseUrl,
            apiKey = ProviderCredentialResolver.apiKey(provider, null),
            voice = resolved.voice,
            providerDisplayName = resolved.providerKind.displayName,
        )
        return ReadAloudEngineChoice(engine, resolved.providerKind.rawValue, reason)
    }

    private fun apply(resolution: VoiceEngineResolution?): VoiceFallbackReason? =
        settings.applyResolution(VoiceDirection.Tts, resolution, VoiceNoticeSite.Use)

    private fun system(reason: VoiceFallbackReason?): ReadAloudEngineChoice {
        val engine = engines.system()
        return ReadAloudEngineChoice(engine, engine.engineName, reason)
    }
}
