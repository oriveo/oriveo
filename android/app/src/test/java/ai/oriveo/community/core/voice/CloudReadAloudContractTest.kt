package ai.oriveo.community.core.voice

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.http.HttpStatusCode
import java.io.File
import java.util.Base64
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Compares CloudReadAloudRules output case by case against the five case groups in shared/voice-contracts/cloud-read-aloud.v1.json; entry references are decoded from the voice catalog v2 contract. */
class CloudReadAloudContractTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/cloud-read-aloud.v1.json").readText()).jsonObject

    private val catalog: VoiceCatalog = VoiceCatalogDecoder.decode(
        Json.parseToJsonElement(
            workspaceFile("shared/model-contracts/voice_catalog_contract.v2.json").readText(),
        ).jsonObject["data"],
    )

    private fun cases(key: String): List<JsonObject> {
        val list = fixture[key]!!.jsonArray.map { it.jsonObject }
        assertTrue("$key must not be empty", list.isNotEmpty())
        return list
    }

    private fun JsonObject.id(): String = this["id"]!!.jsonPrimitive.content
    private fun JsonObject.input(): JsonObject = this["input"]!!.jsonObject

    private fun JsonObject.str(key: String): String? = this[key].let { el ->
        if (el == null || el is JsonNull) null else el.jsonPrimitive.content
    }

    private fun ttsEntry(ref: JsonObject): VoiceTtsEntry {
        val kind = VoiceProviderKinds.fromRawValue(ref.str("providerKind"))!!
        assertEquals(VoiceDirection.Tts.rawValue, ref.str("direction"))
        return catalog.entry(kind, VoiceDirection.Tts, ref.str("model")!!) as VoiceTtsEntry
    }

    @Test
    fun constantsMatchFixture() {
        val constants = fixture["constants"]!!.jsonObject
        assertEquals(constants["firstChunkMaxCodePoints"]!!.jsonPrimitive.int, CloudReadAloudRules.FIRST_CHUNK_MAX_CODE_POINTS)
        assertEquals(constants["firstChunkMaxSentences"]!!.jsonPrimitive.int, CloudReadAloudRules.FIRST_CHUNK_MAX_SENTENCES)
        assertEquals(constants["laterChunkCapCodePoints"]!!.jsonPrimitive.int, CloudReadAloudRules.LATER_CHUNK_CAP_CODE_POINTS)
        assertEquals(constants.str("sentenceJoiner"), CloudReadAloudRules.SENTENCE_JOINER)
        assertEquals(constants["prefetchChunks"]!!.jsonPrimitive.int, CloudReadAloudRules.PREFETCH_CHUNKS)
        assertEquals(
            constants["languageMinConfidence"]!!.jsonPrimitive.double,
            CloudReadAloudRules.LANGUAGE_MIN_CONFIDENCE,
            0.0,
        )
        assertEquals(constants["speedDecimals"]!!.jsonPrimitive.int, CloudReadAloudRules.SPEED_DECIMALS)
        assertEquals(
            constants["xaiTtsLanguages"]!!.jsonArray.map { it.jsonPrimitive.content },
            CloudReadAloudRules.XAI_TTS_LANGUAGES,
        )
        assertEquals(
            constants["xaiDefaultRegion"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content },
            CloudReadAloudRules.XAI_DEFAULT_REGION,
        )
    }

    @Test
    fun chunkCases() {
        for (case in cases("chunkCases")) {
            val input = case.input()
            val sentences = input["sentences"]!!.jsonArray.map { it.jsonPrimitive.content }
            val chunks = CloudReadAloudRules.ttsChunks(sentences, input["maxChars"]!!.jsonPrimitive.int)
            val expected = case["expected"]!!.jsonArray.map { it.jsonPrimitive.content }
            assertEquals(case.id(), expected, chunks.map { it.text })
            // The chunk's first-sentence index points at that sentence in the input list; once trimmed, it is the start of the chunk.
            for (chunk in chunks) {
                val first = DictationRules.trim(sentences[chunk.firstSentenceIndex])
                assertTrue("${case.id()} first sentence ${chunk.firstSentenceIndex}", first.isNotEmpty() && chunk.text.startsWith(first))
            }
            assertEquals("${case.id()} first-sentence indices increase", chunks.map { it.firstSentenceIndex }.sorted(), chunks.map { it.firstSentenceIndex })
        }
    }

    @Test
    fun readingLanguageCases() {
        for (case in cases("readingLanguageCases")) {
            val input = case.input()
            val hypotheses = input["hypotheses"]!!.jsonArray.map { el ->
                val obj = el.jsonObject
                LanguageHypothesis(obj.str("language")!!, obj["confidence"]!!.jsonPrimitive.double)
            }
            assertEquals(
                case.id(),
                case.str("expected"),
                CloudReadAloudRules.readingLanguage(hypotheses, input.str("uiLocale")!!),
            )
        }
    }

    @Test
    fun xaiLanguageCases() {
        for (case in cases("xaiLanguageCases")) {
            assertEquals(case.id(), case.str("expected"), CloudReadAloudRules.xaiLanguage(case.input().str("language")!!))
        }
    }

    @Test
    fun bodyCases() {
        for (case in cases("bodyCases")) {
            val input = case.input()
            val entry = ttsEntry(input["entry"]!!.jsonObject)
            val expected = case["expected"]!!.jsonObject
            assertEquals("${case.id()}.method", expected.str("method"), CloudReadAloudRules.REQUEST_METHOD)
            assertEquals("${case.id()}.path", expected.str("path"), entry.path)
            assertEquals(
                "${case.id()}.url",
                "https://api.example.com${expected.str("path")}",
                CloudReadAloudRules.requestUrl("https://api.example.com/ignored/base?x=1", entry),
            )
            val body = CloudReadAloudRules.requestBody(
                entry = entry,
                text = input.str("text")!!,
                voice = input.str("voice")!!,
                slider = input["speed"]?.jsonPrimitive?.double,
                language = input.str("language")!!,
            )
            assertEquals("${case.id()}.json", expected["json"]!!.jsonObject, body)
            // Headers come from the request CloudSpeechEngine actually sends; when a case has no headers, the default is Bearer + JSON.
            val apiKey = input.str("apiKey") ?: "test-key"
            val expectedHeaders = expected["headers"]?.jsonObject?.mapValues { it.value.jsonPrimitive.content }
                ?: mapOf("Authorization" to "Bearer $apiKey", "Content-Type" to "application/json")
            assertEquals(
                "${case.id()}.headers",
                expectedHeaders,
                wireHeaders(input["entry"]!!.jsonObject, entry, apiKey, input.str("text")!!, input.str("language")!!),
            )
        }
    }

    /** The first request CloudSpeechEngine sends through MockEngine: request headers as-is plus the body's Content-Type. */
    private fun wireHeaders(ref: JsonObject, entry: VoiceTtsEntry, apiKey: String, text: String, language: String): Map<String, String> {
        val captured = mutableListOf<HttpRequestData>()
        val mock = MockEngine { request ->
            captured += request
            respond(content = "{}", status = HttpStatusCode.BadRequest)
        }
        val engine = CloudSpeechEngine(
            httpClient = HttpClient(mock),
            entry = entry,
            providerKind = VoiceProviderKinds.fromRawValue(ref.str("providerKind"))!!,
            baseUrl = "https://api.example.com/",
            apiKey = apiKey,
            voice = null,
            slider = null,
            cache = SpeechAudioCache(tmp.newFolder()),
            playerFactory = { error("not played") },
            fallbackFactory = null,
            providerDisplayName = "test",
            scope = CoroutineScope(Dispatchers.Default),
            sleeper = {},
        )
        runBlocking { engine.synthesizeToFile(text, Locale.forLanguageTag(language)) }
        val request = captured.first()
        // Ktor's default transformation adds `*/*` when Accept is unset; only that default is dropped, so an Accept explicitly set by production code is still compared.
        return request.headers.entries()
            .filterNot { it.key.equals("Accept", ignoreCase = true) && it.value == listOf("*/*") }
            .associate { it.key to it.value.joinToString(",") } +
            listOfNotNull(request.body.contentType?.let { "Content-Type" to it.toString() })
    }

    @Test
    fun audioResponseCases() {
        for (case in cases("audioResponseCases")) {
            val input = case.input()
            val transport = VoiceTransport.fromRawValue(input.str("transport")!!, VoiceDirection.Tts)!!
            val actual = CloudReadAloudRules.audioResponse(transport, input["body"])
            val expected = case["expected"]
            when {
                expected == null || expected is JsonNull -> assertNull(case.id(), actual)
                expected.jsonObject.containsKey("downloadUrl") -> assertEquals(
                    case.id(),
                    TtsAudioResponse.Download(expected.jsonObject.str("downloadUrl")!!),
                    actual,
                )
                else -> assertEquals(
                    case.id(),
                    expected.jsonObject.str("audioBase64"),
                    Base64.getEncoder().encodeToString((actual as TtsAudioResponse.Audio).bytes),
                )
            }
        }
    }

    @Test
    fun floatSliderConvertsToDoubleFirst() {
        val openAI = catalog.entry(VoiceProviderKinds.fromRawValue("openAI")!!, VoiceDirection.Tts, "tts-1") as VoiceTtsEntry
        assertEquals(1.1, CloudReadAloudRules.effectiveSpeed(openAI, 1.1f), 0.0)
        assertEquals(1.0, CloudReadAloudRules.effectiveSpeed(openAI, null as Float?), 0.0)
        val groq = catalog.entry(
            VoiceProviderKinds.fromRawValue("groq")!!,
            VoiceDirection.Tts,
            "canopylabs/orpheus-v1-english",
        ) as VoiceTtsEntry
        assertNull(groq.speedRange)
        assertEquals(1.0, CloudReadAloudRules.effectiveSpeed(groq, 1.5f), 0.0)
    }

    @Test
    fun failureCases() {
        for (case in cases("failureCases")) {
            val input = case.input()
            val failureObj = input["failure"]!!.jsonObject
            val failure = when (val kind = failureObj.str("kind")) {
                "network" -> DictationFailure.Network
                "timeout" -> DictationFailure.Timeout
                "http" -> DictationFailure.Http(failureObj["status"]!!.jsonPrimitive.int, failureObj.str("retryAfter"))
                else -> throw IllegalStateException("unknown failure.kind $kind")
            }
            val actual = CloudReadAloudRules.failureDecision(failure, input["attempt"]!!.jsonPrimitive.int)
            val expected = case["expected"]!!.jsonObject
            val autoRetry = expected["autoRetry"]!!.jsonPrimitive.boolean
            assertEquals("${case.id()}.autoRetry", autoRetry, actual.autoRetry)
            if (autoRetry) {
                assertEquals("${case.id()}.delaySec", expected["delaySec"]!!.jsonPrimitive.double, actual.delaySec!!, 0.0)
                assertNull("${case.id()}.then", actual.then)
            } else {
                assertEquals("${case.id()}.then", expected.str("then"), actual.then?.rawValue)
                assertNull("${case.id()}.delaySec", actual.delaySec)
            }
        }
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
}
