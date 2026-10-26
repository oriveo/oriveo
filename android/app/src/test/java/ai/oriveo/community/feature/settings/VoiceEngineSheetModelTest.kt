package ai.oriveo.community.feature.settings

import ai.oriveo.community.R
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.model.ProviderAuthMode
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceCatalogDecoder
import ai.oriveo.community.core.voice.VoiceCatalogState
import ai.oriveo.community.core.voice.VoiceConnection
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceEngineOption
import ai.oriveo.community.core.voice.VoiceEngineSelection
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Rows and footer of the engine sheet. pendingCases are read one by one from shared/voice-contracts/engine-resolution.v2.json;
 * catalog "base" = the data of shared/model-contracts/voice_catalog_contract.v2.json, decoded by the production decoder.
 */
class VoiceEngineSheetModelTest {

    private val fixture: JsonObject =
        Json.parseToJsonElement(workspaceFile("shared/voice-contracts/engine-resolution.v2.json").readText()).jsonObject

    private val baseCatalogJson: JsonElement =
        Json.parseToJsonElement(workspaceFile("shared/model-contracts/voice_catalog_contract.v2.json").readText())
            .jsonObject["data"]!!

    private val baseCatalog: VoiceCatalog = VoiceCatalogDecoder.decode(baseCatalogJson)

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun catalog(input: JsonObject): VoiceCatalog {
        val element = input["catalog"]!!
        val data = if (element is JsonPrimitive && element.content == "base") baseCatalogJson else element
        return VoiceCatalogDecoder.decode(data)
    }

    // A connection can be any provider (not only the four voice knows), resolved by the ProviderKind serialized name.
    private fun kind(raw: String?): ProviderKind = Json.decodeFromString(ProviderKind.serializer(), "\"$raw\"")

    private fun connections(input: JsonObject): List<VoiceConnection> = input["connections"]!!.jsonArray.map {
        val c = it.jsonObject
        VoiceConnection(
            id = c.str("id")!!,
            providerKind = kind(c.str("providerKind")),
            authMode = ProviderAuthMode.entries.first { mode -> mode.rawValue == c.str("authMode") },
            hasKey = c["hasKey"]!!.jsonPrimitive.boolean,
        )
    }

    private fun usable(id: String, kind: ProviderKind) = VoiceConnection(id, kind, ProviderAuthMode.ApiKey, hasKey = true)

    private val available = VoiceCatalogState.Available(baseCatalog)

    @Test
    fun pendingCases() {
        val all = fixture["pendingCases"]!!.jsonArray.map { it.jsonObject }
        assertTrue("pendingCases must not be empty", all.isNotEmpty())
        for (case in all) {
            val input = case["input"]!!.jsonObject
            val direction = VoiceDirection.fromRawValue(input.str("direction"))!!
            val expected = case["expected"]!!.jsonArray.map { kind(it.jsonPrimitive.content) }
            val model = VoiceEngineSheetModels.build(
                VoiceCatalogState.Available(catalog(input)),
                direction,
                VoiceEngineSelection.System,
                connections(input),
                emptyMap(),
            )
            val footer = if (expected.isEmpty()) {
                VoiceEngineSheetFooter.None
            } else {
                VoiceEngineSheetFooter.PendingProviders(expected)
            }
            assertEquals(case.str("id"), footer, model.footer)
        }
    }

    @Test
    fun `system first then options`() {
        val model = VoiceEngineSheetModels.build(
            available, VoiceDirection.Stt, VoiceEngineSelection.System,
            listOf(usable("o1", ProviderKind.OpenAI), usable("g1", ProviderKind.Groq)),
            mapOf("o1" to "Work", "g1" to "Groq"),
        )
        assertEquals(
            listOf(
                VoiceEngineOption.System,
                VoiceEngineOption.Cloud(ProviderKind.OpenAI, "o1", "gpt-transcribe", isDefault = false),
                VoiceEngineOption.Cloud(ProviderKind.OpenAI, "o1", "whisper-1", isDefault = false),
                VoiceEngineOption.Cloud(ProviderKind.Groq, "g1", "whisper-large-v3-turbo", isDefault = false),
            ).map { it::class to (it as? VoiceEngineOption.Cloud)?.let { c -> c.connectionId to c.model } },
            model.rows.map { it.option::class to (it.option as? VoiceEngineOption.Cloud)?.let { c -> c.connectionId to c.model } },
        )
        assertTrue(model.rows.all { it.connectionName == null })
    }

    @Test
    fun `realtime follow model first then cloud rows`() {
        val model = VoiceEngineSheetModels.build(
            available, VoiceDirection.Realtime, VoiceEngineSelection.System,
            listOf(usable("o1", ProviderKind.OpenAI), usable("m1", ProviderKind.Gemini)),
            emptyMap(),
        )
        assertEquals(VoiceEngineOption.System, model.rows.first().option)
        assertTrue(model.rows.first().isChecked)
        assertEquals(UiText.Resource(R.string.voice_realtime_follow_model), model.systemTitle)
        assertEquals(UiText.Resource(R.string.voice_realtime_follow_model_subtitle), model.systemSubtitle)
        assertEquals(
            setOf(
                "o1" to "gpt-realtime-2.1",
                "o1" to "gpt-realtime-2.1-mini",
                "m1" to "gemini-3.8-live",
            ),
            model.rows.drop(1).map { (it.option as VoiceEngineOption.Cloud).let { c -> c.connectionId to c.model } }.toSet(),
        )
        assertEquals(4, model.rows.size)
        assertTrue(model.rows.all { it.connectionName == null })

        val stt = VoiceEngineSheetModels.build(available, VoiceDirection.Stt, VoiceEngineSelection.System, emptyList(), emptyMap())
        assertEquals(UiText.Resource(R.string.voice_engine_system), stt.systemTitle)
        assertEquals(UiText.Resource(R.string.voice_engine_system_subtitle), stt.systemSubtitle)
    }

    @Test
    fun `same kind multiple connections adds connection name`() {
        val model = VoiceEngineSheetModels.build(
            available, VoiceDirection.Stt, VoiceEngineSelection.System,
            listOf(usable("o1", ProviderKind.OpenAI), usable("o2", ProviderKind.OpenAI), usable("g1", ProviderKind.Groq)),
            mapOf("o1" to "Work", "o2" to "Home", "g1" to "Groq"),
        )
        val names = model.rows.associate { row ->
            ((row.option as? VoiceEngineOption.Cloud)?.let { it.connectionId to it.model } ?: ("system" to "")) to row.connectionName
        }
        assertNull(names["system" to ""])
        assertEquals("Work", names["o1" to "whisper-1"])
        assertEquals("Home", names["o2" to "whisper-1"])
        assertNull(names["g1" to "whisper-large-v3-turbo"])
    }

    @Test
    fun `checked follows selection`() {
        val conns = listOf(usable("o1", ProviderKind.OpenAI), usable("o2", ProviderKind.OpenAI))
        val system = VoiceEngineSheetModels.build(available, VoiceDirection.Stt, VoiceEngineSelection.System, conns, emptyMap())
        assertEquals(listOf(VoiceEngineOption.System), system.rows.filter { it.isChecked }.map { it.option })

        val cloud = VoiceEngineSheetModels.build(
            available, VoiceDirection.Stt,
            VoiceEngineSelection.Cloud(ProviderKind.OpenAI, "o2", "whisper-1"),
            conns, emptyMap(),
        )
        val checked = cloud.rows.filter { it.isChecked }.map { it.option as VoiceEngineOption.Cloud }
        assertEquals(listOf("o2" to "whisper-1"), checked.map { it.connectionId to it.model })
    }

    @Test
    fun `404 shows empty footer`() {
        val model = VoiceEngineSheetModels.build(
            VoiceCatalogState.Unavailable, VoiceDirection.Tts, VoiceEngineSelection.System,
            listOf(usable("o1", ProviderKind.OpenAI)), emptyMap(),
        )
        assertEquals(VoiceEngineSheetFooter.CatalogEmpty, model.footer)
        assertEquals(listOf(VoiceEngineOption.System), model.rows.map { it.option })
    }

    @Test
    fun `load failed without cache shows failed footer`() {
        val model = VoiceEngineSheetModels.build(
            VoiceCatalogState.LoadFailed, VoiceDirection.Stt, VoiceEngineSelection.System,
            listOf(usable("o1", ProviderKind.OpenAI)), emptyMap(),
        )
        assertEquals(VoiceEngineSheetFooter.LoadFailed, model.footer)
        assertEquals(listOf(VoiceEngineOption.System), model.rows.map { it.option })
    }

    @Test
    fun `no conclusion lists system only`() {
        val model = VoiceEngineSheetModels.build(
            null, VoiceDirection.Stt, VoiceEngineSelection.System,
            listOf(usable("o1", ProviderKind.OpenAI), usable("q1", ProviderKind.Qwen)), emptyMap(),
        )
        assertEquals(VoiceEngineSheetFooter.None, model.footer)
        assertEquals(listOf(VoiceEngineOption.System), model.rows.map { it.option })
        assertTrue(model.rows.single().isChecked)
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
