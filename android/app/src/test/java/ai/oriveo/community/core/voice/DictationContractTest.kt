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
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
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

/** Compares DictationRules / SystemFailure / LiveDictationRules output item by item against the case groups in shared/voice-contracts/dictation.v1.json; entry references are decoded from the voice catalog v2 contract. */
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

    @Test
    fun systemFailureConstantsMatchFixture() {
        val constants = fixture["constants"]!!.jsonObject
        val system = constants["systemFailure"]!!.jsonObject
        assertEquals(
            system["kinds"]!!.jsonArray.map { it.jsonPrimitive.content },
            SystemFailure.REPORTABLE_KINDS.map { it.rawValue },
        )
        val codes = system["codes"]!!.jsonObject
        assertEquals(
            codes["android"]!!.jsonObject.entries.associate { it.key.toInt() to it.value.jsonPrimitive.content },
            SystemFailure.ANDROID_CODES.mapValues { it.value.rawValue },
        )
        assertEquals(
            codes["conditions"]!!.jsonObject.mapValues { it.value.jsonPrimitive.content },
            SystemFailure.CONDITIONS.entries.associate { it.key.rawValue to it.value.rawValue },
        )
        assertEquals(
            system["actions"]!!.jsonObject.mapValues { it.value.jsonArray.map { a -> a.jsonPrimitive.content } },
            SystemFailure.ACTIONS.entries.associate { it.key.rawValue to listOf(it.value.first.rawValue, it.value.second.rawValue) },
        )
        assertEquals(system["busyAutoRetries"]!!.jsonPrimitive.int, SystemFailure.BUSY_AUTO_RETRIES)
        assertEquals(
            constants["live"]!!.jsonObject["maxTextLength"]!!.jsonPrimitive.int,
            LiveDictationRules.MAX_TEXT_LENGTH,
        )
    }

    @Test
    fun systemFailureCases() {
        var checked = 0
        for (case in cases("systemFailureCases")) {
            val input = case.input()
            val failure = input["failure"]!!.jsonObject
            if (failure.str("platform") == "ios") continue
            val parsed = failure.str("condition")?.let { raw ->
                SystemFailureInput.Condition(SystemFailureCondition.entries.single { it.rawValue == raw })
            } ?: SystemFailureInput.Code(failure["code"]!!.jsonPrimitive.int).also {
                assertEquals("${case.id()} platform", "android", failure.str("platform"))
            }
            val actual = input["canRetry"]?.let {
                SystemFailure.classify(parsed, input["attempt"]!!.jsonPrimitive.int, it.jsonPrimitive.boolean)
            } ?: SystemFailure.classify(parsed, input["attempt"]!!.jsonPrimitive.int)
            assertEquals(case.id(), case["expected"], actual.toJson())
            checked++
        }
        assertTrue("android / condition cases must not be empty", checked > 0)
    }

    @Test
    fun livePartialCases() {
        for (case in cases("livePartialCases")) {
            val input = case.input()
            val actual = LiveDictationRules.livePartial(strings(input["finals"]), input.str("partial")!!)
            val json = buildJsonObject {
                put("final", actual.final)
                put("volatile", actual.volatile)
                put("text", actual.text)
            }
            assertEquals(case.id(), case["expected"], json)
        }
    }

    /** Live-caption state from recognition callbacks is compared between two session kinds by SystemSTTEngineTest; here we only register that the group exists and has enough cases. */
    @Test
    fun liveResultCases() {
        assertTrue("liveResultCases must have at least 10 cases", cases("liveResultCases").size >= 10)
    }

    @Test
    fun liveInsertCases() {
        for (case in cases("liveInsertCases")) {
            val input = case.input()
            val text = input.str("text")!!
            val selectionStart = input["selectionStart"]!!.jsonPrimitive.int
            val selectionEnd = input["selectionEnd"]!!.jsonPrimitive.int
            val finals = strings(input["finals"])
            val partial = input.str("partial")!!
            val actual = input["maxLength"]?.let {
                LiveDictationRules.liveInsert(text, selectionStart, selectionEnd, finals, partial, it.jsonPrimitive.int)
            } ?: LiveDictationRules.liveInsert(text, selectionStart, selectionEnd, finals, partial)
            val json = buildJsonObject {
                put("text", actual.text)
                put("cursor", actual.cursor)
                putJsonArray("region") { add(actual.regionStart); add(actual.regionEnd) }
                putJsonArray("volatile") { add(actual.volatileStart); add(actual.volatileEnd) }
            }
            assertEquals(case.id(), case["expected"], json)
        }
    }

    @Test
    fun outcomeCases() {
        fun kind(raw: String?): SystemFailureKind? = raw?.let { r -> SystemFailureKind.entries.single { it.rawValue == r } }
        for (case in cases("outcomeCases")) {
            val input = case.input()
            val live = input["live"]!!.jsonObject
            val session = LiveSessionResult(
                finals = strings(live["finals"]),
                partial = live.str("partial") ?: "",
                ended = LiveEnded.entries.single { it.rawValue == live.str("ended") },
                failureKind = kind(live.str("failureKind")),
                hasRecording = live["hasRecording"]!!.jsonPrimitive.boolean,
                droppedAudio = live["droppedAudio"]?.jsonPrimitive?.boolean ?: false,
            )
            val file = input["file"]?.jsonObject?.let { f ->
                kind(f.str("failureKind"))?.let { LiveFileResult.Failed(it) } ?: LiveFileResult.Text(f.str("text")!!)
            }
            val actual = LiveDictationRules.dictationOutcome(session, file)
            val json = buildJsonObject {
                put("fileAttempted", actual.fileAttempted)
                put("result", actual.result.rawValue)
                actual.source?.let { put("source", it.rawValue) }
                actual.text?.let { put("text", it) }
                actual.failureKind?.let { put("failureKind", it.rawValue) }
            }
            assertEquals(case.id(), case["expected"], json)
        }
    }

    private fun strings(element: JsonElement?): List<String> = element!!.jsonArray.map { it.jsonPrimitive.content }

    private fun SystemFailureDecision.toJson(): JsonObject = buildJsonObject {
        put("kind", kind.rawValue)
        put("autoRetry", autoRetry)
        put("recreateRecognizer", recreateRecognizer)
        put("primaryAction", primaryAction?.rawValue)
        put("secondaryAction", secondaryAction?.rawValue)
        put(
            "telemetry",
            telemetry?.toMap()?.let { map ->
                JsonObject(
                    map.mapValues { (_, v) ->
                        when (v) {
                            is Boolean -> JsonPrimitive(v)
                            is Number -> JsonPrimitive(v)
                            else -> JsonPrimitive(v.toString())
                        }
                    },
                )
            } ?: JsonNull,
        )
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
