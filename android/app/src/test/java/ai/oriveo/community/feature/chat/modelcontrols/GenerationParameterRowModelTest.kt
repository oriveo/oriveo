package ai.oriveo.community.feature.chat.modelcontrols

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.GenerationOverrideState
import ai.oriveo.community.core.model.GenerationParameterOverride
import ai.oriveo.community.core.model.GenerationParameterOverrides
import ai.oriveo.community.core.model.GenerationParameterRange
import ai.oriveo.community.core.model.GenerationParameterRef
import ai.oriveo.community.core.model.GenerationParameterSettingsStore
import ai.oriveo.community.core.model.GenerationParameterSource
import ai.oriveo.community.core.model.GenerationProfileRef
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.GenerationParameterResolver
import ai.oriveo.community.core.provider.GenerationParameterResolver.DropReason
import ai.oriveo.community.core.provider.LocalEngineGenerationProfiles
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.DisplayValue
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.FallbackKind
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.Source
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.ValidationError
import ai.oriveo.community.feature.chat.modelcontrols.GenerationParameterRowModel.Verification
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GenerationParameterRowModelTest {
    private var payload: String? = null
    private val store = GenerationParameterSettingsStore(readPayload = { payload }, writePayload = { payload = it })

    private fun value(raw: JsonElement) = GenerationParameterOverride(GenerationOverrideState.Value, raw)
    private fun values(vararg pairs: Pair<String, JsonElement>) =
        GenerationParameterOverrides(pairs.associate { (id, raw) -> id to value(raw) })

    @Test
    fun `resolve with sources labels session and model default layers and leaves the rest to the model`() {
        store.setModelDefaults(values("temperature" to JsonPrimitive(0.2), "top_p" to JsonPrimitive(0.9)), "p1", "m1")
        store.setSessionOverrides(values("temperature" to JsonPrimitive(0.7)), "p1", "m1", "c1")
        val sourced = store.resolveWithSources(null, "p1", "m1", "c1")
        assertEquals(GenerationParameterSource.Session, sourced.getValue("temperature").source)
        assertEquals(JsonPrimitive(0.7), sourced.getValue("temperature").override.value)
        assertEquals(GenerationParameterSource.ModelDefault, sourced.getValue("top_p").source)
        assertFalse("max_output_tokens" in sourced)
        // The older entry point behaves the same: same values, same precedence.
        assertEquals(
            GenerationParameterOverrides(mapOf("temperature" to value(JsonPrimitive(0.7)), "top_p" to value(JsonPrimitive(0.9)))),
            store.resolve(null, "p1", "m1", "c1"),
        )
        val page = GenerationParameterRowModel.page(profile(), sourced)
        assertEquals(Source.Session, page.row("temperature").source)
        assertEquals(Source.ModelDefault, page.row("top_p").source)
        assertEquals(Source.ModelDecides, page.row("max_output_tokens").source)
    }

    @Test
    fun `llama cpp max tokens default of minus one shows as unlimited and is not sent`() {
        val profile = LocalEngineGenerationProfiles.profile("llamacpp", RelayTransport.OpenAIChatCompletions)!!
        val page = GenerationParameterRowModel.page(profile, emptyMap())
        assertEquals(DisplayValue.Fallback(FallbackKind.Unlimited), page.row("max_output_tokens").display)
        val result = GenerationParameterResolver.applyWithResult(
            """{"model":"m","messages":[]}""",
            ChatRequestOptions(activeModel = AIModel(id = "m", name = "m", generationProfile = profile)),
            null,
            relayProjection(AIModel(id = "m", name = "m", generationProfile = profile), RelayTransport.OpenAIChatCompletions, profile),
        )
        assertFalse(result.body.contains("-1"))
    }

    @Test
    fun `string fixed value is shown without json quotes`() {
        val parameter = GenerationParameterRef(id = "verbosity", support = "supported", fixedValue = JsonPrimitive("low"))
        assertEquals(DisplayValue.Value("low"), GenerationParameterRowModel.display(parameter, null))
        val placeholder = GenerationParameterRef(id = "seed", defaultDescription = JsonPrimitive("provider_default"))
        assertEquals(DisplayValue.Fallback(FallbackKind.ModelDecides), GenerationParameterRowModel.display(placeholder, null))
    }

    @Test
    fun `out of range value is flagged with the allowed range and not clamped`() {
        val sourced = store.also { it.setSessionOverrides(values("temperature" to JsonPrimitive(3)), "p1", "m1", "c1") }
            .resolveWithSources(null, "p1", "m1", "c1")
        val row = GenerationParameterRowModel.page(profile(), sourced).row("temperature")
        assertEquals(ValidationError.OutOfRange(GenerationParameterRange(min = 0.0, max = 2.0)), row.validationError)
        assertEquals(DisplayValue.Value("3"), row.display)
    }

    @Test
    fun `drop reasons come from the production resolver`() {
        val profile = profile()
        val model = AIModel(id = "m", name = "m", generationProfile = profile)
        val overrides = values(
            "temperature" to JsonPrimitive(5),
            "mirostat" to JsonPrimitive(2),
            "top_k" to JsonPrimitive(40),
            "mirostat_tau" to JsonPrimitive(4.0),
        )
        val result = GenerationParameterResolver.applyWithResult(
            """{"model":"m","messages":[]}""",
            ChatRequestOptions(generationParameters = overrides, activeModel = model),
            null,
            relayProjection(model, RelayTransport.OpenAIChatCompletions, profile),
        )
        val sourced = overrides.values.mapValues {
            ai.oriveo.community.core.model.SourcedGenerationParameter(it.value, GenerationParameterSource.Session)
        }
        val page = GenerationParameterRowModel.page(profile, sourced, result.dropped)
        assertEquals(DropReason.InvalidValue, page.row("temperature").dropReason)
        assertEquals(DropReason.Conflict, page.row("top_k").dropReason)
        assertEquals(DropReason.RequirementUnmet, page.row("mirostat_tau").dropReason)
        assertEquals("mirostat", page.row("top_k").takenOverBy)
        assertEquals("mirostat", page.row("top_p").takenOverBy)
        assertNull(page.row("mirostat").dropReason)
    }

    @Test
    fun `thinking drop reason comes from the production anthropic guard`() {
        val profile = GenerationProfileRef(
            template = "anthropic_messages",
            parameters = listOf(GenerationParameterRef(id = "temperature", support = "supported", valueSchema = "number")),
            wire = mapOf("temperature" to "temperature"),
        )
        val model = AIModel(id = "claude-x", name = "claude-x", generationProfile = profile)
        val overrides = values("temperature" to JsonPrimitive(0.3))
        val result = GenerationParameterResolver.applyWithResult(
            """{"model":"claude-x","max_tokens":8192,"messages":[],"thinking":{"type":"enabled","budget_tokens":2048}}""",
            ChatRequestOptions(generationParameters = overrides, activeModel = model),
            null,
            relayProjection(model, RelayTransport.AnthropicMessages, profile),
        )
        val page = GenerationParameterRowModel.page(
            profile,
            mapOf("temperature" to ai.oriveo.community.core.model.SourcedGenerationParameter(value(JsonPrimitive(0.3)), GenerationParameterSource.Session)),
            result.dropped,
        )
        assertEquals(DropReason.ThinkingIncompatible, page.row("temperature").dropReason)
    }

    @Test
    fun `reasoning row without a wire path is read only and points to model options`() {
        val profile = GenerationProfileRef(
            template = "anthropic_messages",
            parameters = listOf(
                GenerationParameterRef(id = "reasoning_effort", support = "supported", group = "reasoning"),
                GenerationParameterRef(id = "temperature", support = "supported", valueSchema = "number"),
            ),
            wire = mapOf("temperature" to "temperature"),
        )
        val page = GenerationParameterRowModel.page(profile, emptyMap())
        assertFalse(page.row("reasoning_effort").isEditable)
        assertTrue(page.row("reasoning_effort").reasoningSetInModelOptions)
        assertTrue(page.row("temperature").isEditable)
        assertFalse(page.row("temperature").reasoningSetInModelOptions)
    }

    @Test
    fun `unverified as page baseline marks only rows that differ`() {
        val local = LocalEngineGenerationProfiles.profile("llamacpp", RelayTransport.OpenAIChatCompletions)!!
        val allUnverified = GenerationParameterRowModel.page(local, emptyMap())
        assertEquals(Verification.Unverified, allUnverified.baseline)
        assertTrue(allUnverified.rows.all { it.inlineVerification == null })
        val mixed = local.copy(parameters = local.parameters.mapIndexed { index, parameter ->
            if (index == 0) parameter.copy(support = "supported") else parameter
        })
        val page = GenerationParameterRowModel.page(mixed, emptyMap())
        assertEquals(listOf(Verification.Verified), page.rows.mapNotNull { it.inlineVerification })
        assertEquals(Verification.Verified, GenerationParameterRowModel.page(profile(), emptyMap()).baseline)
    }

    @Test
    fun `summary shows at most two chips and folds the rest`() {
        store.setSessionOverrides(
            values("temperature" to JsonPrimitive(0.2), "top_p" to JsonPrimitive(0.9), "max_output_tokens" to JsonPrimitive(4096)),
            "p1", "m1", "c1",
        )
        val page = GenerationParameterRowModel.page(profile(), store.resolveWithSources(null, "p1", "m1", "c1"))
        val summary = GenerationParameterRowModel.summary(page.rows)
        assertEquals(listOf("max_output_tokens", "temperature"), summary.chips.map { it.id })
        assertEquals(DisplayValue.Value("4096"), summary.chips.first().display)
        assertEquals(1, summary.moreCount)
        assertEquals(GenerationParameterRowModel.Summary(emptyList(), 0), GenerationParameterRowModel.summary(emptyList()))
    }

    private fun GenerationParameterRowModel.Page.row(id: String) = rows.first { it.id == id }

    private fun profile(): GenerationProfileRef {
        val ids = listOf("max_output_tokens", "temperature", "top_p", "top_k", "mirostat", "mirostat_tau")
        return GenerationProfileRef(
            template = "openai_chat_completions",
            parameters = listOf(
                GenerationParameterRef(id = "max_output_tokens", support = "supported", valueSchema = "integer", range = GenerationParameterRange(min = 1.0)),
                GenerationParameterRef(id = "temperature", support = "supported", valueSchema = "number", range = GenerationParameterRange(min = 0.0, max = 2.0)),
                GenerationParameterRef(id = "mirostat", support = "supported", valueSchema = "integer", conflictsWith = listOf("top_k", "top_p")),
                GenerationParameterRef(id = "top_p", support = "supported", valueSchema = "number"),
                GenerationParameterRef(id = "top_k", support = "supported", valueSchema = "integer"),
                GenerationParameterRef(
                    id = "mirostat_tau", support = "supported", valueSchema = "number",
                    requires = listOf(buildJsonObject { put("key", "mirostat_eta") }),
                ),
            ),
            wire = ids.associateWith { if (it == "max_output_tokens") "max_tokens" else it },
            transport = "openai_chat_completions",
        )
    }

    private fun relayProjection(
        model: AIModel,
        transport: RelayTransport,
        profile: GenerationProfileRef,
    ): CapabilityEvidenceProductionAdapter.Projection {
        val keys = profile.parameters.mapNotNull { it.id }.map { "generation_parameter/$it" }.toSet()
        val provider = Provider(
            id = "relay-rows",
            kind = ProviderKind.Relay,
            baseUrlText = "https://relay.example/v1",
            relayRequested = RelayRequestedConfig(transport = transport),
        )
        val finalUrl = if (transport == RelayTransport.AnthropicMessages) {
            "https://relay.example/v1/messages"
        } else {
            "https://relay.example/v1/chat/completions"
        }
        val identity = CapabilityEvidenceProductionAdapter.dispatchIdentity(
            CapabilityEvidenceIdentity("test", provider.id, "1", "1", ProviderKind.Relay.rawValue),
            model,
            transport,
            finalUrl,
        )
        return CapabilityEvidenceProductionAdapter.dispatchCapabilityProjection(
            model = model,
            relayRequested = provider.relayRequested,
            identity = identity,
            keys = keys,
            explicitKeys = keys,
        )
    }
}
