package ai.oriveo.community.feature.chat

import ai.oriveo.community.R
import ai.oriveo.community.core.capability.InputNegativeCache
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.feature.chat.components.RelayBubbleIdentity
import ai.oriveo.community.feature.chat.components.userAttachmentNotSentMarks
import java.io.File
import java.util.zip.GZIPInputStream
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The user bubble "not sent to this model" mark: only attachments that the target model cannot receive and that the
 * outbound request replaces with a placeholder are marked; the local message is never modified.
 * The verdict comes from the real deepseek entry of the bundled snapshot bundled-metadata.v2, injected into a separate
 * MetadataClient through the production decode / publish boundary.
 */
class MessageBubbleNotSentMarkTest {
    private val provider = Provider(id = "official-deepseek", kind = ProviderKind.DeepSeek)
    private val image = Attachment(id = "img-1", kind = AttachmentKind.Image, fileName = "a.png", mimeType = "image/png", base64Data = "AAAA")

    @Test
    fun `deepseek v4 pro user image is marked not sent to this model`() {
        val message = userMessage("deepseek-v4-pro")
        val marks = userAttachmentNotSentMarks(message, provider, deepseekClient(), memoryCache())
        assertEquals(mapOf("img-1" to R.string.capability_input_bubble_not_sent_to_model), marks)
        // Read-only projection: the local message is untouched.
        assertEquals(listOf(image), message.attachments)
        assertEquals("look", message.text)
    }

    @Test
    fun `deepseek flash user image is not marked`() {
        val marks = userAttachmentNotSentMarks(userMessage("deepseek-flash"), provider, deepseekClient(), memoryCache())
        assertTrue(marks.toString(), marks.isEmpty())
    }

    @Test
    fun `deepseek model missing from the catalog is unknown and its user image is not marked`() {
        val marks = userAttachmentNotSentMarks(userMessage("deepseek-unlisted"), provider, deepseekClient(), memoryCache())
        assertTrue(marks.toString(), marks.isEmpty())
    }

    @After
    fun tearDown() = MetadataTestFixtures.clear()

    @Test
    fun `relay session user image is marked when the envelope rejects images`() {
        relayEnvelope(image = false)
        val message = relayMessage()
        val marks = userAttachmentNotSentMarks(message, relayProvider, negativeCache = memoryCache(), relayLocalIdentity = RelayBubbleIdentity.Resolved(relayIdentity()))
        assertEquals(mapOf("img-1" to R.string.capability_input_bubble_not_sent_to_model), marks)
        assertEquals(listOf(image), message.attachments)
    }

    @Test
    fun `relay session user image with unknown vision is not marked`() {
        relayEnvelope(image = true)
        val marks = userAttachmentNotSentMarks(relayMessage(), relayProvider, negativeCache = memoryCache(), relayLocalIdentity = RelayBubbleIdentity.Resolved(relayIdentity()))
        assertTrue(marks.toString(), marks.isEmpty())
    }

    @Test
    fun `relay session user image without input identity is marked`() {
        // When outbound cannot obtain an identity the three-key hard block writes the placeholder; the bubble marks it the same way.
        relayEnvelope(image = true)
        val message = relayMessage()
        val marks = userAttachmentNotSentMarks(message, relayProvider, negativeCache = memoryCache(), relayLocalIdentity = RelayBubbleIdentity.Resolved(null))
        assertEquals(mapOf("img-1" to R.string.capability_input_bubble_not_sent_to_model), marks)
        assertEquals(listOf(image), message.attachments)
    }

    @Test
    fun `relay session user image is not marked while identity is loading`() {
        relayEnvelope(image = true)
        val marks = userAttachmentNotSentMarks(relayMessage(), relayProvider, negativeCache = memoryCache(), relayLocalIdentity = RelayBubbleIdentity.Loading)
        assertTrue(marks.toString(), marks.isEmpty())
    }

    @Test
    fun `assistant messages are never marked`() {
        val message = userMessage("deepseek-v4-pro").copy(role = ChatRole.Assistant)
        assertTrue(userAttachmentNotSentMarks(message, provider, deepseekClient(), memoryCache()).isEmpty())
    }

    private fun userMessage(modelId: String) = ChatMessage(
        id = "u-1",
        role = ChatRole.User,
        text = "look",
        providerID = provider.id,
        providerKind = ProviderKind.DeepSeek,
        providerName = "DeepSeek",
        modelID = modelId,
        modelName = modelId,
        state = ChatMessageState.Delivered,
        attachments = listOf(image),
    )

    private val relayModel = AIModel(
        id = "relay-model",
        name = "Relay Model",
        capabilities = listOf(ModelCapability.Text),
        relayTransport = RelayTransport.OpenAIChatCompletions,
    )
    private val relayProvider = Provider(
        id = "relay-bubble",
        kind = ProviderKind.Relay,
        status = ProviderConnectionState.Connected,
        apiKey = "relay-key",
        baseUrlText = "https://relay.test/v1",
        relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
        models = listOf(relayModel),
    )

    private fun relayMessage() = userMessage(relayModel.id).copy(providerID = relayProvider.id, providerKind = ProviderKind.Relay, providerName = "Relay")

    private fun relayIdentity() = CapabilityEvidenceIdentity(
        partitionId = "u1",
        connectionInstanceId = relayProvider.id,
        connectionGeneration = "generation",
        credentialEpoch = "epoch",
        providerKind = relayProvider.kind.rawValue,
        authMode = relayProvider.authMode.rawValue,
    )

    private fun relayEnvelope(image: Boolean) = MetadataTestFixtures.applyRaw(
        """{"version":1,"providers":{},"relayRuntimeConfig":{"transportEnvelopes":""" +
            """{"openai_chat_completions":{"image":$image,"textFileInline":true}}}}""",
    )

    private fun memoryCache() = InputNegativeCache(InputNegativeCache.MemoryStore())

    private fun deepseekClient(): MetadataClient {
        val entry = bundledPayload().getValue("providers").jsonObject.getValue("deepseek").jsonObject
        val payload = buildJsonObject {
            put("version", 1)
            put("contractVersion", 1)
            put("providers", buildJsonObject { put("deepseek", entry) })
        }
        return MetadataClient().apply { loadNetworkPayloadForTesting(payload.toString(), "\"bubble-not-sent-mark\"") }
    }

    private fun bundledPayload(): JsonObject {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "shared/model-contracts/bundled-metadata.v2.json.gz")
            if (candidate.exists()) {
                val text = GZIPInputStream(candidate.inputStream()).bufferedReader().use { it.readText() }
                return Json.parseToJsonElement(text).jsonObject
            }
            dir = dir.parentFile
        }
        throw IllegalStateException("bundled-metadata.v2.json.gz not found")
    }
}
