package ai.oriveo.community.feature.chat.modelcontrols

import ai.oriveo.community.R
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterRange
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.GenerationParameterDiagnosticEntry
import ai.oriveo.community.core.provider.GenerationParameterDiagnosticStore
import ai.oriveo.community.core.provider.LocalEngineGenerationProfiles
import ai.oriveo.community.feature.chat.modelcontrols.AdvancedSubgroups.SingleValue
import ai.oriveo.community.feature.chat.modelcontrols.AdvancedSubgroups.Summary
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.DisplayValue
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.FallbackKind
import ai.oriveo.community.feature.providers.detail.generationParameterTitleRes
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Subgroups of "more" in the advanced settings: membership, notes, summary, takeover note and displayed value. */
class AdvancedSubgroupsTest {
    private var payload: String? = null
    private val store = GenerationParameterSettingsStore(readPayload = { payload }, writePayload = { payload = it })
    private val llama = LocalEngineGenerationProfiles.profile("llamacpp", RelayTransport.OpenAIChatCompletions)!!

    private fun set(conversation: String, vararg pairs: Pair<String, JsonElement>) {
        store.setSessionOverrides(
            GenerationParameterOverrides(pairs.associate { (id, v) -> id to GenerationParameterOverride(GenerationOverrideState.Value, v) }),
            "p1", "m1", conversation,
        )
    }

    private fun page(profile: GenerationProfileRef, conversation: String) =
        GenerationParameterRowModel.page(profile, store.resolveWithSources(null, "p1", "m1", conversation))

    private fun summaries(profile: GenerationProfileRef, conversation: String): Map<String, Summary> {
        val page = page(profile, conversation)
        val layout = AdvancedSettingsLayout.layout(page, profile)
        val raw = store.resolveWithSources(null, "p1", "m1", conversation).mapValues { it.value.override.value }
        val schemas = profile.parameters.associate { it.id to it.valueSchema }.mapNotNull { (k, v) -> k?.let { it to v } }.toMap()
        val rows = page.rows.associateBy { it.id }
        return layout.more.associate { it.key to AdvancedSubgroups.summary(it, rows, raw, schemas) }
    }

    @Test
    fun `llama cpp profile splits more into the design subgroups by parameter id and group`() {
        val layout = AdvancedSettingsLayout.layout(page(llama, "c0"), llama)
        val groups = layout.more.associate { it.key to it.rowIds }

        assertEquals(listOf("max_output_tokens", "temperature", "top_k", "top_p", "min_p"), layout.common)
        assertEquals(listOf("mirostat", "mirostat_tau", "mirostat_eta"), groups["mirostat"])
        assertEquals(listOf("dynatemp_range", "dynatemp_exponent"), groups["dynamic_temperature"])
        assertTrue(groups.getValue("repetition").containsAll(listOf("repeat_penalty", "dry_multiplier")))
        assertTrue(groups.getValue("more_sampling").containsAll(listOf("typical_p", "xtc_probability", "samplers")))
        assertFalse(groups.getValue("more_sampling").any { it.startsWith("mirostat") || it.startsWith("dynatemp_") })
        assertFalse("a subgroup without members does not appear", "sampling" in groups)
        assertEquals(R.string.advanced_repetition, AdvancedSettingsLayout.groupTitleRes("repetition"))
        assertEquals(R.string.advanced_more_sampling, AdvancedSettingsLayout.groupTitleRes("more_sampling"))
        assertEquals(R.string.advanced_dynamic_temperature, AdvancedSettingsLayout.groupTitleRes("dynamic_temperature"))
    }

    @Test
    fun `a subgroup with no member in the profile does not appear`() {
        val ollama = LocalEngineGenerationProfiles.profile("ollama")!!
        val keys = AdvancedSettingsLayout.layout(page(ollama, "c0"), ollama).more.map { it.key }
        assertFalse("mirostat" in keys)
        assertFalse("dynamic_temperature" in keys)
        assertEquals("mirostat", AdvancedSubgroups.subgroupOf("mirostat_eta", "sampling"))
        assertEquals("more_sampling", AdvancedSubgroups.subgroupOf("xtc_threshold", "sampling"))
        assertEquals("repetition", AdvancedSubgroups.subgroupOf("dry_base", "repetition"))
        assertEquals("budget", AdvancedSubgroups.subgroupOf("stop", "budget"))
        assertEquals("engine_runtime", AdvancedSubgroups.subgroupOf("n_ctx", null))
    }

    @Test
    fun `notes sit on the mirostat and dynamic temperature subgroups and on the dry and xtc lead rows`() {
        assertEquals(R.string.advanced_mirostat_note, AdvancedSubgroups.groupNoteRes("mirostat"))
        assertEquals(R.string.advanced_dynamic_temperature_note, AdvancedSubgroups.groupNoteRes("dynamic_temperature"))
        assertNull(AdvancedSubgroups.groupNoteRes("repetition"))
        assertEquals(R.string.advanced_dry_note, AdvancedSubgroups.rowNoteRes("dry_multiplier"))
        assertEquals(R.string.advanced_xtc_note, AdvancedSubgroups.rowNoteRes("xtc_probability"))
        assertNull(AdvancedSubgroups.rowNoteRes("dry_base"))
        assertNull(AdvancedSubgroups.rowNoteRes("temperature"))
    }

    @Test
    fun `subgroup summary counts list entries, says on for switches and set for schemas`() {
        set("c1", "stop" to JsonArray(listOf(JsonPrimitive("###"), JsonPrimitive("\n\n"))), "repeat_penalty" to JsonPrimitive(1.15))
        val first = summaries(llama, "c1")
        assertEquals(Summary.Single("stop", SingleValue.Entries(2)), first["budget"])
        assertEquals(Summary.Single("repeat_penalty", SingleValue.Text("1.15")), first["repetition"])
        assertEquals(Summary.NotAdjusted, first["mirostat"])

        set("c2", "post_sampling_probs" to JsonPrimitive(true))
        assertEquals(Summary.Single("post_sampling_probs", SingleValue.On), summaries(llama, "c2")["output_contract"])

        set("c3", "json_schema" to buildJsonObject { put("type", JsonPrimitive("object")) })
        assertEquals(Summary.Single("json_schema", SingleValue.Set), summaries(llama, "c3")["output_contract"])

        set("c4", "mirostat" to JsonPrimitive(2), "mirostat_tau" to JsonPrimitive(4.0))
        assertEquals(Summary.Count(2), summaries(llama, "c4")["mirostat"])
    }

    @Test
    fun `takeover reason is aggregated once per group`() {
        val profile = GenerationProfileRef(
            template = "openai_chat_completions",
            parameters = listOf(
                GenerationParameterRef(id = "temperature", support = "supported", valueSchema = "number", group = "sampling"),
                GenerationParameterRef(id = "top_k", support = "supported", valueSchema = "integer", group = "sampling"),
                GenerationParameterRef(id = "top_p", support = "supported", valueSchema = "number", group = "sampling"),
                GenerationParameterRef(id = "mirostat", support = "supported", valueSchema = "integer", group = "sampling", conflictsWith = listOf("top_k", "top_p")),
            ),
            wire = listOf("temperature", "top_k", "top_p", "mirostat").associateWith { it },
        )
        assertNull(AdvancedSubgroups.takenOverNote(page(profile, "c0").rows))
        set("c1", "mirostat" to JsonPrimitive(2))
        val note = AdvancedSubgroups.takenOverNote(page(profile, "c1").rows)
        assertEquals(AdvancedSubgroups.TakenOverNote(listOf("mirostat"), 2), note)
    }

    @Test
    fun `seed and output format fall back to their specific wording only when nothing is set`() {
        val rows = page(llama, "c0").rows.associateBy { it.id }
        assertEquals(DisplayValue.Fallback(FallbackKind.RandomEachTime), rows.getValue("seed").display)
        assertEquals(DisplayValue.Fallback(FallbackKind.PlainText), rows.getValue("json_schema").display)
        assertEquals(DisplayValue.Fallback(FallbackKind.ModelDecides), rows.getValue("grammar").display)
        set("c1", "seed" to JsonPrimitive(42))
        assertEquals(DisplayValue.Value("42"), page(llama, "c1").rows.first { it.id == "seed" }.display)
    }

    @Test
    fun `allowed range text covers closed, open and one sided ranges`() {
        assertEquals("0 – 1", GenerationParameterRowModel.rangeText(llama.parameters.first { it.id == "top_p" }.range!!))
        assertEquals("≥ 1", GenerationParameterRowModel.rangeText(GenerationParameterRange(min = 1.0)))
        assertEquals("≤ 2", GenerationParameterRowModel.rangeText(GenerationParameterRange(max = 2.0)))
        assertEquals("> 0 – < 1", GenerationParameterRowModel.rangeText(GenerationParameterRange(minExclusive = 0.0, maxExclusive = 1.0)))
        assertNull(GenerationParameterRowModel.rangeText(GenerationParameterRange()))
    }

    @Test
    fun `titles come from the shared title table except the new page stop sequences row`() {
        assertEquals(R.string.advanced_stop_sequences, AdvancedSettingsLayout.rowTitleRes("stop"))
        assertEquals(R.string.temperature, AdvancedSettingsLayout.rowTitleRes("temperature"))
        assertEquals(R.string.advanced_target_entropy, generationParameterTitleRes("mirostat_tau"))
        assertEquals(R.string.advanced_learning_rate, generationParameterTitleRes("mirostat_eta"))
    }

    @Test
    fun `clearing diagnostics removes exactly what the model scoped list shows`() {
        fun entry(id: String, model: String?) = GenerationParameterDiagnosticEntry(id, 0, "top_k", "recovered", "t", "e", "p", model)
        val all = listOf(entry("a", "m1"), entry("b", "m2"), entry("c", null))
        assertEquals(listOf("b"), GenerationParameterDiagnosticStore.remainingAfterClear(all, "m1").map { it.id })
        assertEquals(emptyList<String>(), GenerationParameterDiagnosticStore.remainingAfterClear(all, null).map { it.id })
    }
}
