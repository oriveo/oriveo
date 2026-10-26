package ai.oriveo.community.core.voice

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.http.HttpStatusCode
import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Compares DictationRules output item by item against the nine groups of cases in shared/voice-contracts/dictation.v1.json; entry references are decoded from the voice catalog v2 contract. */
class DictationContractTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/dictation.v1.json").readText()).jsonObject

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

    private fun envelope(element: JsonElement?): List<Double?> =
        element!!.jsonArray.map { if (it is JsonNull) null else it.jsonPrimitive.double }

    private fun spans(element: JsonElement?): List<DictationSpan> =
        element!!.jsonArray.map { pair ->
            val arr = pair.jsonArray
            DictationSpan(arr[0].jsonPrimitive.double, arr[1].jsonPrimitive.double)
        }

    private fun assertSpans(id: String, expected: List<DictationSpan>, actual: List<DictationSpan>) {
        assertEquals("$id segment count", expected.size, actual.size)
        expected.zip(actual).forEachIndexed { i, (e, a) ->
            assertEquals("$id[$i].start", e.startSec, a.startSec, 1e-9)
            assertEquals("$id[$i].end", e.endSec, a.endSec, 1e-9)
        }
    }

    private fun sttEntry(ref: JsonObject): VoiceSttEntry {
        val kind = VoiceProviderKinds.fromRawValue(ref.str("providerKind"))!!
        assertEquals(VoiceDirection.Stt.rawValue, ref.str("direction"))
        return catalog.entry(kind, VoiceDirection.Stt, ref.str("model")!!) as VoiceSttEntry
    }

    @Test
    fun constantsMatchFixture() {
        val constants = fixture["constants"]!!.jsonObject
        val text = constants["text"]!!.jsonObject
        val whitespace = text["whitespace"]!!.jsonArray.map { it.jsonPrimitive.content.removePrefix("U+").toInt(16) }
        assertEquals(whitespace.toSet(), DictationRules.WHITESPACE)
        val ranges = text["noSpaceScripts"]!!.jsonArray.map {
            val (lo, hi) = it.jsonPrimitive.content.split("..").map { s -> s.removePrefix("U+").toInt(16) }
            lo..hi
        }
        assertEquals(ranges, DictationRules.NO_SPACE_SCRIPTS)
        fun codePoints(key: String) = text[key]!!.jsonArray.map { it.jsonPrimitive.content.codePointAt(0) }.toSet()
        assertEquals(codePoints("noSpaceBefore"), DictationRules.NO_SPACE_BEFORE)
        assertEquals(codePoints("noSpaceAfter"), DictationRules.NO_SPACE_AFTER)

        val envelope = constants["envelope"]!!.jsonObject
        assertEquals(envelope["windowSec"]!!.jsonPrimitive.double, DictationRules.WINDOW_SEC, 0.0)
        assertEquals(envelope["speechThresholdDbfs"]!!.jsonPrimitive.double, DictationRules.SPEECH_THRESHOLD_DBFS, 0.0)
        val precheck = constants["precheck"]!!.jsonObject
        assertEquals(precheck["minDurationSec"]!!.jsonPrimitive.double, DictationRules.MIN_DURATION_SEC, 0.0)
        assertEquals(precheck["minVoicedWindows"]!!.jsonPrimitive.int, DictationRules.MIN_VOICED_WINDOWS)
        val segmentation = constants["segmentation"]!!.jsonObject
        assertEquals(segmentation["minSilenceRunWindows"]!!.jsonPrimitive.int, DictationRules.MIN_SILENCE_RUN_WINDOWS)
        assertEquals(segmentation["byteSafetyFactor"]!!.jsonPrimitive.double, DictationRules.BYTE_SAFETY_FACTOR, 0.0)
        assertEquals(segmentation["secondsDecimals"]!!.jsonPrimitive.int, DictationRules.SECONDS_DECIMALS)
        assertEquals(segmentation["compareTolerance"]!!.jsonPrimitive.double, DictationRules.COMPARE_TOLERANCE, 0.0)
        assertEquals(constants["discardUndoAboveSec"]!!.jsonPrimitive.double, DictationRules.DISCARD_UNDO_ABOVE_SEC, 0.0)
        assertEquals(constants["pendingRetentionSec"]!!.jsonPrimitive.double, DictationRules.PENDING_RETENTION_SEC, 0.0)
        val retry = constants["retry"]!!.jsonObject
        assertEquals(retry["maxAutoRetries"]!!.jsonPrimitive.int, DictationRules.MAX_AUTO_RETRIES)
        assertEquals(retry["defaultDelaySec"]!!.jsonPrimitive.double, DictationRules.DEFAULT_RETRY_DELAY_SEC, 0.0)
        assertEquals(retry["maxRetryAfterSec"]!!.jsonPrimitive.double, DictationRules.MAX_RETRY_AFTER_SEC, 0.0)
        assertEquals(
            retry["transientHttpStatuses"]!!.jsonArray.map { it.jsonPrimitive.int }.toSet(),
            DictationRules.TRANSIENT_HTTP_STATUSES,
        )
        assertEquals(retry["transientHttpFrom"]!!.jsonPrimitive.int, DictationRules.TRANSIENT_HTTP_FROM)
        assertEquals(
            retry["authHttpStatuses"]!!.jsonArray.map { it.jsonPrimitive.int }.toSet(),
            DictationRules.AUTH_HTTP_STATUSES,
        )
        val multipart = constants["multipart"]!!.jsonObject
        assertEquals(multipart.str("fileName"), DictationRules.FILE_NAME)
        assertEquals(multipart.str("contentType"), DictationRules.FILE_CONTENT_TYPE)
        assertEquals(
            multipart["legacyLanguageCodes"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content },
            DictationRules.LEGACY_LANGUAGE_CODES,
        )
    }

    @Test
    fun precheckCases() {
        for (case in cases("precheckCases")) {
            val input = case.input()
            val actual = DictationRules.precheck(input["durationSec"]!!.jsonPrimitive.double, envelope(input["envelope"]))
            assertEquals(case.id(), case.str("expected"), actual.rawValue)
        }
    }

    @Test
    fun silenceRunCases() {
        for (case in cases("silenceRunCases")) {
            val actual = DictationRules.silenceRuns(envelope(case.input()["envelope"]))
            assertSpans(case.id(), spans(case["expected"]), actual)
        }
    }

    @Test
    fun segmentPlanCases() {
        for (case in cases("segmentPlanCases")) {
            val input = case.input()
            val recording = input["recording"]!!.jsonObject
            val durationSec = recording["durationSec"]!!.jsonPrimitive.double
            val uploadBytes = recording["uploadBytes"]!!.jsonPrimitive.long
            val silences = spans(recording["silences"])
            val actual = input["entry"]?.let { ref ->
                DictationRules.segmentPlan(sttEntry(ref.jsonObject), durationSec, uploadBytes, silences)
            } ?: input["limits"]!!.jsonObject.let { limits ->
                DictationRules.segmentPlan(
                    maxBytes = limits["maxBytes"]!!.jsonPrimitive.long,
                    maxDurationSec = limits["maxDurationSec"]!!.jsonPrimitive.double,
                    durationSec = durationSec,
                    uploadBytes = uploadBytes,
                    silences = silences,
                )
            }
            assertSpans(case.id(), spans(case["expected"]), actual)
        }
    }

    @Test
    fun joinCases() {
        for (case in cases("joinCases")) {
            val texts = case.input()["texts"]!!.jsonArray.map { it.jsonPrimitive.content }
            assertEquals(case.id(), case.str("expected"), DictationRules.join(texts))
        }
    }

    @Test
    fun insertCases() {
        for (case in cases("insertCases")) {
            val input = case.input()
            val actual = DictationRules.insert(
                text = input.str("text")!!,
                selectionStart = input["selectionStart"]!!.jsonPrimitive.int,
                selectionEnd = input["selectionEnd"]!!.jsonPrimitive.int,
                transcript = input.str("transcript")!!,
            )
            val expected = case["expected"]!!.jsonObject
            assertEquals("${case.id()}.text", expected.str("text"), actual.text)
            assertEquals("${case.id()}.cursor", expected["cursor"]!!.jsonPrimitive.int, actual.cursor)
        }
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
            val actual = DictationRules.failureDecision(failure, input["attempt"]!!.jsonPrimitive.int)
            val expected = case["expected"]!!.jsonObject
            val autoRetry = expected["autoRetry"]!!.jsonPrimitive.boolean
            assertEquals("${case.id()}.autoRetry", autoRetry, actual.autoRetry)
            if (autoRetry) {
                assertEquals("${case.id()}.delaySec", expected["delaySec"]!!.jsonPrimitive.double, actual.delaySec!!, 0.0)
                assertNull("${case.id()}.primaryAction", actual.primaryAction)
            } else {
                assertEquals("${case.id()}.primaryAction", expected.str("primaryAction"), actual.primaryAction?.rawValue)
                assertNull("${case.id()}.delaySec", actual.delaySec)
            }
        }
    }

    @Test
    fun requestCases() {
        for (case in cases("requestCases")) {
            val input = case.input()
            val language = input.str("language")
            val entry = input["entry"]?.let { sttEntry(it.jsonObject) } ?: input["inlineEntry"]!!.jsonObject.let { inline ->
                val transport = VoiceTransport.fromRawValue(inline.str("transport")!!, VoiceDirection.Stt)
                assertTrue("${case.id()} transport", transport != null)
                VoiceSttEntry(
                    model = inline.str("model")!!,
                    transport = transport!!,
                    path = inline.str("path")!!,
                    maxBytes = 0,
                    maxDurationSec = 0,
                    languageField = inline.str("languageField"),
                )
            }
            val expected = case["expected"]!!.jsonObject
            assertEquals("${case.id()}.method", expected.str("method"), DictationRules.REQUEST_METHOD)
            assertEquals("${case.id()}.path", expected.str("path"), entry.path)
            expected["json"]?.let { json ->
                assertTrue("${case.id()} JSON type", DictationRules.isJsonRequest(entry.transport))
                assertEquals(
                    "${case.id()}.headers",
                    expected["headers"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content },
                    wireHeaders(entry, input.str("apiKey")!!, language),
                )
                assertEquals(
                    "${case.id()}.json",
                    json,
                    DictationRules.requestJson(entry, language, input.str("audioBase64")!!),
                )
                continue
            }
            assertTrue("${case.id()} multipart type", !DictationRules.isJsonRequest(entry.transport))
            assertEquals("${case.id()}.auth", "Authorization" to "Bearer k", DictationRules.authorizationHeader(entry.transport, "k"))
            val parts = DictationRules.requestParts(entry, language)
            val expectedParts = expected["parts"]!!.jsonArray.map { el ->
                val obj = el.jsonObject
                if (obj.containsKey("filename")) {
                    DictationRequestPart.File(obj.str("name")!!, obj.str("filename")!!, obj.str("contentType")!!)
                } else {
                    DictationRequestPart.Field(obj.str("name")!!, obj.str("value")!!)
                }
            }
            assertEquals("${case.id()}.parts", expectedParts, parts)
            assertTrue("${case.id()} does not send response_format", parts.none { it.name == "response_format" })
        }
    }

    @Test
    fun responseCases() {
        for (case in cases("responseCases")) {
            val transport = case.input().str("transport")?.let { raw ->
                VoiceTransport.fromRawValue(raw, VoiceDirection.Stt).also { assertTrue("${case.id()} transport", it != null) }
            }
            val actual = DictationRules.transcript(transport, case.input()["body"])
            assertEquals(case.id(), case.str("expected"), actual)
        }
    }

    @Test
    fun thresholdCases() {
        for (case in cases("thresholdCases")) {
            val input = case.input()
            val value = input["value"]!!.jsonPrimitive.double
            val actual = when (val kind = input.str("kind")) {
                "discard_undo" -> DictationRules.shouldOfferDiscardUndo(value)
                "retention_age" -> DictationRules.isPendingExpired(value).also { rules ->
                    // Production path: RecordingStore.isExpired judges the same as the contract rule.
                    val meta = RecordingSlotMeta("k", createdAt = 0L, RecordingSlotStatus.Ready, 0.0, emptyList(), "cloud")
                    val store = RecordingStore(tmp.newFolder())
                    assertEquals("${case.id()}.store", rules, store.isExpired(meta, now = Math.round(value * 1000)))
                }
                else -> throw IllegalStateException("unknown threshold.kind $kind")
            }
            assertEquals(case.id(), case["expected"]!!.jsonPrimitive.boolean, actual)
        }
    }

    @Test
    fun requestUrlUsesConnectionOriginPlusCatalogPath() {
        val groq = catalog.entry(VoiceProviderKinds.fromRawValue("groq")!!, VoiceDirection.Stt, "whisper-large-v3-turbo") as VoiceSttEntry
        assertEquals(
            "https://api.groq.com/openai/v1/audio/transcriptions",
            DictationRules.requestUrl("https://api.groq.com/openai/v1", groq),
        )
        assertEquals(
            "http://localhost:8080/v1/audio/transcriptions",
            DictationRules.requestUrl("http://localhost:8080/v1", "/v1/audio/transcriptions"),
        )
        assertNull(DictationRules.requestUrl("", "/v1/audio/transcriptions"))
        assertNull(DictationRules.requestUrl("api.groq.com/openai/v1", "/v1/audio/transcriptions"))
        assertNull(DictationRules.requestUrl("localhost:8080/v1", "/v1/audio/transcriptions"))
        assertEquals("Authorization" to "Bearer sk-test", DictationRules.authorizationHeader("sk-test"))
    }

    @Test
    fun retryAfterTrimsBeforeParsing() {
        assertEquals(3.0, DictationRules.parseRetryAfter(" 3 ")!!, 0.0)
        assertEquals(2.5, DictationRules.parseRetryAfter("2.5")!!, 0.0)
        assertNull(DictationRules.parseRetryAfter("-1"))
        assertNull(DictationRules.parseRetryAfter("1e1"))
        assertNull(DictationRules.parseRetryAfter("٣"))
    }

    /** Headers come from the real request CloudSTTEngine sends through MockEngine: request headers verbatim plus the body's Content-Type. */
    private fun wireHeaders(entry: VoiceSttEntry, apiKey: String, language: String?): Map<String, String> {
        val captured = mutableListOf<HttpRequestData>()
        val mock = MockEngine { request ->
            captured += request
            respond(content = "{}", status = HttpStatusCode.BadRequest)
        }
        val aac = File("src/test/resources/voice/sine-silence-16k.aac").copyTo(tmp.newFolder().resolve("rec.aac"))
        val engine = CloudSTTEngine(HttpClient(mock), entry, "https://api.example.com/", apiKey, tmp.newFolder(), sleeper = {})
        runBlocking { engine.transcribe(STTSegment(aac), language) }
        val request = captured.first()
        // Ktor's default transformation adds `*/*` when Accept is not set; only that one default is filtered out, so an Accept explicitly set by production code is still compared.
        return request.headers.entries()
            .filterNot { it.key.equals("Accept", ignoreCase = true) && it.value == listOf("*/*") }
            .associate { it.key to it.value.joinToString(",") } +
            listOfNotNull(request.body.contentType?.let { "Content-Type" to it.toString() })
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("not found: $relative")
    }
}
