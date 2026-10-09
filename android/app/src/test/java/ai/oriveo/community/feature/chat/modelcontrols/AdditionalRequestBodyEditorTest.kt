package ai.oriveo.community.feature.chat.modelcontrols

import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore.AdditionalBody
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.AdditionalRequestBody
import ai.oriveo.community.core.provider.AdditionalRequestBody.PreviewEntry
import ai.oriveo.community.core.provider.AdditionalRequestBody.PreviewStatus
import ai.oriveo.community.core.provider.ModelControlRuntimeIdentityResolver
import ai.oriveo.community.feature.providers.detail.customRequestFieldSectionOpensAdditionalBody
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AdditionalRequestBodyEditorTest {
    // A sample for the additional body page: the messages on line 6 are filled in by the app.
    private val sample = """
        {
          "chat_template_kwargs": {
            "enable_thinking": false
          },
          "cache_prompt": true,
          "messages": []
        }
    """.trimIndent()

    private val provider = Provider(
        id = "relay-local",
        kind = ProviderKind.Relay,
        baseUrlText = "http://127.0.0.1:8080/v1",
        relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
    )
    private val model = AIModel(id = "qwen3-8b-instruct-q4", name = "qwen3-8b-instruct-q4")

    @Test
    fun `preview lists leaf paths and marks protected fields with their line`() {
        val preview = AdditionalRequestBody.preview(sample)
        assertEquals(
            listOf(
                PreviewEntry("chat_template_kwargs.enable_thinking", PreviewStatus.Included, 3),
                PreviewEntry("cache_prompt", PreviewStatus.Included, 5),
                PreviewEntry("messages", PreviewStatus.Protected, 6),
            ),
            preview.entries,
        )
        // The verdict comes from the same validation as sending: this is exactly what would be rejected locally.
        val rejected = preview.validation as AdditionalRequestBody.Validation.Rejected
        assertEquals("protected_field", rejected.reason)
        assertEquals("messages", rejected.field)
    }

    @Test
    fun `preview flags blocked names at any depth and leaves syntax errors to the validator`() {
        val blocked = AdditionalRequestBody.preview("{\n  \"a\": {\"__proto__\": 1},\n  \"b\": [1, 2]\n}")
        assertEquals(
            listOf(PreviewEntry("a.__proto__", PreviewStatus.BlockedName, 2), PreviewEntry("b", PreviewStatus.Included, 3)),
            blocked.entries,
        )
        val broken = AdditionalRequestBody.preview("{\n  \"a\": 1,\n  \"b\": \n}")
        assertTrue(broken.entries.isEmpty())
        // The line number is where the syntax scan stopped: with a missing value it stops at the } on the next line.
        assertEquals(4, (broken.validation as AdditionalRequestBody.Validation.Rejected).line)
        val blank = AdditionalRequestBody.preview("   \n")
        assertEquals(AdditionalRequestBody.Validation.Empty, blank.validation)
        assertTrue(blank.entries.isEmpty())
    }

    @Test
    fun `tidy reindents valid json and leaves invalid json alone`() {
        val tidied = AdditionalRequestBody.tidy("""{"b":{"c":1},"a":[1,2]}""")!!
        assertEquals("{\n  \"b\": {\n    \"c\": 1\n  },\n  \"a\": [\n    1,\n    2\n  ]\n}", tidied)
        assertEquals(Json.parseToJsonElement("""{"b":{"c":1},"a":[1,2]}"""), Json.parseToJsonElement(tidied))
        assertNull(AdditionalRequestBody.tidy("""{"a": """))
    }

    @Test
    fun `editor reads and writes the store the send path reads`() {
        var raw: String? = null
        var additional: String? = null
        val store = LocalCapabilityCustomFragmentStore({ raw }, { raw = it }, readAdditionalBody = { additional }, writeAdditionalBody = { additional = it })
        val key = ModelControlRuntimeIdentityResolver.resolve(provider, model)?.canonicalModelId ?: model.id
        assertEquals(key, AdditionalBodyEditor.modelKey(provider, model))

        AdditionalBodyEditor.save(store, provider, model, "c1", AdditionalBody("""{"top_k": 40}""", sendWithRequest = true))
        assertEquals("""{"top_k": 40}""", store.outboundAdditionalBody(provider.id, key, "c1"))
        // After turning it off the content stays, it is just not sent.
        AdditionalBodyEditor.save(store, provider, model, "c1", AdditionalBody("""{"top_k": 40}""", sendWithRequest = false))
        assertNull(store.outboundAdditionalBody(provider.id, key, "c1"))
        assertEquals(AdditionalBody("""{"top_k": 40}""", false), AdditionalBodyEditor.load(store, provider, model, "c1"))
    }

    @Test
    fun `old generation entry now opens the additional body page and sees migrated content`() {
        assertTrue(customRequestFieldSectionOpensAdditionalBody("generation"))
        assertFalse(customRequestFieldSectionOpensAdditionalBody("web"))
        assertFalse(customRequestFieldSectionOpensAdditionalBody("reasoning"))

        var raw: String? = null
        var additional: String? = null
        val key = AdditionalBodyEditor.modelKey(provider, model)
        LocalCapabilityCustomFragmentStore({ raw }, { raw = it }).setFragment("""{"top_k":2}""", provider.id, key, "c1", "openai_chat_completions|rev-a")
        val store = LocalCapabilityCustomFragmentStore({ raw }, { raw = it }, readAdditionalBody = { additional }, writeAdditionalBody = { additional = it })
        // What the older editor wrote is visible in the new page (migration happens on read) instead of an empty page.
        assertEquals(AdditionalBody("""{"top_k":2}""", true), AdditionalBodyEditor.load(store, provider, model, "c1"))
    }

    @Test
    fun `reason copy and field count follow the preview`() {
        assertEquals(R.string.additional_body_conversation_filled, AdditionalBodyEditor.reasonRes(PreviewEntry("messages", PreviewStatus.Protected, 1)))
        assertEquals(R.string.additional_body_model_chosen, AdditionalBodyEditor.reasonRes(PreviewEntry("model", PreviewStatus.Protected, 1)))
        assertEquals(R.string.additional_body_tools_managed, AdditionalBodyEditor.reasonRes(PreviewEntry("tool_choice", PreviewStatus.Protected, 1)))
        assertEquals(R.string.additional_body_streaming_by_oriveo, AdditionalBodyEditor.reasonRes(PreviewEntry("stream_options", PreviewStatus.Protected, 1)))
        assertEquals(R.string.additional_body_system_prompt_filled, AdditionalBodyEditor.reasonRes(PreviewEntry("instructions", PreviewStatus.Protected, 1)))
        assertEquals(R.string.additional_body_attachments_filled, AdditionalBodyEditor.reasonRes(PreviewEntry("attachments", PreviewStatus.Protected, 1)))
        assertEquals(R.string.additional_body_field_name_invalid, AdditionalBodyEditor.reasonRes(PreviewEntry("a.constructor", PreviewStatus.BlockedName, 1)))
        assertEquals(2, AdditionalBodyEditor.fieldCount(sample))
        assertEquals(0, AdditionalBodyEditor.fieldCount("  "))
        assertEquals(0, AdditionalBodyEditor.fieldCount("{"))
    }

    @Test
    fun `engine docs link follows the connection engine profile and only the four local engines`() {
        fun relay(engine: String?) = Provider(
            id = "relay-docs",
            kind = ProviderKind.Relay,
            baseUrlText = "http://127.0.0.1:8080/v1",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions, engineProfile = engine),
        )
        assertEquals(
            AdditionalBodyEditor.EngineDocs("llama.cpp", "https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md"),
            AdditionalBodyEditor.engineDocs(relay("llamacpp")),
        )
        assertEquals(
            AdditionalBodyEditor.EngineDocs("Ollama", "https://docs.ollama.com/api/openai-compatibility"),
            AdditionalBodyEditor.engineDocs(relay("ollama")),
        )
        assertEquals(
            AdditionalBodyEditor.EngineDocs("LM Studio", "https://lmstudio.ai/docs/developer/openai-compat/chat-completions"),
            AdditionalBodyEditor.engineDocs(relay("lmstudio")),
        )
        assertEquals(
            AdditionalBodyEditor.EngineDocs("vLLM", "https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/"),
            AdditionalBodyEditor.engineDocs(relay("vllm")),
        )
        assertNull(AdditionalBodyEditor.engineDocs(relay(null)))
        assertNull(AdditionalBodyEditor.engineDocs(relay("openwebui")))
        assertNull(AdditionalBodyEditor.engineDocs(Provider(id = "official", kind = ProviderKind.OpenAI)))
        assertEquals(R.string.additional_body_docs_link, AdditionalBodyEditor.ENGINE_DOCS_LINK_RES)
    }

    @Test
    fun `entry row opens the page and summarises what is saved`() {
        // The field count is the production fieldCount of the sample.
        val fields = AdditionalBodyEditor.fieldCount(sample)
        assertTrue(fields > 0)
        run {
            assertEquals(
                AdditionalBodyEditor.EntryRow(true, R.string.advanced_fields_count, fields),
                AdditionalBodyEditor.entryRow(sendWithRequest = true, fieldCount = fields),
            )
            assertEquals(
                AdditionalBodyEditor.EntryRow(true, R.string.advanced_not_in_use),
                AdditionalBodyEditor.entryRow(sendWithRequest = false, fieldCount = fields),
            )
            assertEquals(
                AdditionalBodyEditor.EntryRow(true, R.string.advanced_not_in_use),
                AdditionalBodyEditor.entryRow(sendWithRequest = true, fieldCount = 0),
            )
        }
    }
}
