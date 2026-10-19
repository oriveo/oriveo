package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.context.ContinuationInstructionsMode
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.provider.applyCapabilityRuntimeRecipes
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.feature.chat.ContextConfirmAttempt
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Stateful Responses continuation decides the wire format from the recipe continuationInstructionsMode and the ContextContinuation verdict. */
class ContextPipelineStatefulTest {

    private val model = "gpt-5.6-terra"
    private val recipeRef = "openai.responses.web.v1"

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    /** Sets the web recipe continuationInstructionsMode in the shared registry to the given value (null = remove the field). */
    private fun applyRuntime(mode: String?) {
        val root = File(System.getProperty("user.dir")).absoluteFile.parentFile!!.parentFile!!
        val execution = Json.parseToJsonElement(
            File(root, "shared/model-contracts/provider_recipe_execution.v1.json").readText(),
        ).jsonObject
        val registry = Json.parseToJsonElement(
            File(root, execution["registryPath"]!!.jsonPrimitive.content).readText(),
        ).jsonObject
        val recipes = registry["recipes"]!!.jsonObject
        val recipe = recipes[recipeRef]!!.jsonObject.toMutableMap().apply {
            remove("continuationInstructionsMode")
            mode?.let { put("continuationInstructionsMode", JsonPrimitive(it)) }
        }
        val runtime = JsonObject(registry + mapOf(
            "recipes" to JsonObject(recipes + (recipeRef to JsonObject(recipe))),
            "revision" to JsonPrimitive("sha256:stateful"),
            "generatedAt" to JsonPrimitive("2026-10-15T00:00:00Z"),
        ))
        MetadataTestFixtures.applyRaw(buildJsonObject {
            put("version", 1); put("capabilityRuntime", runtime)
            put("providers", buildJsonObject { put("openAI", buildJsonObject {
                put("resolveMap", buildJsonObject { put(model, model) })
                put("models", buildJsonObject { put(model, buildJsonObject {
                    put("transport", "openai_responses")
                    put("capabilityControls", buildJsonObject { put("web", buildJsonObject {
                        put("state", "auto_available"); put("recipeRef", recipeRef)
                    }) })
                }) })
            }) })
        }.toString())
    }

    private val chatBody = """{"model":"gpt-5.6-terra","stream":true,"instructions":"SYS","input":[""" +
        """{"role":"user","content":"q"},{"role":"assistant","content":"a"},{"role":"user","content":"continue"}]}"""

    private fun continueBody(mode: String?, fingerprintMatches: Boolean?): JsonObject {
        applyRuntime(mode)
        val base = ChatRequestOptions(
            localContinuationState = JsonObject(mapOf("previousResponseId" to JsonPrimitive("resp-1"))),
            localContinuationExplicit = true,
        )
        val options = fingerprintMatches?.let { base.copy(localContinuationFingerprintMatches = it) } ?: base
        val body = applyCapabilityRuntimeRecipes(
            bodyJson = chatBody, providerKind = ProviderKind.OpenAI, modelID = model,
            finalTransport = "openai_responses", webRequested = true,
            reasoningMode = ReasoningMode.Automatic, requestOptions = options,
        ).body
        return Json.parseToJsonElement(body).jsonObject
    }

    @Test fun `resend chains on previous response and keeps instructions`() {
        val body = continueBody("resend", fingerprintMatches = true)
        assertEquals("resp-1", body["previous_response_id"]?.jsonPrimitive?.content)
        assertEquals("SYS", body["instructions"]?.jsonPrimitive?.content)
        assertEquals(1, body["input"]!!.jsonArray.size)
    }

    @Test fun `omit chains on previous response without instructions`() {
        val body = continueBody("omit", fingerprintMatches = true)
        assertEquals("resp-1", body["previous_response_id"]?.jsonPrimitive?.content)
        assertFalse("instructions" in body)
        assertEquals(1, body["input"]!!.jsonArray.size)
    }

    @Test fun `missing mode sends the full plan`() {
        val body = continueBody(null, fingerprintMatches = true)
        assertNull(body["previous_response_id"])
        assertEquals("SYS", body["instructions"]?.jsonPrimitive?.content)
        assertEquals(3, body["input"]!!.jsonArray.size)
    }

    @Test fun `unknown mode counts as missing`() {
        val body = continueBody("sometimes", fingerprintMatches = true)
        assertNull(body["previous_response_id"])
        assertEquals(3, body["input"]!!.jsonArray.size)
    }

    @Test fun `fingerprint mismatch or absent sends the full plan`() {
        listOf(false, null).forEach { matches ->
            val body = continueBody("resend", fingerprintMatches = matches)
            assertNull("matches=$matches", body["previous_response_id"])
            assertEquals("SYS", body["instructions"]?.jsonPrimitive?.content)
            assertEquals(3, body["input"]!!.jsonArray.size)
        }
    }

    /** Sends through ChatRepository reusing an existing assistant slot; returns the options handed to the provider. */
    private fun sendReusingAssistant(attemptKind: ContextConfirmAttempt): ChatRequestOptions = kotlinx.coroutines.runBlocking {
        val chatModel = AIModel(id = "gpt-4o", name = "GPT-4o", contextLength = 128_000, maxOutputTokens = 16_384)
        val provider = Provider(id = "openai-1", kind = ProviderKind.OpenAI, apiKey = "key", models = listOf(chatModel))
        val service = mockk<ProviderService>()
        val options = slot<ChatRequestOptions>()
        every {
            service.sendMessageStream(any(), any(), any(), any(), any(), any(), any(), capture(options))
        } returns flowOf(StreamEvent.Delta("ok"), StreamEvent.Done(ProviderChatResult(text = "ok")))
        val providerRepository = mockk<ProviderRepository>(relaxed = true)
        every { providerRepository.serviceFor(any<Provider>(), any()) } returns service
        val repository = ChatRepository(
            conversationRepository = mockk<ConversationRepository>(relaxed = true),
            providerRepository = providerRepository,
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        val conversation = Conversation(
            id = "conversation-1", title = "Chat", providerID = provider.id,
            providerKind = provider.kind, modelID = chatModel.id,
        )
        val user = ChatMessage(
            id = "u-1", role = ChatRole.User, text = "q", providerKind = ProviderKind.OpenAI,
            providerName = "OpenAI", modelName = "GPT", state = ChatMessageState.Delivered,
        )
        val assistant = user.copy(id = "a-1", role = ChatRole.Assistant, text = "a")
        // Same shape as the production entry: continue sends the continuation sentence (not in history); regenerate / retry reuse the user already in history.
        val continues = attemptKind == ContextConfirmAttempt.CONTINUE
        repository.sendMessage(
            conversation = conversation,
            text = if (continues) ai.oriveo.community.core.context.ContextAssembler.CONTINUE_PROMPT else "q",
            provider = provider,
            modelID = chatModel.id,
            existingMessages = listOf(user, assistant),
            outputs = ConversationStreamingOutputs(
                streamingText = MutableStateFlow(""),
                streamingMessageId = MutableStateFlow(null),
            ),
            persistUserMessage = false,
            userMessageAlreadyInHistory = !continues,
            appendToAssistant = assistant,
            attemptKind = attemptKind,
        )
        options.captured
    }

    /** Contract §7: stateful continuation is only for explicit continue and the next tool-loop leg. */
    @Test fun regenerate_never_stateful() {
        val options = sendReusingAssistant(ContextConfirmAttempt.REGENERATE)
        assertFalse(options.localContinuationExplicit)
        assertNull(options.localContinuationState)
    }

    @Test fun retry_never_stateful() {
        val options = sendReusingAssistant(ContextConfirmAttempt.RETRY)
        assertFalse(options.localContinuationExplicit)
        assertNull(options.localContinuationState)
    }

    @Test fun explicit_continue_is_judged_for_stateful() {
        assertTrue(sendReusingAssistant(ContextConfirmAttempt.CONTINUE).localContinuationExplicit)
    }
}
