package ai.oriveo.community.core.voice

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.testing.TestSharedPreferences
import java.io.File
import java.util.Locale
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** The production [SettingsReadAloudEngineSource] picks the read-aloud engine from settings, the catalog snapshot, disclosure consent and the endpoint. */
class ReadAloudEngineSourceTest {

    private class NamedEngine(override val engineName: String) : SpeechEngine {
        override fun speak(utterances: List<String>, locale: Locale, listener: SpeechEngine.Listener) = Unit
        override fun stop() = Unit
    }

    private data class CloudCall(
        val entry: VoiceTtsEntry,
        val providerKind: ProviderKind,
        val baseUrl: String,
        val apiKey: String,
        val voice: String?,
        val providerDisplayName: String,
    )

    private class FakeFactory : ReadAloudEngineFactory {
        val systemEngine = NamedEngine("system")
        val cloudEngine = NamedEngine("cloud")
        val cloudCalls = mutableListOf<CloudCall>()

        override fun system(): SpeechEngine = systemEngine

        override fun cloud(
            entry: VoiceTtsEntry,
            providerKind: ProviderKind,
            baseUrl: String,
            apiKey: String,
            voice: String?,
            providerDisplayName: String,
        ): SpeechEngine {
            cloudCalls += CloudCall(entry, providerKind, baseUrl, apiKey, voice, providerDisplayName)
            return cloudEngine
        }
    }

    /** The entry decoded from the real catalog fixture. */
    private val catalog: VoiceCatalog = VoiceCatalogDecoder.decode(
        Json.parseToJsonElement(workspaceFile("shared/model-contracts/voice_catalog_contract.v2.json").readText())
            .jsonObject["data"],
    )
    private val entry: VoiceTtsEntry = catalog.provider(ProviderKind.OpenAI).tts.first { it.isDefault }
    private val openAI = Provider(
        id = "conn-openai",
        kind = ProviderKind.OpenAI,
        apiKey = "sk-live",
        baseUrlText = "https://api.openai.com/v1",
    )
    private val cloudSelection = VoiceEngineSelection.Cloud(
        providerKind = ProviderKind.OpenAI,
        connectionId = openAI.id,
        model = entry.model,
    )

    private val prefs = TestSharedPreferences()
    private val settings = VoiceEngineSettings { prefs }
    private val engines = FakeFactory()
    private var state: VoiceCatalogState? = VoiceCatalogState.Available(catalog)
    private var refreshes = 0
    private var providers = listOf(openAI)

    private val source = SettingsReadAloudEngineSource(
        engines = engines,
        settings = settings,
        catalogState = { state },
        refreshCatalog = { refreshes++ },
        providers = { providers },
    )

    private fun pick() = runBlocking { source.pick() }

    @Test
    fun `no catalog conclusion uses system without rewrite`() {
        settings.setSelection(VoiceDirection.Tts, cloudSelection)
        settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Tts)
        state = null

        val choice = pick()

        assertSame(engines.systemEngine, choice.engine)
        assertEquals("system", choice.providerKind)
        assertNull(choice.fallbackReason)
        assertEquals(cloudSelection, settings.selection(VoiceDirection.Tts))
        assertEquals(1, refreshes)
        assertTrue(engines.cloudCalls.isEmpty())
    }

    @Test
    fun `cloud selection accepted builds cloud engine`() {
        settings.setSelection(VoiceDirection.Tts, cloudSelection)
        settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Tts)

        val choice = pick()

        assertSame(engines.cloudEngine, choice.engine)
        assertEquals(ProviderKind.OpenAI.rawValue, choice.providerKind)
        assertNull(choice.fallbackReason)
        assertEquals(
            listOf(
                CloudCall(
                    entry = entry,
                    providerKind = ProviderKind.OpenAI,
                    baseUrl = "https://api.openai.com/v1",
                    apiKey = "sk-live",
                    voice = entry.defaultVoice.id,
                    providerDisplayName = ProviderKind.OpenAI.displayName,
                ),
            ),
            engines.cloudCalls,
        )
        assertEquals(1, refreshes)
    }

    @Test
    fun `fallback name is provider kind even when connection renamed`() {
        // The name in the fallback notice is the provider name, not the custom name the user gave the connection.
        providers = listOf(openAI.copy(customName = "My Work Key"))
        settings.setSelection(VoiceDirection.Tts, cloudSelection)
        settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Tts)

        val choice = pick()

        assertSame(engines.cloudEngine, choice.engine)
        assertEquals(listOf(ProviderKind.OpenAI.displayName), engines.cloudCalls.map { it.providerDisplayName })
    }

    @Test
    fun `stale catalog refreshes on pick`() {
        settings.setSelection(VoiceDirection.Tts, cloudSelection)
        settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Tts)

        // The catalog already has a usable snapshot (possibly stale): every engine pick hands off to ensureFresh, which decides staleness itself.
        assertSame(engines.cloudEngine, pick().engine)
        assertSame(engines.cloudEngine, pick().engine)

        assertEquals(2, refreshes)
    }

    @Test
    fun `cloud not accepted uses system`() {
        settings.setSelection(VoiceDirection.Tts, cloudSelection)

        val choice = pick()

        assertSame(engines.systemEngine, choice.engine)
        assertEquals("system", choice.providerKind)
        assertNull(choice.fallbackReason)
        assertEquals(cloudSelection, settings.selection(VoiceDirection.Tts))
        assertTrue(engines.cloudCalls.isEmpty())
    }

    @Test
    fun `endpoint unbuildable uses system`() {
        settings.setSelection(VoiceDirection.Tts, cloudSelection)
        settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Tts)
        providers = listOf(openAI.copy(baseUrlText = "https://bad host"))

        val choice = pick()

        assertSame(engines.systemEngine, choice.engine)
        assertEquals("system", choice.providerKind)
        assertNull(choice.fallbackReason)
        assertEquals(cloudSelection, settings.selection(VoiceDirection.Tts))
        assertTrue(engines.cloudCalls.isEmpty())
    }

    @Test
    fun `entry removed falls back and rewrites`() {
        settings.setSelection(VoiceDirection.Tts, cloudSelection)
        settings.disclosure.markAccepted(ProviderKind.OpenAI, VoiceDirection.Tts)
        state = VoiceCatalogState.Available(VoiceCatalog(providers = mapOf(ProviderKind.OpenAI to VoiceProviderCatalog())))

        val choice = pick()

        assertSame(engines.systemEngine, choice.engine)
        assertEquals("system", choice.providerKind)
        assertEquals(VoiceFallbackReason.EntryRemoved, choice.fallbackReason)
        assertEquals(VoiceEngineSelection.System, settings.selection(VoiceDirection.Tts))
        assertTrue(engines.cloudCalls.isEmpty())
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        error("workspace file not found: $relative")
    }
}
