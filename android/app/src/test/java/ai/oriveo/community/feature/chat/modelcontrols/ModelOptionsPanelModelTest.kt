package ai.oriveo.community.feature.chat.modelcontrols

import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore
import ai.oriveo.community.core.model.LocalCapabilityCustomFragmentStore.AdditionalBody
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.CapabilityControlPresentation
import ai.oriveo.community.core.provider.CapabilityControlPresentationResolver
import ai.oriveo.community.core.provider.GenerationParameterOutboundContractTest
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.ConnectionCategory
import ai.oriveo.community.feature.chat.modelcontrols.ModelOptionCapabilityShape.CustomProtocol
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelOptionsPanelModelTest {
    private fun root(raw: String): JsonObject = Json.parseToJsonElement(raw).jsonObject

    // -- chat-template thinking switch of a custom connection --

    private fun written(body: AdditionalBody, enable: Boolean) =
        ChatTemplateThinking.write(body, enable) as ChatTemplateThinking.Write.Written

    @Test
    fun `state covers off on blocked and not sending`() {
        val s = ChatTemplateThinking::state
        assertEquals(ChatTemplateThinking.State.Off, s(AdditionalBody.Empty))
        assertEquals(ChatTemplateThinking.State.On, s(AdditionalBody("""{"chat_template_kwargs":{"enable_thinking":true}}""", true)))
        // true but sending is off and there are no other fields: off
        assertEquals(ChatTemplateThinking.State.Off, s(AdditionalBody("""{"chat_template_kwargs":{"enable_thinking":true}}""", false)))
        assertEquals(ChatTemplateThinking.State.Off, s(AdditionalBody("""{"chat_template_kwargs":{"enable_thinking":"true"}}""", true)))
        assertEquals(ChatTemplateThinking.State.Blocked, s(AdditionalBody("""{"chat_template_kwargs": {""", true)))
        assertEquals(ChatTemplateThinking.State.Blocked, s(AdditionalBody("""{"chat_template_kwargs": "on"}""", true)))
        assertEquals(ChatTemplateThinking.State.Blocked, s(AdditionalBody("""[1]""", true)))
        // Rejected by local validation (protected field)
        assertEquals(ChatTemplateThinking.State.Blocked, s(AdditionalBody("""{"model":"x"}""", true)))
        assertEquals(ChatTemplateThinking.State.NotSending, s(AdditionalBody("""{"min_p":0.05}""", false)))
        assertEquals(ChatTemplateThinking.State.NotSending, s(AdditionalBody("""{"chat_template_kwargs":{"enable_thinking":true,"x":1}}""", false)))
        assertEquals(ChatTemplateThinking.State.Off, s(AdditionalBody("""{"min_p":0.05}""", true)))
    }

    @Test
    fun `blocked and not sending replace the switch note`() {
        assertEquals(R.string.additional_body_switch_blocked_invalid,
            ModelOptionsRender.templateThinkingBlockedNoteRes(ChatTemplateThinking.State.Blocked))
        assertEquals(R.string.additional_body_switch_blocked_off,
            ModelOptionsRender.templateThinkingBlockedNoteRes(ChatTemplateThinking.State.NotSending))
        assertNull(ModelOptionsRender.templateThinkingBlockedNoteRes(ChatTemplateThinking.State.On))
        assertNull(ModelOptionsRender.templateThinkingBlockedNoteRes(ChatTemplateThinking.State.Off))
    }

    @Test
    fun `blocked and not sending writes nothing`() {
        listOf(
            AdditionalBody("""{"chat_template_kwargs": {""", true),
            AdditionalBody("""{"chat_template_kwargs": "on"}""", true),
            AdditionalBody("""{"min_p":0.05}""", false),
        ).forEach { body ->
            assertEquals(ChatTemplateThinking.Write.Unavailable, ChatTemplateThinking.write(body, true))
            assertEquals(ChatTemplateThinking.Write.Unavailable, ChatTemplateThinking.write(body, false))
        }
    }

    @Test
    fun `from blank writes the indented object and turns sending on`() {
        val on = written(AdditionalBody.Empty, true)
        assertEquals("{\n  \"chat_template_kwargs\": {\n    \"enable_thinking\": true\n  }\n}", on.body.rawJSON)
        assertTrue(on.body.sendWithRequest)
        val off = written(AdditionalBody("", sendWithRequest = false), false)
        assertEquals("{\n  \"chat_template_kwargs\": {\n    \"enable_thinking\": false\n  }\n}", off.body.rawJSON)
        assertTrue(off.body.sendWithRequest)
    }

    @Test
    fun `turning off writes false in place and keeps every other byte`() {
        val raw = "{\n    \"top_k\": 20,\n    \"chat_template_kwargs\": {\n        \"foo\": 1.50,\n        \"enable_thinking\":   true\n    },\n    \"stop\": [\"a\", \"b\"]\n}"
        val result = written(AdditionalBody(raw, sendWithRequest = true), false)
        assertEquals(raw.replace("\"enable_thinking\":   true", "\"enable_thinking\":   false"), result.body.rawJSON)
        assertTrue(result.body.sendWithRequest)
    }

    @Test
    fun `turning on inserts the flag with the surrounding indentation`() {
        // Sending off with only this field counts as off; turning it on also turns sending on
        val inKwargs = "{\n    \"chat_template_kwargs\": {\n        \"foo\": 1\n    }\n}"
        val r1 = written(AdditionalBody(inKwargs, sendWithRequest = true), true)
        assertEquals("{\n    \"chat_template_kwargs\": {\n        \"foo\": 1,\n        \"enable_thinking\": true\n    }\n}", r1.body.rawJSON)

        val noKwargs = "{\n  \"top_k\": 20,\n  \"stop\": [\"a\"]\n}"
        val r2 = written(AdditionalBody(noKwargs, sendWithRequest = true), true)
        assertEquals("{\n  \"top_k\": 20,\n  \"stop\": [\"a\"],\n  \"chat_template_kwargs\": {\n    \"enable_thinking\": true\n  }\n}", r2.body.rawJSON)

        val oneLine = """{"top_k": 20}"""
        val r3 = written(AdditionalBody(oneLine, sendWithRequest = true), true)
        assertEquals("""{"top_k": 20, "chat_template_kwargs": {"enable_thinking": true}}""", r3.body.rawJSON)

        val onlyFlagNotSending = AdditionalBody("""{"chat_template_kwargs":{"enable_thinking":false}}""", sendWithRequest = false)
        val r4 = written(onlyFlagNotSending, true)
        assertEquals("""{"chat_template_kwargs":{"enable_thinking":true}}""", r4.body.rawJSON)
        assertTrue(r4.body.sendWithRequest)
    }

    @Test
    fun `escaped key names fall back to the sorted indented format without losing content`() {
        val raw = """{"z": 1, "chat\u005ftemplate_kwargs": {"enable_thinking": false, "b": [1, 2]}, "a": {"y": 2, "x": 1}}"""
        val result = written(AdditionalBody(raw, sendWithRequest = true), true)
        assertEquals(
            "{\n  \"a\": {\n    \"x\": 1,\n    \"y\": 2\n  },\n  \"chat_template_kwargs\": {\n    \"b\": [\n      1,\n      2\n    ],\n" +
                "    \"enable_thinking\": true\n  },\n  \"z\": 1\n}",
            result.body.rawJSON,
        )
    }

    @Test
    fun `writes on top of the effective model default into the conversation layer`() {
        var raw: String? = null
        val store = LocalCapabilityCustomFragmentStore({ raw }, { raw = it })
        // The model default carries other fields; the conversation layer has no record
        store.setAdditionalBody(AdditionalBody("{\n  \"min_p\": 0.05\n}", sendWithRequest = true), "p1", "m1", null)
        val effective = store.additionalBody("p1", "m1", "c1")
        assertEquals(ChatTemplateThinking.State.Off, ChatTemplateThinking.state(effective))
        store.setAdditionalBody(written(effective, true).body, "p1", "m1", "c1")
        val conversation = store.additionalBody("p1", "m1", "c1")
        assertEquals(ChatTemplateThinking.State.On, ChatTemplateThinking.state(conversation))
        assertEquals("0.05", root(conversation.rawJSON)["min_p"].toString())
        // The model default stays untouched
        assertEquals("{\n  \"min_p\": 0.05\n}", store.additionalBody("p1", "m1", null).rawJSON)
    }

    // -- status mark --

    @Test
    fun `status mark follows connection category and capability evidence`() {
        val auto = listOf(CapabilityControlPresentation.AutomaticAvailable, CapabilityControlPresentation.Unknown)
        val none = listOf(CapabilityControlPresentation.Unknown, CapabilityControlPresentation.Pending)
        assertEquals(ModelOptionsStatusMark.Unverified, ModelOptionsStatusMark.resolve(ConnectionCategory.CustomLLM, auto))
        assertEquals(ModelOptionsStatusMark.Official, ModelOptionsStatusMark.resolve(ConnectionCategory.Other, auto))
        assertEquals(ModelOptionsStatusMark.None, ModelOptionsStatusMark.resolve(ConnectionCategory.Other, none))
        assertEquals(R.string.generation_parameter_source_official, ModelOptionsStatusMark.Official.labelRes)
        assertEquals(R.string.generation_parameter_unverified_badge, ModelOptionsStatusMark.Unverified.labelRes)
        assertNull(ModelOptionsStatusMark.None.labelRes)
    }

    @Test
    fun `production official recipe gives the official mark`() {
        MetadataTestFixtures.applyRaw(GenerationParameterOutboundContractTest().officialMetadata().toString())
        val provider = Provider(id = "anthropic-mark", kind = ProviderKind.Anthropic)
        val model = AIModel(id = GenerationParameterOutboundContractTest.OFFICIAL_MODEL, name = GenerationParameterOutboundContractTest.OFFICIAL_MODEL)
        val presentations = listOf("web", "reasoning").map { CapabilityControlPresentationResolver.presentation(provider, model, it) }
        assertEquals(
            ModelOptionsStatusMark.Official,
            ModelOptionsStatusMark.resolve(ModelOptionsPanelInput.connectionCategory(provider.kind), presentations),
        )
    }

    // -- connection facts to shape inputs --

    @Test
    fun `connection facts map to shape inputs without looking at names`() {
        assertEquals(ConnectionCategory.CustomLLM, ModelOptionsPanelInput.connectionCategory(ProviderKind.Relay))
        assertEquals(ConnectionCategory.Other, ModelOptionsPanelInput.connectionCategory(ProviderKind.OpenAI))
        fun relay(transport: RelayTransport?) = Provider(
            id = "r", kind = ProviderKind.Relay, baseUrlText = "http://127.0.0.1:8080/v1",
            relayRequested = transport?.let { RelayRequestedConfig(transport = it) },
        )
        assertTrue(ModelOptionsPanelInput.protocolUndecided(relay(RelayTransport.Auto)))
        assertTrue(ModelOptionsPanelInput.protocolUndecided(relay(null)))
        assertFalse(ModelOptionsPanelInput.protocolUndecided(relay(RelayTransport.OpenAIChatCompletions)))
        assertFalse(ModelOptionsPanelInput.protocolUndecided(Provider(id = "o", kind = ProviderKind.OpenAI)))
        assertEquals(CustomProtocol.ChatCompletions, ModelOptionsPanelInput.customProtocol(relay(RelayTransport.OpenAIChatCompletions)))
        assertEquals(CustomProtocol.Other, ModelOptionsPanelInput.customProtocol(relay(RelayTransport.AnthropicMessages)))
        assertNull(ModelOptionsPanelInput.customProtocol(Provider(id = "o", kind = ProviderKind.OpenAI)))
        ai.oriveo.community.core.model.CapabilityWebPreference.entries.forEach { preference ->
            val roundTrip = ModelOptionsPanelInput.webPreference(ModelOptionsPanelInput.webIntent(preference))
            val expected = if (preference == ai.oriveo.community.core.model.CapabilityWebPreference.Custom) {
                ai.oriveo.community.core.model.CapabilityWebPreference.Automatic
            } else {
                preference
            }
            assertEquals(expected, roundTrip)
        }
    }

    // -- shape to copy slots --

    @Test
    fun `shape semantics map to the registered copy`() {
        assertEquals(
            listOf(R.string.reasoning_auto, R.string.model_control_off, R.string.reasoning_fast, R.string.reasoning_balanced, R.string.reasoning_deep, R.string.reasoning_max),
            listOf("automatic", "off", "low", "balanced", "deep", "max").map(ModelOptionsRender::tierLabelRes),
        )
        assertEquals(R.string.model_control_reasoning_note_automatic, ModelOptionsRender.tierNoteRes("automatic"))
        assertEquals(R.string.model_control_reasoning_note_fast, ModelOptionsRender.tierNoteRes("low"))
        assertTrue(ModelOptionsRender.appendsHigherLevelsNote("balanced"))
        assertFalse(ModelOptionsRender.appendsHigherLevelsNote("automatic"))
        assertEquals(R.string.model_options_web_when_needed, ModelOptionsRender.timingLabelRes("automatic"))
        assertEquals(R.string.model_options_web_every_message, ModelOptionsRender.timingLabelRes("force"))
        assertEquals(
            R.string.model_options_template_thinking_note,
            ModelOptionsRender.toggleNoteRes(ModelOptionCapabilityShape.Capability.Reasoning, ModelOptionCapabilityShape.ToggleKind.ChatTemplateThinking),
        )
        assertEquals(
            R.string.model_options_web_note,
            ModelOptionsRender.toggleNoteRes(ModelOptionCapabilityShape.Capability.Web, ModelOptionCapabilityShape.ToggleKind.Capability),
        )
        assertEquals(R.string.model_options_see_adjustable_models, ModelOptionsRender.escapeRes(ModelOptionCapabilityShape.Escape.SupportedModels))
        assertEquals(R.string.model_options_open_additional_body, ModelOptionsRender.escapeRes(ModelOptionCapabilityShape.Escape.AdditionalBody))
        assertEquals(
            R.string.model_options_connection_cannot,
            ModelOptionsRender.disclosureRes(ModelOptionCapabilityShape.DisclosureStatus.ConnectionCannotSearch),
        )
        assertTrue(ModelOptionsRender.disclosureOffersSupportedModels(ModelOptionCapabilityShape.DisclosureStatus.ModelDoesNotThink))
        assertFalse(ModelOptionsRender.disclosureOffersSupportedModels(ModelOptionCapabilityShape.DisclosureStatus.ConnectionCannotSearch))
    }
}
