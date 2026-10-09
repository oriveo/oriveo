package ai.oriveo.community.feature.chat.modelcontrols

import ai.oriveo.community.R
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.GenerationParameterSupportPresentation.PresentationClass
import ai.oriveo.community.core.provider.LocalEngineGenerationProfiles
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.Verification
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AdvancedSettingsModelTest {
    private var payload: String? = null
    private val store = GenerationParameterSettingsStore(readPayload = { payload }, writePayload = { payload = it })

    private fun values(vararg pairs: Pair<String, Double>) = GenerationParameterOverrides(
        pairs.associate { (id, raw) -> id to GenerationParameterOverride(GenerationOverrideState.Value, JsonPrimitive(raw)) },
    )

    @Test
    fun `conversation reset clears only this conversation and says so`() {
        var raw: String? = null
        val fragments = LocalCapabilityCustomFragmentStore({ raw }, { raw = it })
        val body = LocalCapabilityCustomFragmentStore.AdditionalBody("""{"top_k": 1}""", sendWithRequest = true)
        fragments.setAdditionalBody(body, "p1", "m1", "c1")
        store.setModelDefaults(values("temperature" to 0.2), "p1", "m1")
        store.setSessionOverrides(values("temperature" to 0.7, "top_p" to 0.9), "p1", "m1", "c1")
        store.setSessionOverrides(values("top_p" to 0.5), "p1", "m1", "c2")

        val plan = AdvancedReset.plan(store, "p1", "m1", "c1", null)
        assertEquals(R.string.advanced_reset_conversation_title, plan.titleRes)
        assertEquals(R.string.advanced_reset_conversation_body, plan.bodyRes)
        assertEquals(R.string.advanced_reset_conversation_action, plan.confirmRes)
        plan.execute()

        assertNull(store.sessionOverrides("p1", "m1", "c1")?.values?.takeIf { it.isNotEmpty() })
        assertEquals(values("top_p" to 0.5), store.sessionOverrides("p1", "m1", "c2"))
        assertEquals(values("temperature" to 0.2), store.modelDefaults("p1", "m1"))
        assertEquals(body, fragments.additionalBody("p1", "m1", "c1"))
        // After clearing, the effective value falls back to the model-default layer.
        assertEquals(
            ai.oriveo.community.core.model.GenerationParameterSource.ModelDefault,
            store.resolveWithSources(null, "p1", "m1", "c1").getValue("temperature").source,
        )
    }

    @Test
    fun `model scope reset clears model defaults and keeps conversations`() {
        store.setModelDefaults(values("temperature" to 0.2), "p1", "m1")
        store.setSessionOverrides(values("temperature" to 0.7), "p1", "m1", "c1")
        val plan = AdvancedReset.plan(store, "p1", "m1", null, null)
        assertEquals(R.string.advanced_reset_model_title, plan.titleRes)
        assertEquals(R.string.advanced_reset_model_body, plan.bodyRes)
        assertEquals(R.string.advanced_reset_model_action, plan.confirmRes)
        plan.execute()
        assertNull(store.modelDefaults("p1", "m1")?.values?.takeIf { it.isNotEmpty() })
        assertEquals(values("temperature" to 0.7), store.sessionOverrides("p1", "m1", "c1"))
    }

    @Test
    fun `unverified baseline keeps inline marks for rows of a different presentation class`() {
        val local = LocalEngineGenerationProfiles.profile("llamacpp", RelayTransport.OpenAIChatCompletions)!!
        // A "no data" row is just as unverified but differs from what the header says, so the row is still marked.
        val mixed = local.copy(parameters = local.parameters.mapIndexed { index, parameter ->
            if (index == 1) parameter.copy(support = "unknown") else parameter
        })
        val page = GenerationParameterRowModel.page(mixed, emptyMap(), isUnverified = { true })
        assertEquals(Verification.Unverified, page.baseline)
        assertEquals(PresentationClass.Unverified, page.baselineClass)
        val marked = page.rows.filter { it.inlineVerification != null }
        assertEquals(listOf(mixed.parameters[1].id), marked.map { it.id })
        assertEquals(PresentationClass.NoData, marked.single().presentationClass)
        assertEquals(Verification.Unverified, marked.single().inlineVerification)
    }

    @Test
    fun `half unverified is not a baseline and every unverified row is marked`() {
        val profile = GenerationProfileRef(
            template = "openai_chat_completions",
            parameters = listOf(
                GenerationParameterRef(id = "temperature", support = "supported", valueSchema = "number"),
                GenerationParameterRef(id = "top_p", support = "accepted_unverified", valueSchema = "number"),
            ),
            wire = mapOf("temperature" to "temperature", "top_p" to "top_p"),
        )
        val page = GenerationParameterRowModel.page(profile, emptyMap(), isUnverified = { it.id == "top_p" })
        assertEquals(Verification.Verified, page.baseline)
        assertEquals(listOf("top_p"), page.rows.filter { it.inlineVerification != null }.map { it.id })
    }

    @Test
    fun `layout puts common rows first and groups the rest with summaries and one takeover note`() {
        val profile = GenerationProfileRef(
            template = "openai_chat_completions",
            parameters = listOf(
                GenerationParameterRef(id = "top_p", support = "supported", valueSchema = "number", group = "sampling"),
                GenerationParameterRef(id = "temperature", support = "supported", valueSchema = "number", group = "sampling"),
                GenerationParameterRef(id = "max_output_tokens", support = "supported", valueSchema = "integer", group = "budget"),
                GenerationParameterRef(id = "stop", support = "supported", valueSchema = "string-list", group = "budget"),
                GenerationParameterRef(id = "frequency_penalty", support = "supported", valueSchema = "number", group = "repetition"),
                GenerationParameterRef(id = "presence_penalty", support = "supported", valueSchema = "number", group = "repetition"),
                GenerationParameterRef(id = "mirostat", support = "supported", valueSchema = "integer", group = "sampling", conflictsWith = listOf("top_p", "typical_p")),
                GenerationParameterRef(id = "typical_p", support = "supported", valueSchema = "number", group = "sampling"),
            ),
            wire = listOf("top_p", "temperature", "max_output_tokens", "stop", "frequency_penalty", "presence_penalty", "mirostat", "typical_p").associateWith { it },
        )
        store.setSessionOverrides(values("frequency_penalty" to 0.3, "mirostat" to 2.0), "p1", "m1", "c1")
        val page = GenerationParameterRowModel.page(profile, store.resolveWithSources(null, "p1", "m1", "c1"))
        val layout = AdvancedSettingsLayout.layout(page, profile)

        assertEquals(listOf("max_output_tokens", "temperature", "top_p"), layout.common)
        assertEquals(listOf("mirostat"), layout.commonTakenOverBy)
        // Mirostat forms its own subgroup and the other sampling items go into "more sampling".
        assertEquals(listOf("budget", "more_sampling", "mirostat", "repetition"), layout.more.map { it.key })
        assertEquals(listOf("stop"), layout.more[0].rowIds)
        assertEquals(listOf("typical_p"), layout.more[1].rowIds)
        val mirostat = layout.more[2]
        assertEquals(listOf("mirostat"), mirostat.rowIds)
        assertEquals(listOf("mirostat"), mirostat.adjustedIds)
        assertTrue(mirostat.takenOverBy.isEmpty())
        assertEquals(listOf("frequency_penalty"), layout.more[3].adjustedIds)
        assertTrue(layout.more[3].takenOverBy.isEmpty())
        assertEquals(R.string.advanced_repetition, AdvancedSettingsLayout.groupTitleRes("repetition"))
    }

    @Test
    fun `not adjustable rows keep the supported models action except reasoning rows with no writer`() {
        val profile = GenerationProfileRef(
            template = "openai_chat_completions",
            parameters = listOf(
                GenerationParameterRef(id = "temperature", support = "fixed", valueSchema = "number"),
                GenerationParameterRef(id = "top_p", support = "supported", valueSchema = "number"),
                GenerationParameterRef(id = "reasoning_effort", support = "fixed", group = "reasoning"),
            ),
            wire = mapOf("temperature" to "temperature", "top_p" to "top_p"),
        )
        val provider = ai.oriveo.community.core.model.Provider(id = "official-outlets", kind = ai.oriveo.community.core.model.ProviderKind.OpenAI)
        val model = ai.oriveo.community.core.model.AIModel(id = "gpt-x", name = "gpt-x", generationProfile = profile)
        val projection = ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter.generationParameterUiProjection(
            provider = provider,
            model = model,
            localIdentity = null,
            parameters = profile.parameters,
            values = GenerationParameterOverrides(),
        )
        val actions = AdvancedSettingsOutlets.supportedModelsActions(profile, projection)
        assertEquals(setOf("temperature"), actions.keys)
        assertEquals(R.string.model_control_view_supported_models, actions["temperature"])
    }

    @Test
    fun `custom fields entry opens, offers supported models, or says none would help`() {
        val candidate = ai.oriveo.community.core.model.AIModel(id = "m2", name = "m2")
        assertEquals(
            AdvancedSettingsOutlets.CustomFieldsTap.Open,
            AdvancedSettingsOutlets.customFieldsTap(ai.oriveo.community.feature.providers.detail.CustomFieldsEntry.Idle, emptyList()),
        )
        assertEquals(
            AdvancedSettingsOutlets.CustomFieldsTap.Open,
            AdvancedSettingsOutlets.customFieldsTap(ai.oriveo.community.feature.providers.detail.CustomFieldsEntry.InUse, emptyList()),
        )
        assertEquals(
            AdvancedSettingsOutlets.CustomFieldsTap.OfferSupportedModels,
            AdvancedSettingsOutlets.customFieldsTap(ai.oriveo.community.feature.providers.detail.CustomFieldsEntry.Unsupported, listOf(candidate)),
        )
        assertEquals(
            AdvancedSettingsOutlets.CustomFieldsTap.NoModelWouldHelp,
            AdvancedSettingsOutlets.customFieldsTap(ai.oriveo.community.feature.providers.detail.CustomFieldsEntry.Unsupported, emptyList()),
        )
    }
}
