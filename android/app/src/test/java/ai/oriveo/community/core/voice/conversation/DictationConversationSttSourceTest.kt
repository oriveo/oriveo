package ai.oriveo.community.core.voice.conversation

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.DictationCatalogSource
import ai.oriveo.community.core.voice.DictationController
import ai.oriveo.community.core.voice.DictationEngineFactory
import ai.oriveo.community.core.voice.DictationLiveSession
import ai.oriveo.community.core.voice.LiveTranscript
import ai.oriveo.community.core.voice.STTEngine
import ai.oriveo.community.core.voice.STTResult
import ai.oriveo.community.core.voice.STTSegment
import ai.oriveo.community.core.voice.SystemSTTRecognizer
import ai.oriveo.community.core.voice.SystemSTTRoute
import ai.oriveo.community.core.voice.SystemSTTSelfRecordSession
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceDisclosureStore
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.VoiceProviderCatalog
import ai.oriveo.community.core.voice.VoiceSttEntry
import ai.oriveo.community.core.voice.VoiceTransport
import ai.oriveo.community.testing.TestSharedPreferences
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Production [DictationConversationSttSource] against a fake catalog / fake engine: fetching the catalog has a 10 s total budget, and on timeout system recognition is used. */
@OptIn(ExperimentalCoroutinesApi::class)
class DictationConversationSttSourceTest {

    private class FakeCatalog : DictationCatalogSource {
        var cached: VoiceCatalog? = null
        var refreshed: VoiceCatalogState = VoiceCatalogState.LoadFailed
        var refreshes = 0

        /** When non-null, the cached read suspends until it completes, simulating a wait on the catalog lock. */
        var gate: CompletableDeferred<Unit>? = null

        /** When true, the fetch never returns, simulating a hung network. */
        var refreshHangs = false

        override suspend fun loadCached(): VoiceCatalog? {
            gate?.await()
            return cached
        }

        override suspend fun refresh(): VoiceCatalogState {
            refreshes++
            if (refreshHangs) awaitCancellation()
            return refreshed
        }
    }

    private class FakeEngine(override val engineName: String) : STTEngine {
        override suspend fun transcribe(segment: STTSegment, language: String?): STTResult = STTResult.Success("")
    }

    private class FakeEngineFactory(private val system: STTEngine, private val cloud: STTEngine) : DictationEngineFactory {
        val cloudCalls = mutableListOf<Triple<VoiceSttEntry, String, String>>()
        var route: SystemSTTRoute = SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "zh-Hans")
        val downloads = mutableListOf<String>()
        val pipeSessions = mutableListOf<Pair<SystemSTTRoute.Pipe, DictationLiveSession>>()

        override fun system(): STTEngine = system

        override suspend fun startPipeSession(route: SystemSTTRoute.Pipe): DictationLiveSession {
            val session = object : DictationLiveSession {
                override val live: StateFlow<LiveTranscript> = MutableStateFlow(LiveTranscript())
                override fun onPcm(samples: ShortArray, count: Int) = Unit
                override fun stop() = Unit
                override suspend fun await(): STTResult = STTResult.Success("")
                override fun cancel() = Unit
            }
            pipeSessions += route to session
            return session
        }

        override suspend fun systemRoute(language: String?): SystemSTTRoute = route

        override suspend fun downloadLanguagePack(language: String): Boolean {
            downloads += language
            return true
        }

        override suspend fun startSelfRecord(route: SystemSTTRoute.SelfRecord): SystemSTTSelfRecordSession =
            error("not used")

        override fun cloud(entry: VoiceSttEntry, baseUrl: String, apiKey: String): STTEngine {
            cloudCalls += Triple(entry, baseUrl, apiKey)
            return cloud
        }
    }

    private val systemEngine = FakeEngine("system")
    private val cloudEngine = FakeEngine("cloud")
    private val engines = FakeEngineFactory(systemEngine, cloudEngine)
    private val prefs = TestSharedPreferences()
    private val settings = VoiceEngineSettings(prefsProvider = { prefs })
    private val acceptedDisclosure = VoiceDisclosureStore { TestSharedPreferences() }.also {
        ProviderKind.entries.forEach { kind -> it.markAccepted(kind, VoiceDirection.Stt) }
    }
    private val catalog = FakeCatalog()

    private val sttEntry = VoiceSttEntry(
        model = "gpt-transcribe",
        transport = VoiceTransport.OpenAITranscriptions,
        path = "/v1/audio/transcriptions",
        maxBytes = 25_000_000,
        maxDurationSec = 600,
        languageField = "language",
        isDefault = true,
    )
    private val voiceCatalog = VoiceCatalog(providers = mapOf(ProviderKind.OpenAI to VoiceProviderCatalog(stt = listOf(sttEntry))))
    private val cloudSelection = VoiceEngineSelection.Cloud(
        providerKind = ProviderKind.OpenAI,
        connectionId = "conn-openai",
        model = "gpt-transcribe",
    )
    private val openAI = Provider(
        id = "conn-openai",
        kind = ProviderKind.OpenAI,
        apiKey = "sk-live",
        baseUrlText = "https://api.openai.com/v1",
    )

    private val source = DictationConversationSttSource(
        engines = engines,
        settings = settings,
        catalog = catalog,
        providers = { listOf(openAI) },
        language = { "zh-Hans" },
        disclosure = acceptedDisclosure,
    )

    @Test
    fun `cloud returns null when catalog never loads within the limit`() = runTest {
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        // The cached read waits for another stuck refresh to release the lock; even once released, the cold fetch hangs.
        catalog.gate = CompletableDeferred()
        catalog.refreshHangs = true

        val result = async { source.resolve() }
        advanceTimeBy(DictationController.CATALOG_REFRESH_TIMEOUT_MILLIS - 1)
        runCurrent()
        assertFalse(result.isCompleted)
        advanceTimeBy(1)
        runCurrent()
        assertTrue(result.isCompleted)

        val stt = result.await() as ConversationStt.FromFile
        assertSame(systemEngine, stt.engine)
        assertEquals(null, stt.providerKind)
        assertTrue(engines.cloudCalls.isEmpty())
        assertEquals(cloudSelection, settings.selection(VoiceDirection.Stt))
    }

    @Test
    fun `cloud uses cached catalog when available`() = runTest {
        settings.setSelection(VoiceDirection.Stt, cloudSelection)
        catalog.cached = voiceCatalog

        val stt = source.resolve() as ConversationStt.FromFile

        assertSame(cloudEngine, stt.engine)
        // The cloud engine does not open a realtime session
        assertEquals(null, stt.live)
        assertEquals("openAI", stt.providerKind)
        assertEquals("zh-Hans", stt.language)
        assertEquals(0, catalog.refreshes)
        assertEquals(sttEntry, engines.cloudCalls.single().first)
    }

    @Test
    fun `conversation never offers a language pack on pipe or self record routes`() = runTest {
        engines.route = SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "zh-Hans", languagePackOffer = true)
        val pipe = source.resolve() as ConversationStt.FromFile
        assertSame(systemEngine, pipe.engine)

        engines.route = SystemSTTRoute.SelfRecord(SystemSTTRecognizer.DEFAULT, "zh-Hans", languagePackOffer = true)
        assertTrue(source.resolve() is ConversationStt.SelfRecord)

        // Matches iOS: no prompt in conversation, no prompted state recorded, no download
        assertFalse(settings.languagePackOffered("zh-Hans"))
        assertTrue(engines.downloads.isEmpty())
    }

    @Test
    fun `pipe route gives the system engine with a live session opener on that route`() = runTest {
        val route = SystemSTTRoute.Pipe(SystemSTTRecognizer.DEFAULT, "zh-Hans")
        engines.route = route
        val stt = source.resolve() as ConversationStt.FromFile
        assertSame(systemEngine, stt.engine)
        // Resolving alone does not open a session: it opens when each sentence starts.
        assertTrue(engines.pipeSessions.isEmpty())
        val opened = stt.live!!.invoke()
        assertSame(engines.pipeSessions.single().second, opened)
        assertEquals(route, engines.pipeSessions.single().first)
    }
}
