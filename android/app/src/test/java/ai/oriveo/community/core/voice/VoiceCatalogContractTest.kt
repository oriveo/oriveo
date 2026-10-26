package ai.oriveo.community.core.voice

import ai.oriveo.community.core.model.ProviderKind
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * shared/voice-contracts/engine-resolution.v2.json decodeCases, case by case: the typed result of the production decoder
 * is compared with expected (strict parsing, not the lenient production path). A provider not listed is treated as empty in both directions.
 */
class VoiceCatalogContractTest {

    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/engine-resolution.v2.json").readText()).jsonObject

    private val baseCatalog: JsonElement =
        Json.parseToJsonElement(workspaceFile("shared/model-contracts/voice_catalog_contract.v2.json").readText())
            .jsonObject["data"]!!

    private fun catalogInput(element: JsonElement): JsonElement =
        if (element is JsonPrimitive && element.content == "base") baseCatalog else element

    private fun JsonObject.str(key: String): String = this[key]!!.jsonPrimitive.content

    private fun expectedVoices(e: JsonObject): List<VoiceOption> = e["voices"]!!.jsonArray.map { v ->
        VoiceOption(v.jsonObject.str("id"), v.jsonObject["isDefault"]!!.jsonPrimitive.boolean)
    }

    private fun expectedRealtime(obj: JsonObject): List<VoiceRealtimeEntry> = obj["realtime"]!!.jsonArray.map { el ->
        val e = el.jsonObject
        VoiceRealtimeEntry(
            model = e.str("model"),
            transport = VoiceTransport.fromRawValue(e.str("transport"), VoiceDirection.Realtime)!!,
            path = e.str("path"),
            contextWindow = e["contextWindow"]!!.jsonPrimitive.long,
            voices = expectedVoices(e),
            maxSessionSec = e["maxSessionSec"]?.jsonPrimitive?.long,
            inputTranscriptionModel = e["inputTranscriptionModel"]?.jsonPrimitive?.content,
            isDefault = e["isDefault"]!!.jsonPrimitive.boolean,
        )
    }

    /** The expected of decodeCases only lists stt / tts; realtime is filled in as empty (rules.realtime: old groups ignore realtime). */
    private fun expectedProvider(obj: JsonObject): VoiceProviderCatalog = VoiceProviderCatalog(
        stt = obj["stt"]!!.jsonArray.map { el ->
            val e = el.jsonObject
            VoiceSttEntry(
                model = e.str("model"),
                transport = VoiceTransport.fromRawValue(e.str("transport"), VoiceDirection.Stt)!!,
                path = e.str("path"),
                maxBytes = e["maxBytes"]!!.jsonPrimitive.long,
                maxDurationSec = e["maxDurationSec"]!!.jsonPrimitive.int,
                languageField = e["languageField"]?.jsonPrimitive?.content,
                isDefault = e["isDefault"]!!.jsonPrimitive.boolean,
            )
        },
        tts = obj["tts"]!!.jsonArray.map { el ->
            val e = el.jsonObject
            VoiceTtsEntry(
                model = e.str("model"),
                transport = VoiceTransport.fromRawValue(e.str("transport"), VoiceDirection.Tts)!!,
                path = e.str("path"),
                voices = expectedVoices(e),
                outputFormat = e.str("outputFormat"),
                maxChars = e["maxChars"]!!.jsonPrimitive.int,
                speedRange = e["speedRange"]?.jsonObject?.let {
                    VoiceSpeedRange(it["min"]!!.jsonPrimitive.double, it["max"]!!.jsonPrimitive.double)
                },
                isDefault = e["isDefault"]!!.jsonPrimitive.boolean,
            )
        },
        realtime = emptyList(),
    )

    @Test
    fun `client provider kinds equal fixture constants`() {
        // The enum equals the fixture item by item: prevents a client from recognizing only "the providers that have voice right now" and diverging when the server lists a new one
        val want = fixture["constants"]!!.jsonObject["knownProviderKinds"]!!.jsonArray.map { it.jsonPrimitive.content }
        assertEquals(want.sorted(), ProviderKind.entries.map { it.rawValue }.sorted())
    }

    @Test
    fun `decode cases match fixture`() {
        val cases = fixture["decodeCases"]!!.jsonArray.map { it.jsonObject }
        assertTrue("decodeCases must not be empty", cases.isNotEmpty())
        for (case in cases) {
            val id = case.str("id")
            val decoded = VoiceCatalogDecoder.decode(catalogInput(case["input"]!!.jsonObject["catalog"]!!))
            val expected = case["expected"]!!.jsonObject["providers"]!!.jsonObject
            for (raw in expected.keys) {
                assertTrue("$id: unknown providerKind $raw", VoiceProviderKinds.fromRawValue(raw) != null)
            }
            assertTrue("$id: decoded an unknown provider ${decoded.providers.keys}", ProviderKind.entries.containsAll(decoded.providers.keys))
            for (kind in ProviderKind.entries) {
                val raw = kind.rawValue
                val want = expected[raw]?.let { expectedProvider(it.jsonObject) } ?: VoiceProviderCatalog.EMPTY
                assertEquals("$id/$raw", want, decoded.provider(kind).copy(realtime = emptyList()))
            }
        }
    }

    @Test
    fun realtimeDecodeCasesMatchFixture() {
        val cases = fixture["realtimeDecodeCases"]!!.jsonArray.map { it.jsonObject }
        assertTrue("realtimeDecodeCases must not be empty", cases.isNotEmpty())
        for (case in cases) {
            val id = case.str("id")
            val decoded = VoiceCatalogDecoder.decode(catalogInput(case["input"]!!.jsonObject["catalog"]!!))
            val expected = case["expected"]!!.jsonObject["providers"]!!.jsonObject
            for (raw in expected.keys) {
                assertTrue("$id: unknown providerKind $raw", VoiceProviderKinds.fromRawValue(raw) != null)
            }
            for (kind in ProviderKind.entries) {
                val raw = kind.rawValue
                val want = expected[raw]?.let { expectedRealtime(it.jsonObject) } ?: emptyList()
                assertEquals("$id/$raw", want, decoded.provider(kind).realtime)
            }
        }
    }

    @Test
    fun `realtime transports equal fixture constants`() {
        val want = fixture["constants"]!!.jsonObject["realtimeTransports"]!!.jsonArray.map { it.jsonPrimitive.content }
        assertEquals(want, VoiceTransport.entries.filter { it.direction == VoiceDirection.Realtime }.map { it.rawValue })
    }

    private fun workspaceFile(relative: String): File {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        throw IllegalStateException("Cannot find $relative")
    }
}
