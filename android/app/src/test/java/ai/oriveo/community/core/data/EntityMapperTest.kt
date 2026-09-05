package ai.oriveo.community.core.data

import ai.oriveo.community.core.data.entity.ConversationEntity
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayImageConfig
import ai.oriveo.community.core.model.RelayImageMode
import ai.oriveo.community.core.model.RelayImageOutputFormat
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayReasoningEffort
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EntityMapperTest {

    
    private inline fun <T> mapper(block: EntityMapper.() -> T): T =
        with(EntityMapper) { block() }

    // ── Provider round-trip ──────────────────────────────────────

    @Test
    fun `Provider to entity and back preserves all fields`() = mapper {
        val original = Provider(
            id = "p1",
            kind = ProviderKind.Anthropic,
            status = ProviderConnectionState.Connected,
            models = listOf(
                AIModel(
                    id = "m1", name = "Claude 3",
                    capabilities = listOf(ModelCapability.Reasoning, ModelCapability.Text),
                ),
            ),
            catalogModels = emptyList(),
            lastCheckedAt = 1700000000000L,
            apiKey = "secret-key",
            apiKeyPreview = "sk-ant-...xyz",
            lastError = null,
            baseUrlText = "api.anthropic.com",
            customName = null,
            updatedAt = 1700000001000L,
        )

        val entity = original.toEntity()
        val restored = entity.toDomain(apiKey = "secret-key")

        assertEquals(original.id, restored.id)
        assertEquals(original.kind, restored.kind)
        assertEquals(original.status, restored.status)
        assertEquals(original.models.size, restored.models.size)
        assertEquals(original.models[0].id, restored.models[0].id)
        assertEquals(original.models[0].capabilities, restored.models[0].capabilities)
        assertEquals(original.lastCheckedAt, restored.lastCheckedAt)
        assertEquals(original.apiKeyPreview, restored.apiKeyPreview)
        assertNull(restored.lastError)
        assertEquals(original.baseUrlText, restored.baseUrlText)
        assertEquals(original.updatedAt, restored.updatedAt)
    }

    @Test
    fun `Provider entity does not store apiKey`() = mapper {
        val provider = Provider(id = "p1", kind = ProviderKind.OpenAI, apiKey = "secret")
        val entity = provider.toEntity()
        val restored = entity.toDomain()
        assertEquals("", restored.apiKey)
    }

    @Test
    fun `Provider with Issue status round-trips`() = mapper {
        val provider = Provider(
            id = "p1", kind = ProviderKind.Gemini,
            status = ProviderConnectionState.Issue("rate limited"),
        )
        val entity = provider.toEntity()
        val restored = entity.toDomain()
        assertTrue(restored.status is ProviderConnectionState.Issue)
        assertEquals("rate limited", (restored.status as ProviderConnectionState.Issue).message)
    }

    @Test
    fun `Provider updatedAt field maps correctly`() = mapper {
        val ts = 1700000000000L
        val provider = Provider(id = "p1", kind = ProviderKind.OpenAI, updatedAt = ts)
        val entity = provider.toEntity()
        assertEquals(ts, entity.updatedAt)
        val restored = entity.toDomain()
        assertEquals(ts, restored.updatedAt)
    }

    @Test
    fun `Relay Provider round-trips structured relay configs`() = mapper {
        val original = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            models = listOf(AIModel(id = "gpt-5.4", name = "GPT-5.4", isDefault = true)),
            catalogModels = listOf(AIModel(id = "gpt-5.4", name = "GPT-5.4", isDefault = true)),
            apiKey = "relay-secret",
            apiKeyPreview = "rk-***1234",
            baseUrlText = "https://relay.example.com/v1",
            customName = "Codex Relay",
            relayKind = ai.oriveo.community.core.model.RelayKind.CodexStyle,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIResponses,
                authMode = RelayAuthMode.Bearer,
                modelID = "gpt-5.4",
                reasoningEffort = RelayReasoningEffort.XHigh,
                serviceTier = "fast",
                stream = true,
                disableResponseStorage = true,
                headers = listOf(RelayKeyValue("x-trace-id", "relay-1")),
                queryParams = listOf(RelayKeyValue("region", "us")),
                codexCompatIdentity = false,
                customUserAgent = "Custom UA",
            ),
            relayImage = RelayImageConfig(
                enabled = true,
                mode = RelayImageMode.ToolModel,
                toolModelID = "gpt-image-2",
                outputFormat = RelayImageOutputFormat.Png,
            ),
            updatedAt = 1700000001000L,
        )

        val entity = original.toEntity()
        val restored = entity.toDomain(apiKey = "relay-secret")

        assertEquals(original.relayKind, restored.relayKind)
        assertEquals(original.relayRequested, restored.relayRequested)
        assertEquals(original.relayImage, restored.relayImage)
    }

    // ── Conversation round-trip ──────────────────────────────────

    @Test
    fun `Conversation to entity and back preserves all fields`() = mapper {
        val createdTs = 1700000000000L
        val updatedTs = 1700000001000L
        val original = Conversation(
            id = "c1",
            title = "Test Chat",
            hasCustomTitle = true,
            providerID = "p1",
            providerKind = ProviderKind.OpenAI,
            modelID = "m1",
            previewText = "Hello there",
            estimatedCost = 0.05,
            isDraft = false,
            draftText = "draft content",
            createdAt = createdTs,
            updatedAt = updatedTs,
        )

        val entity = original.toEntity()
        val restored = entity.toDomain()

        assertEquals(original.id, restored.id)
        assertEquals(original.title, restored.title)
        assertEquals(original.hasCustomTitle, restored.hasCustomTitle)
        assertEquals(original.providerID, restored.providerID)
        assertEquals(original.modelID, restored.modelID)
        assertEquals(original.previewText, restored.previewText)
        assertEquals(original.estimatedCost, restored.estimatedCost, 0.001)
        assertEquals(original.isDraft, restored.isDraft)
        assertEquals(original.draftText, restored.draftText)
        assertEquals(original.createdAt, restored.createdAt)
        assertEquals(original.updatedAt, restored.updatedAt)
    }

    @Test
    fun `Conversation entity preserves createdAt`() = mapper {
        val ts = 1700000000000L
        val conv = Conversation(
            id = "c1", title = "Test", providerID = "p1", modelID = "m1",
            providerKind = ProviderKind.OpenAI,
            createdAt = ts,
        )
        val entity = conv.toEntity()
        assertEquals(ts, entity.createdAt)
    }

    @Test
    fun `Conversation with folderID round-trips correctly`() = mapper {
        val conv = Conversation(
            id = "c1", title = "Test", providerID = "p1", modelID = "m1",
            providerKind = ProviderKind.OpenAI,
            folderID = "f1",
        )
        val entity = conv.toEntity()
        val restored = entity.toDomain()
        assertEquals("f1", restored.folderID)
    }

    // ── Folder round-trip ──────────────────────────────────

    @Test
    fun `Folder to entity and back preserves all fields`() = mapper {
        val original = ai.oriveo.community.core.model.Folder(
            id = "f1",
            name = "Work",
            sortOrder = 1000,
            createdAt = 100L,
            updatedAt = 200L,
        )
        val entity = original.toEntity()
        val restored = entity.toDomain()

        assertEquals(original.id, restored.id)
        assertEquals(original.name, restored.name)
        assertEquals(original.sortOrder, restored.sortOrder)
        assertEquals(original.createdAt, restored.createdAt)
        assertEquals(original.updatedAt, restored.updatedAt)
    }

    @Test
    fun `Conversation toDomain with messages includes them`() = mapper {
        val entity = ConversationEntity(
            id = "c1", title = "Test", hasCustomTitle = false,
            providerID = "p1", modelID = "m1",
            providerKind = ProviderKind.OpenAI.name,
            previewText = "", estimatedCost = 0.0,
            isDraft = false, draftText = "",
            createdAt = 0L, updatedAt = 0L,
        )
        val messages = listOf(
            ChatMessage(
                id = "msg1", role = ChatRole.User, text = "Hello",
                providerKind = ProviderKind.OpenAI, providerName = "OpenAI",
                modelName = "gpt-4", state = ChatMessageState.Delivered,
            ),
        )
        val conv = entity.toDomain(messages)
        assertEquals(1, conv.messages.size)
        assertEquals("msg1", conv.messages[0].id)
    }

    // ── Message round-trip ───────────────────────────────────────

    @Test
    fun `ChatMessage to entity and back preserves all fields`() = mapper {
        val original = ChatMessage(
            id = "msg1",
            role = ChatRole.Assistant,
            text = "Hello, I'm Claude.",
            providerID = "123e4567-e89b-12d3-a456-426614174000",
            providerKind = ProviderKind.Anthropic,
            providerName = "Anthropic",
            modelID = "openai/gpt-5.4-nano",
            modelName = "claude-3-opus",
            servedModelID = "openai/gpt-5.4-nano-2026-03-01",
            estimatedCost = 0.003,
            state = ChatMessageState.Delivered,
            errorTitle = null,
            errorDetail = null,
            attachments = null,
            createdAt = 1700000000000L,
        )

        val entity = original.toEntity("guest", "c1", sortOrder = 0)
        val restored = entity.toDomain()

        assertEquals(original.id, restored.id)
        assertEquals(original.role, restored.role)
        assertEquals(original.text, restored.text)
        assertEquals(original.providerID?.uppercase(), restored.providerID)
        assertEquals(original.providerKind, restored.providerKind)
        assertEquals(original.providerName, restored.providerName)
        assertEquals(original.modelID, restored.modelID)
        assertEquals(original.modelName, restored.modelName)
        assertEquals(original.servedModelID, restored.servedModelID)
        assertEquals(original.estimatedCost, restored.estimatedCost, 0.0001)
        assertEquals(original.state, restored.state)
        assertNull(restored.errorTitle)
        assertNull(restored.attachments)
    }

    @Test
    fun `ChatMessage with attachments round-trips`() = mapper {
        val attachment = Attachment(
            id = "att1",
            kind = AttachmentKind.Image,
            fileName = "photo.jpg",
            mimeType = "image/jpeg",
            localImageId = "local-123",
            thumbnailBase64 = "dGh1bWJuYWls",
        )
        val msg = ChatMessage(
            id = "msg1", role = ChatRole.User, text = "Look at this",
            providerKind = ProviderKind.OpenAI, providerName = "OpenAI",
            modelName = "gpt-4o", state = ChatMessageState.Delivered,
            attachments = listOf(attachment),
        )

        val entity = msg.toEntity("guest", "c1", sortOrder = 1)
        val restored = entity.toDomain()

        assertEquals(1, restored.attachments?.size)
        val restoredAtt = restored.attachments!![0]
        assertEquals("att1", restoredAtt.id)
        assertEquals(AttachmentKind.Image, restoredAtt.kind)
        assertEquals("photo.jpg", restoredAtt.fileName)
        assertEquals("local-123", restoredAtt.localImageId)
    }

    @Test
    fun `ChatMessage with attachments new rawContentRef field round-trips`() = mapper {
        
        val attachment = Attachment(
            id = "att1",
            kind = AttachmentKind.Video,
            fileName = "clip.mp4",
            mimeType = "video/mp4",
            rawContentRef = "blob-abc",
        )
        val msg = ChatMessage(
            id = "msg1", role = ChatRole.User, text = "Watch this",
            providerKind = ProviderKind.OpenAI, providerName = "OpenAI",
            modelName = "gpt-4o", state = ChatMessageState.Delivered,
            attachments = listOf(attachment),
        )

        val entity = msg.toEntity("guest", "c1", sortOrder = 1)
        val restored = entity.toDomain()

        assertEquals(1, restored.attachments?.size)
        val restoredAtt = restored.attachments!![0]
        assertEquals(AttachmentKind.Video, restoredAtt.kind)
        assertEquals("blob-abc", restoredAtt.rawContentRef)
        assertNull(restoredAtt.base64Data)
    }

    @Test
    fun `malformed attachmentsJson degrades to null attachments instead of throwing`() = mapper {
        
        
        val entity = ai.oriveo.community.core.data.entity.MessageEntity(
            id = "msg1",
            conversationId = "c1",
            role = ChatRole.User.name,
            text = "hello",
            providerKind = ProviderKind.OpenAI.name,
            providerName = "OpenAI",
            modelName = "gpt-4o",
            estimatedCost = 0.0,
            state = ChatMessageState.Delivered.name,
            errorTitle = null,
            errorDetail = null,
            attachmentsJson = "{this is not valid attachments json",
            createdAt = null,
            sortOrder = 0,
        )

        val restored = entity.toDomain()

        assertNull(restored.attachments)
        assertEquals("hello", restored.text)
    }

    @Test
    fun `quote context round-trips through production entity mapper`() = mapper {
        val quote = ai.oriveo.community.core.model.QuoteContext(
            sourceMessageId = "source-1",
            sourceRole = ChatRole.Assistant,
            contentKind = ai.oriveo.community.core.model.QuoteContentKind.Code,
            leadingText = "val ",
            selectedText = "answer",
            trailingText = " = 42",
            contextTruncated = false,
        )
        val message = ChatMessage(
            id = "message-1", role = ChatRole.User, text = "Explain",
            providerKind = ProviderKind.OpenAI, providerName = "OpenAI",
            modelName = "gpt", state = ChatMessageState.Delivered, quoteContext = quote,
        )

        val entity = message.toEntity("guest", "conversation-1", 0)
        val restored = entity.toDomain()

        assertEquals(quote, restored.quoteContext)
    }

    @Test
    fun `malformed quote json is dropped without dropping message`() = mapper {
        val entity = ai.oriveo.community.core.data.entity.MessageEntity(
            id = "message-1", conversationId = "conversation-1", role = ChatRole.User.name,
            text = "hello", providerKind = ProviderKind.OpenAI.name, providerName = "OpenAI",
            modelName = "gpt", estimatedCost = 0.0, state = ChatMessageState.Delivered.name,
            errorTitle = null, errorDetail = null, attachmentsJson = null,
            quoteContextJson = "{broken", createdAt = null, sortOrder = 0,
        )

        val restored = entity.toDomain()

        assertNull(restored.quoteContext)
        assertEquals("hello", restored.text)
    }

    @Test
    fun `ChatMessage with failed state preserves error info`() = mapper {
        val msg = ChatMessage(
            id = "msg1", role = ChatRole.Assistant, text = "",
            providerKind = ProviderKind.Gemini, providerName = "Gemini",
            modelName = "gemini-pro", state = ChatMessageState.Failed,
            errorTitle = "Rate Limited",
            errorDetail = "HTTP 429: Too many requests",
        )

        val entity = msg.toEntity("guest", "c1", sortOrder = 0)
        val restored = entity.toDomain()

        assertEquals(ChatMessageState.Failed, restored.state)
        assertEquals("Rate Limited", restored.errorTitle)
        assertEquals("HTTP 429: Too many requests", restored.errorDetail)
    }

    @Test
    fun `ChatMessage entity stores conversationId and sortOrder`() = mapper {
        val msg = ChatMessage(
            id = "msg1", role = ChatRole.User, text = "Hi",
            providerKind = ProviderKind.OpenAI, providerName = "OpenAI",
            modelName = "gpt-4", state = ChatMessageState.Delivered,
        )
        val entity = msg.toEntity("guest", "conv-123", sortOrder = 5)
        assertEquals("conv-123", entity.conversationId)
        assertEquals(5, entity.sortOrder)
    }

    // ── Boundary conditions ──────────────────────────────────────

    @Test
    fun `Provider with empty models list round-trips`() = mapper {
        val provider = Provider(id = "p1", kind = ProviderKind.Relay, models = emptyList())
        val entity = provider.toEntity()
        val restored = entity.toDomain()
        assertTrue(restored.models.isEmpty())
        assertTrue(restored.catalogModels.isEmpty())
    }

    @Test
    fun `ChatMessage with empty text round-trips`() = mapper {
        val msg = ChatMessage(
            id = "msg1", role = ChatRole.Assistant, text = "",
            providerKind = ProviderKind.OpenAI, providerName = "OpenAI",
            modelName = "gpt-4", state = ChatMessageState.Generating,
        )
        val entity = msg.toEntity("guest", "c1", sortOrder = 0)
        val restored = entity.toDomain()
        assertEquals("", restored.text)
        assertEquals(ChatMessageState.Generating, restored.state)
    }

    

    @Test
    fun `ChatMessage with reasoning round-trips`() = mapper {
        val msg = ChatMessage(
            id = "msg1", role = ChatRole.Assistant, text = "Final answer",
            providerKind = ProviderKind.Anthropic, providerName = "Anthropic",
            modelName = "claude-3-opus", state = ChatMessageState.Delivered,
            reasoningText = "Let me think step by step about the question...",
            reasoningDurationMs = 5000L,
        )
        val entity = msg.toEntity("guest", "c1", sortOrder = 0)
        
        assertEquals("Let me think step by step about the question...", entity.reasoningText)
        assertEquals(5000L, entity.reasoningDurationMs)

        val restored = entity.toDomain()
        assertEquals("Let me think step by step about the question...", restored.reasoningText)
        assertEquals(5000L, restored.reasoningDurationMs)
        assertEquals("Final answer", restored.text)
    }

    @Test
    fun `ChatMessage with null reasoning round-trips as null`() = mapper {
        val msg = ChatMessage(
            id = "msg1", role = ChatRole.Assistant, text = "Just answer",
            providerKind = ProviderKind.OpenAI, providerName = "OpenAI",
            modelName = "gpt-4", state = ChatMessageState.Delivered,
            reasoningText = null,
            reasoningDurationMs = null,
        )
        val entity = msg.toEntity("guest", "c1", sortOrder = 0)
        assertNull(entity.reasoningText)
        assertNull(entity.reasoningDurationMs)

        val restored = entity.toDomain()
        assertNull(restored.reasoningText)
        assertNull(restored.reasoningDurationMs)
    }

    @Test
    fun `ChatMessage with blank reasoning normalizes to null on toEntity`() = mapper {
        
        val msg = ChatMessage(
            id = "msg1", role = ChatRole.Assistant, text = "Ans",
            providerKind = ProviderKind.OpenAI, providerName = "OpenAI",
            modelName = "gpt-4", state = ChatMessageState.Delivered,
            reasoningText = "   ",
            reasoningDurationMs = null,
        )
        val entity = msg.toEntity("guest", "c1", sortOrder = 0)
        assertNull(entity.reasoningText)

        val restored = entity.toDomain()
        assertNull(restored.reasoningText)
    }
}
