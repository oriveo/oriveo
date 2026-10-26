package ai.oriveo.community.core.voice

import ai.oriveo.community.core.model.ProviderKind
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.toByteArray
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import java.io.File
import java.util.Collections
import java.util.Locale
import java.util.concurrent.Executors
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CloudSpeechEngineTest {

    @get:Rule
    val tmp = TemporaryFolder()

    /** Entries decoded from the real catalog fixture: path / outputFormat / maxChars / voices all come from production decoding. */
    private val catalog: VoiceCatalog = VoiceCatalogDecoder.decode(
        Json.parseToJsonElement(workspaceFile("shared/model-contracts/voice_catalog_contract.v2.json").readText())
            .jsonObject["data"],
    )
    private val entry: VoiceTtsEntry = catalog.provider(ProviderKind.OpenAI).tts.first { it.isDefault }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val requests: MutableList<HttpRequestData> = Collections.synchronizedList(mutableListOf())
    private val inputs: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private val sleeps: MutableList<Long> = Collections.synchronizedList(mutableListOf())
    private val cache by lazy { SpeechAudioCache(tmp.root.resolve("voice-tts")) }

    @After
    fun tearDown() {
        scope.cancel()
    }

    private val systems: MutableList<FakeSystemEngine> = Collections.synchronizedList(mutableListOf())
    private var systemAutoPlay = true

    private fun engine(
        player: FakePlayer,
        cache: SpeechAudioCache = this.cache,
        scope: CoroutineScope = this.scope,
        fileDeleter: (File) -> Unit = { it.delete() },
        handler: suspend MockRequestHandleScope.(index: Int, input: String) -> HttpResponseData,
    ): CloudSpeechEngine {
        val mock = MockEngine { request ->
            val body = String(request.body.toByteArray(), Charsets.UTF_8)
            val input = Json.parseToJsonElement(body).jsonObject.getValue("input").jsonPrimitive.content
            val index = synchronized(requests) {
                requests += request
                inputs += input
                requests.size - 1
            }
            handler(index, input)
        }
        return CloudSpeechEngine(
            httpClient = HttpClient(mock),
            entry = entry,
            providerKind = ProviderKind.OpenAI,
            baseUrl = "https://api.openai.com/v1/",
            apiKey = "sk-test",
            voice = null,
            slider = null,
            cache = cache,
            playerFactory = { player },
            fallbackFactory = { FakeSystemEngine(systemAutoPlay).also { systems += it } },
            providerDisplayName = PROVIDER_NAME,
            scope = scope,
            sleeper = { sleeps += it },
            fileDeleter = fileDeleter,
        )
    }

    private fun MockRequestHandleScope.audio(input: String): HttpResponseData =
        respond(
            content = audioBytes(input),
            status = HttpStatusCode.OK,
            headers = headersOf(HttpHeaders.ContentType, "audio/mpeg"),
        )

    private fun MockRequestHandleScope.status(code: Int): HttpResponseData =
        respond(content = """{"error":{"message":"x"}}""", status = HttpStatusCode.fromValue(code))

    private fun audioBytes(input: String): ByteArray = "mp3:$input".toByteArray(Charsets.UTF_8)

    /** Each sentence is 150 code points: chunk 1 = sentence 0; chunk 2 (limit 400) holds sentences 1 and 2; chunk 3 (limit 800) holds sentences 3 and 4. */
    private val longSentences = List(5) { index -> "S$index " + "x".repeat(146) + "." }

    @Test
    fun `plays chunks in order reporting first sentence index`() = runBlocking {
        val player = FakePlayer()
        val listener = RecordingListener()
        engine(player) { _, input -> audio(input) }.speak(longSentences, Locale.US, listener)

        listener.awaitEnd()
        val chunks = CloudReadAloudRules.ttsChunks(longSentences, entry.maxChars)
        assertEquals(listOf(0, 1, 3), chunks.map { it.firstSentenceIndex })
        assertEquals(listOf("start:0", "start:1", "start:3", "done"), listener.events)
        assertEquals(chunks.map { it.text }, inputs)
        assertEquals(chunks.map { String(audioBytes(it.text)) }, player.played.map { String(it) })

        val request = requests.first()
        assertEquals("POST", request.method.value)
        assertEquals("https://api.openai.com/v1/audio/speech", request.url.toString())
        assertEquals("Bearer sk-test", request.headers[HttpHeaders.Authorization])
        assertEquals("application/json", request.body.contentType?.withoutParameters()?.toString())
        assertEquals(emptyList<Long>(), sleeps)
    }

    @Test
    fun `synthesizeToFile fetches through cache without playing`() = runBlocking {
        val player = FakePlayer()
        val engine = engine(player) { _, input -> audio(input) }
        val text = "Hello there."

        val first = engine.synthesizeToFile(text, Locale.US)!!
        assertEquals(1, first.size)
        assertArrayEquals(audioBytes(text), first[0].file.readBytes())
        assertEquals(false, first[0].temporary)
        assertEquals(emptyList<ByteArray>(), player.played)

        // The second run hits the same cache entry and makes no request.
        val second = engine.synthesizeToFile(text, Locale.US)!!
        assertEquals(first[0].file, second[0].file)
        assertEquals(1, requests.size)
    }

    @Test
    fun `synthesizeToFile returns null after retries fail without fallback`() = runBlocking {
        val player = FakePlayer()
        val result = engine(player) { _, _ -> status(400) }.synthesizeToFile("Hello there.", Locale.US)
        assertEquals(null, result)
        assertEquals(emptyList<FakeSystemEngine>(), systems.toList())
        assertEquals(emptyList<ByteArray>(), player.played)
    }

    @Test
    fun `prefetches only next chunk`() = runBlocking {
        val gates = List(3) { CompletableDeferred<Unit>() }
        val player = FakePlayer(gates)
        val listener = RecordingListener()
        val arrived = List(3) { CompletableDeferred<Unit>() }
        engine(player) { index, input ->
            arrived[index].complete(Unit)
            audio(input)
        }.speak(longSentences, Locale.US, listener)

        // Chunk 1 is playing: only chunk 2 is prefetched.
        withTimeout(TIMEOUT_MS) {
            player.started[0].await()
            arrived[1].await()
        }
        delay(SETTLE_MS)
        assertEquals(2, requests.size)

        // Chunk 3 is requested only once chunk 2 starts playing.
        gates[0].complete(Unit)
        withTimeout(TIMEOUT_MS) {
            player.started[1].await()
            arrived[2].await()
        }
        assertEquals(3, requests.size)

        gates[1].complete(Unit)
        gates[2].complete(Unit)
        listener.awaitEnd()
        assertEquals(listOf("start:0", "start:1", "start:3", "done"), listener.events)
        assertEquals(3, requests.size)
    }

    @Test
    fun `cache hit skips request`() = runBlocking {
        val sentences = listOf("Hello there.")
        val first = RecordingListener()
        val player = FakePlayer()
        val engine = engine(player) { _, input -> audio(input) }
        engine.speak(sentences, Locale.US, first)
        first.awaitEnd()
        assertEquals(1, requests.size)

        val second = RecordingListener()
        engine.speak(sentences, Locale.US, second)
        second.awaitEnd()

        assertEquals(1, requests.size)
        assertEquals(listOf("start:0", "done"), second.events)
        assertEquals(2, player.played.size)
        assertArrayEquals(audioBytes("Hello there."), player.played[1])

        // The hit is exactly the cache file written under the production key.
        val key = SpeechCacheKey(
            text = "Hello there.",
            providerKind = ProviderKind.OpenAI,
            model = entry.model,
            voice = entry.defaultVoice.id,
            effectiveSpeed = 1.0,
            language = "en-US",
            outputFormat = entry.outputFormat,
        )
        assertArrayEquals(audioBytes("Hello there."), File(tmp.root.resolve("voice-tts"), key.fileName).readBytes())
    }

    @Test
    fun `5xx retried then plays`() = runBlocking {
        val player = FakePlayer()
        val listener = RecordingListener()
        engine(player) { index, input -> if (index == 0) status(503) else audio(input) }
            .speak(listOf("Hello there."), Locale.US, listener)

        listener.awaitEnd()
        assertEquals(listOf("start:0", "done"), listener.events)
        assertEquals(2, requests.size)
        assertEquals(listOf(1000L), sleeps)
        assertArrayEquals(audioBytes("Hello there."), player.played.single())
    }

    @Test
    fun `stop cancels in flight and player`() = runBlocking {
        val player = FakePlayer()
        val listener = RecordingListener()
        val arrived = CompletableDeferred<Unit>()
        val cancelled = CompletableDeferred<Unit>()
        val engine = engine(player) { _, _ ->
            arrived.complete(Unit)
            try {
                awaitCancellation()
            } catch (e: CancellationException) {
                cancelled.complete(Unit)
                throw e
            }
        }
        engine.speak(listOf("Hello there."), Locale.US, listener)
        withTimeout(TIMEOUT_MS) { arrived.await() }

        engine.stop()

        withTimeout(TIMEOUT_MS) { cancelled.await() }
        assertTrue(player.stopped)
        delay(SETTLE_MS)
        assertEquals(emptyList<String>(), listener.events)
        assertEquals(emptyList<ByteArray>(), player.played)
        assertEquals(1, requests.size)
    }

    @Test
    fun `stop deletes temporary chunk files`() = runBlocking {
        // Temporary audio is created under the cache directory (cleaned by cache trim after a process kill), not in java.io.tmpdir
        val tempDir = tmp.root.resolve("tiny")
        fun temps(): Set<String> =
            tempDir.listFiles { file -> file.name.startsWith("voice-tts-") && file.name.endsWith(".${entry.outputFormat}") }
                ?.map { it.name }?.toSet().orEmpty()
        val before = temps()
        // Limit of 1 byte: cache writes always fail, so every chunk lands in a temp file.
        val failingCache = SpeechAudioCache(tmp.root.resolve("tiny"), maxBytes = 1)
        val gates = List(3) { CompletableDeferred<Unit>() }
        val player = FakePlayer(gates)
        val listener = RecordingListener()
        val arrived = List(3) { CompletableDeferred<Unit>() }
        val engine = engine(player, failingCache) { index, input ->
            arrived[index].complete(Unit)
            audio(input)
        }
        engine.speak(longSentences, Locale.US, listener)

        // Chunk 1 is playing; chunk 2 is prefetched to disk but not yet played.
        withTimeout(TIMEOUT_MS) {
            player.started[0].await()
            arrived[1].await()
        }
        delay(SETTLE_MS)
        assertTrue((temps() - before).isNotEmpty())

        engine.stop()
        delay(SETTLE_MS)

        assertEquals(emptySet<String>(), temps() - before)
        assertEquals(1, player.played.size)
    }

    @Test
    fun `401 falls back to system from failed chunk with one notice`() = runBlocking {
        val player = FakePlayer()
        val listener = RecordingListener()
        engine(player) { _, _ -> status(401) }.speak(longSentences, Locale.US, listener)

        listener.awaitEnd()
        assertEquals(1, requests.size)
        assertEquals(emptyList<Long>(), sleeps)
        assertEquals(emptyList<ByteArray>(), player.played)
        val system = systems.single()
        assertEquals(longSentences, system.spoken.single())
        assertEquals(Locale.US, system.locales.single())
        assertEquals(
            listOf("fallback:$PROVIDER_NAME", "start:0", "start:1", "start:2", "start:3", "start:4", "done"),
            listener.events,
        )
    }

    @Test
    fun `playback error falls back`() = runBlocking {
        val player = FakePlayer(failAt = setOf(0))
        val listener = RecordingListener()
        engine(player) { _, input -> audio(input) }.speak(longSentences, Locale.US, listener)

        listener.awaitEnd()
        // Chunk 1 fails to play: the prefetched chunk 2 is discarded and chunk 3 is not requested.
        assertEquals(1, player.played.size)
        assertTrue(requests.size <= 2)
        assertEquals(longSentences, systems.single().spoken.single())
        assertEquals("start:0", listener.events[0])
        assertEquals("fallback:$PROVIDER_NAME", listener.events[1])
        assertEquals(1, listener.events.count { it.startsWith("fallback:") })
        assertEquals("done", listener.events.last())
    }

    @Test
    fun `fallback progress continues sentence index`() = runBlocking {
        val player = FakePlayer()
        val listener = RecordingListener()
        engine(player) { index, input -> if (index == 1) status(403) else audio(input) }
            .speak(longSentences, Locale.US, listener)

        listener.awaitEnd()
        // Chunk 2 (sentences 1 and 2) fails: the system engine resumes from sentence 1, with progress indexed by the full sentence list.
        assertEquals(longSentences.drop(1), systems.single().spoken.single())
        assertEquals(
            listOf("start:0", "fallback:$PROVIDER_NAME", "start:1", "start:2", "start:3", "start:4", "done"),
            listener.events,
        )
        assertEquals(2, requests.size)
        assertEquals(1, player.played.size)
    }

    @Test
    fun `stop during fallback stops system engine`() = runBlocking {
        systemAutoPlay = false
        val player = FakePlayer()
        val listener = RecordingListener()
        val engine = engine(player) { _, _ -> status(401) }
        engine.speak(longSentences, Locale.US, listener)
        val system = withTimeout(TIMEOUT_MS) {
            while (systems.isEmpty() || systems[0].spoken.isEmpty()) delay(10)
            systems[0]
        }

        engine.stop()

        assertTrue(system.stopped)
        assertEquals(listOf("fallback:$PROVIDER_NAME"), listener.events)
    }

    /** Fake system engine: with autoPlay, calls onStart for each sentence synchronously, then onDoneAll. */
    private class FakeSystemEngine(private val autoPlay: Boolean) : SpeechEngine {
        val spoken: MutableList<List<String>> = Collections.synchronizedList(mutableListOf())
        val locales: MutableList<Locale> = Collections.synchronizedList(mutableListOf())

        @Volatile
        var stopped = false

        override val engineName: String = "system"

        override fun speak(utterances: List<String>, locale: Locale, listener: SpeechEngine.Listener) {
            locales += locale
            spoken += utterances
            if (!autoPlay) return
            utterances.indices.forEach { listener.onStart(it) }
            listener.onDoneAll()
        }

        override fun stop() {
            stopped = true
        }
    }

    /** Protocol-specific entries (decoded from the real catalog) plus MockEngine; requests are recorded as-is, and playback goes through the production speak, send, cache path. */
    private fun privateEngine(
        kind: ProviderKind,
        model: String,
        player: FakePlayer,
        handler: suspend MockRequestHandleScope.(request: HttpRequestData) -> HttpResponseData,
    ): Pair<CloudSpeechEngine, VoiceTtsEntry> {
        val privateEntry = catalog.entry(kind, VoiceDirection.Tts, model) as VoiceTtsEntry
        val mock = MockEngine { request ->
            requests += request
            handler(request)
        }
        val engine = CloudSpeechEngine(
            httpClient = HttpClient(mock),
            entry = privateEntry,
            providerKind = kind,
            baseUrl = "https://api.example.com/",
            apiKey = "sk-test",
            voice = null,
            slider = 1.5f,
            cache = cache,
            playerFactory = { player },
            fallbackFactory = { FakeSystemEngine(systemAutoPlay).also { systems += it } },
            providerDisplayName = PROVIDER_NAME,
            scope = scope,
            sleeper = { sleeps += it },
        )
        return engine to privateEntry
    }

    private fun MockRequestHandleScope.json(body: String): HttpResponseData =
        respond(content = body, status = HttpStatusCode.OK, headers = headersOf(HttpHeaders.ContentType, "application/json"))

    private fun cachedBytes(kind: ProviderKind, entry: VoiceTtsEntry, text: String, speed: Double): ByteArray {
        val key = SpeechCacheKey(
            text = text,
            providerKind = kind,
            model = entry.model,
            voice = entry.defaultVoice.id,
            effectiveSpeed = speed,
            language = "en-US",
            outputFormat = entry.outputFormat,
        )
        return File(tmp.root.resolve("voice-tts"), key.fileName).readBytes()
    }

    @Test
    fun `gemini tts decodes base64 before cache`() = runBlocking {
        val wav = byteArrayOf(0x52, 0x49, 0x46, 0x46, 1, 2, 3)
        val b64 = java.util.Base64.getEncoder().encodeToString(wav)
        val player = FakePlayer()
        val listener = RecordingListener()
        val (engine, geminiEntry) = privateEngine(ProviderKind.Gemini, "gemini-3.8-flash-tts", player) {
            json("""{"steps":[{"type":"model_output","content":[{"type":"text","text":"x"},{"type":"audio","mime_type":"audio/wav","data":"$b64"}]}]}""")
        }
        engine.speak(listOf("Hello there."), Locale.US, listener)

        listener.awaitEnd()
        assertEquals(listOf("start:0", "done"), listener.events)
        val request = requests.single()
        assertEquals("https://api.example.com/v1beta/interactions", request.url.toString())
        assertEquals("sk-test", request.headers["x-goog-api-key"])
        assertEquals(null, request.headers[HttpHeaders.Authorization])
        val sent = Json.parseToJsonElement(String(request.body.toByteArray(), Charsets.UTF_8)).jsonObject
        assertEquals(CloudReadAloudRules.requestBody(geminiEntry, "Hello there.", "Kore", 1.5, "en-US"), sent)
        assertArrayEquals(wav, player.played.single())
        assertArrayEquals(wav, cachedBytes(ProviderKind.Gemini, geminiEntry, "Hello there.", CloudReadAloudRules.effectiveSpeed(geminiEntry, 1.5f)))
    }

    @Test
    fun `dashscope tts downloads url without auth`() = runBlocking {
        val wav = byteArrayOf(0x52, 0x49, 0x46, 0x46, 9, 8)
        val download = "https://dashscope-result.oss-cn-beijing.aliyuncs.com/tts/abc.wav?Expires=1&Signature=x"
        val player = FakePlayer()
        val listener = RecordingListener()
        var downloads = 0
        val (engine, qwenEntry) = privateEngine(ProviderKind.Qwen, "qwen3-tts-flash", player) { request ->
            if (request.url.host == "api.example.com") {
                json("""{"output":{"audio":{"url":"$download","id":"a"}},"request_id":"r"}""")
            } else {
                downloads++
                // The second hop fails once: the same status-code retry rule applies and the whole request is resent.
                if (downloads == 1) {
                    status(503)
                } else {
                    respond(content = wav, status = HttpStatusCode.OK, headers = headersOf(HttpHeaders.ContentType, "audio/wav"))
                }
            }
        }
        engine.speak(listOf("Hello there."), Locale.US, listener)

        listener.awaitEnd()
        assertEquals(listOf("start:0", "done"), listener.events)
        assertEquals(4, requests.size)
        assertEquals(listOf(1000L), sleeps)
        val post = requests[0]
        assertEquals("Bearer sk-test", post.headers[HttpHeaders.Authorization])
        val get = requests[1]
        assertEquals(download, get.url.toString())
        assertEquals("GET", get.method.value)
        assertEquals(null, get.headers[HttpHeaders.Authorization])
        assertEquals(null, get.headers["x-goog-api-key"])
        assertArrayEquals(wav, player.played.single())
        assertArrayEquals(wav, cachedBytes(ProviderKind.Qwen, qwenEntry, "Hello there.", CloudReadAloudRules.effectiveSpeed(qwenEntry, 1.5f)))
    }

    @Test
    fun `mistral speech decodes audio data`() = runBlocking {
        val mp3 = "ID3-mistral".toByteArray(Charsets.UTF_8)
        val b64 = java.util.Base64.getEncoder().encodeToString(mp3)
        val player = FakePlayer()
        val listener = RecordingListener()
        val (engine, mistralEntry) = privateEngine(ProviderKind.Mistral, "voxtral-mini-tts-3-0", player) {
            json("""{"audio_data":"$b64"}""")
        }
        engine.speak(listOf("Hello there."), Locale.US, listener)

        listener.awaitEnd()
        assertEquals(listOf("start:0", "done"), listener.events)
        val request = requests.single()
        assertEquals("Bearer sk-test", request.headers[HttpHeaders.Authorization])
        val sent = Json.parseToJsonElement(String(request.body.toByteArray(), Charsets.UTF_8)).jsonObject
        assertEquals(null, sent["speed"])
        assertEquals("en_paul_neutral", sent["voice_id"]!!.jsonPrimitive.content)
        assertArrayEquals(mp3, player.played.single())
        assertArrayEquals(mp3, cachedBytes(ProviderKind.Mistral, mistralEntry, "Hello there.", CloudReadAloudRules.effectiveSpeed(mistralEntry, 1.5f)))
    }

    @Test
    fun `mistral speech bad base64 falls back without retry`() = runBlocking {
        val player = FakePlayer()
        val listener = RecordingListener()
        val (engine, _) = privateEngine(ProviderKind.Mistral, "voxtral-mini-tts-3-0", player) {
            json("""{"audio_data":"not base64!"}""")
        }
        engine.speak(listOf("Hello there."), Locale.US, listener)

        listener.awaitEnd()
        assertEquals(1, requests.size)
        assertEquals(emptyList<Long>(), sleeps)
        assertTrue(player.played.isEmpty())
        assertEquals(1, systems.size)
    }

    @Test
    fun `temp_files_deleted_off_main_even_when_cancelled`() = runBlocking {
        val tempDir = tmp.root.resolve("tiny-main")
        fun temps(): Set<String> =
            tempDir.listFiles { file -> file.name.startsWith("voice-tts-") }?.map { it.name }?.toSet().orEmpty()
        // Limit of 1 byte: cache writes always fail, so every chunk lands in a temp file.
        val failingCache = SpeechAudioCache(tempDir, maxBytes = 1)
        // Single-threaded stand-in for the main thread: the session coroutine runs on it, and deletion must not happen on this thread.
        val main = Executors.newSingleThreadExecutor { Thread(it, MAIN_THREAD) }
        val mainScope = CoroutineScope(SupervisorJob() + main.asCoroutineDispatcher())
        val deleteThreads: MutableList<String> = Collections.synchronizedList(mutableListOf())
        val gates = List(3) { CompletableDeferred<Unit>() }
        val player = FakePlayer(gates)
        val arrived = List(3) { CompletableDeferred<Unit>() }
        try {
            val engine = engine(
                player,
                failingCache,
                scope = mainScope,
                fileDeleter = { file ->
                    deleteThreads += Thread.currentThread().name
                    file.delete()
                },
            ) { index, input ->
                arrived[index].complete(Unit)
                audio(input)
            }
            engine.speak(longSentences, Locale.US, RecordingListener())
            // Chunk 1 is playing; chunk 2 is prefetched to disk but not yet played.
            withTimeout(TIMEOUT_MS) {
                player.started[0].await()
                arrived[1].await()
            }
            delay(SETTLE_MS)
            assertTrue(temps().isNotEmpty())

            engine.stop()
            delay(SETTLE_MS)

            assertEquals(emptySet<String>(), temps())
            assertTrue("deleted the playing and the prefetched chunk: $deleteThreads", deleteThreads.size >= 2)
            // Coroutine debug mode appends " @coroutine#N" to thread names, so compare by prefix.
            assertTrue("deletes off main: $deleteThreads", deleteThreads.none { it.startsWith(MAIN_THREAD) })
        } finally {
            mainScope.cancel()
            main.shutdown()
        }
    }

    private class FakePlayer(
        private val gates: List<CompletableDeferred<Unit>> = emptyList(),
        private val failAt: Set<Int> = emptySet(),
    ) : ChunkPlayer {
        val played: MutableList<ByteArray> = Collections.synchronizedList(mutableListOf())
        val started = List(8) { CompletableDeferred<Unit>() }

        @Volatile
        var stopped = false

        override suspend fun play(file: File): Boolean {
            val index = synchronized(played) {
                played += file.readBytes()
                played.size - 1
            }
            started[index].complete(Unit)
            gates.getOrNull(index)?.await()
            return index !in failAt
        }

        override fun stop() {
            stopped = true
        }
    }

    private class RecordingListener : SpeechEngine.Listener {
        val events: MutableList<String> = Collections.synchronizedList(mutableListOf())
        private val ended = CompletableDeferred<Unit>()

        override fun onStart(index: Int) {
            events += "start:$index"
        }

        override fun onDoneAll() {
            events += "done"
            ended.complete(Unit)
        }

        override fun onError(error: SpeechError) {
            events += "error:$error"
            ended.complete(Unit)
        }

        override fun onFallback(providerDisplayName: String) {
            events += "fallback:$providerDisplayName"
        }

        suspend fun awaitEnd() = withTimeout(TIMEOUT_MS) { ended.await() }
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("cannot find $relative")
    }

    private companion object {
        const val TIMEOUT_MS = 10_000L
        const val SETTLE_MS = 200L
        const val MAIN_THREAD = "fake-main"
        const val PROVIDER_NAME = "OpenAI"
    }
}
