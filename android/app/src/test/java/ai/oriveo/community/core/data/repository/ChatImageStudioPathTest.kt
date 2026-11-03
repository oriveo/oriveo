package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.attachment.StoredImage
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.ProviderService
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import ai.oriveo.community.core.studio.ChatImageStudioRunner
import ai.oriveo.community.core.studio.ImageHttpRequest
import ai.oriveo.community.core.studio.ImageProfileResolver
import ai.oriveo.community.core.studio.ImageProfileSlice
import ai.oriveo.community.core.studio.StudioByokTransport
import ai.oriveo.community.core.studio.StudioImageResponse
import ai.oriveo.community.core.usage.BudgetAlertChecker
import ai.oriveo.community.core.usage.UsageReporter
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.util.Base64
import java.util.Collections
import javax.imageio.ImageIO
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Chat send path for studio image generation: a send the dispatch routes to studio is stored like the legacy
 * images path, a legacy-only model keeps the legacy request, and a cancelled studio send leaves the same state as
 * a cancelled legacy send with no attachments. Behavior follows chat_image_dispatch.v1.
 */
@RunWith(RobolectricTestRunner::class)
class ChatImageStudioPathTest {
    // Shared contract directory name, built at runtime so the source stays ASCII.
    private val sharedDir = String(charArrayOf(0x5171.toChar(), 0x4eab.toChar()))

    private val profiles: JsonObject by lazy {
        val path: Path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("$sharedDir/studio-contracts/chat_image_dispatch.v1.json") }
            .firstOrNull { Files.exists(it) }
            ?: error("chat_image_dispatch.v1.json not found")
        Json.parseToJsonElement(path.toFile().readText()).jsonObject.getValue("profiles").jsonObject
    }

    private val metadata = MetadataClient()

    private val resultPng: ByteArray by lazy {
        val image = BufferedImage(64, 64, BufferedImage.TYPE_INT_RGB)
        for (x in 0 until 64) for (y in 0 until 64) image.setRGB(x, y, 0x336699)
        val out = ByteArrayOutputStream()
        check(ImageIO.write(image, "png", out)) { "no png writer" }
        out.toByteArray()
    }

    private val resultBase64: String by lazy { Base64.getEncoder().encodeToString(resultPng) }

    /** A slice listing [modelId] under [serverKey] with profile [ref]; a null [ref] lists no models (no imageProfile). */
    private fun slice(serverKey: String, modelId: String, ref: String?): ImageProfileSlice = ImageProfileResolver.sliceOf(
        profiles = profiles,
        providers = if (ref == null) {
            emptyMap()
        } else {
            mapOf(serverKey to ImageProfileSlice.Provider(models = mapOf(modelId to ImageProfileSlice.ModelEntry(imageProfile = ref))))
        },
    )

    /** Fake studio transport answering an openai_images success; with [hang] set it signals and waits for cancellation. */
    private inner class FakeTransport(private val hang: CompletableDeferred<Unit>? = null) : StudioByokTransport {
        val sent: MutableList<ImageHttpRequest> = Collections.synchronizedList(mutableListOf())

        override suspend fun send(request: ImageHttpRequest, timeoutSeconds: Int, maxBodyBytes: Long): StudioByokTransport.SendOutcome {
            sent += request
            if (hang != null) {
                hang.complete(Unit)
                awaitCancellation()
            }
            return StudioByokTransport.SendOutcome.Response(200, """{"data":[{"b64_json":"$resultBase64"}]}""".toByteArray())
        }

        override suspend fun fetchImage(url: String): StudioImageResponse.Outcome =
            StudioImageResponse.Outcome.Ok(StudioImageResponse.DeliveredImage(resultPng, "image/png", 64, 64))
    }

    /** One chat repository wired with a real runner over [transport] and [slice]; the legacy service is a mock. */
    private inner class Harness(slice: ImageProfileSlice, val transport: FakeTransport = FakeTransport()) {
        val service = mockk<ProviderService>()
        val finalMessages = mutableListOf<ChatMessage>()
        val attachmentStore = mockk<AttachmentStore>(relaxed = true)
        private val conversationRepository = mockk<ConversationRepository>(relaxed = true)
        private val repository: ChatRepository

        init {
            coEvery { conversationRepository.updateMessage(any(), capture(finalMessages)) } returns Unit
            every { attachmentStore.saveOriginalImage(any(), any()) } answers { StoredImage(secondArg(), "image/png") }
            every { attachmentStore.loadThumbnailBase64(any()) } answers { "thumb-" + firstArg<String>() }
            val providerRepository = mockk<ProviderRepository>(relaxed = true)
            every { providerRepository.serviceFor(any<Provider>(), any()) } returns service
            repository = ChatRepository(
                conversationRepository = conversationRepository,
                providerRepository = providerRepository,
                usageReporter = mockk<UsageReporter>(relaxed = true),
                budgetAlertChecker = mockk<BudgetAlertChecker>(relaxed = true),
                attachmentStore = attachmentStore,
                chatImageStudioRunner = ChatImageStudioRunner(
                    transport = transport,
                    images = ChatImageStudioRunner.attachmentImages(attachmentStore),
                    profileSlice = { slice },
                    catalogKey = metadata::catalogKey,
                    pricing = { _, _ -> null },
                ),
            )
        }

        /** Legacy images path answer: one generated image as base64, empty text. */
        fun legacyAnswersWithImage() {
            coEvery { service.sendMessage(any(), any(), any(), any(), true, any(), any(), any()) } returns StreamEvent.Done(
                ProviderChatResult(
                    text = "",
                    attachments = listOf(
                        Attachment(
                            id = "legacy-out",
                            kind = AttachmentKind.Image,
                            fileName = "generated_image.png",
                            mimeType = "image/png",
                            base64Data = resultBase64,
                        ),
                    ),
                ),
            )
        }

        suspend fun send(provider: Provider, model: AIModel) {
            repository.sendMessage(
                conversation = Conversation(
                    id = "conv-1",
                    title = "Image",
                    providerID = provider.id,
                    providerKind = provider.kind,
                    modelID = model.id,
                ),
                text = "a red bicycle",
                provider = provider,
                modelID = model.id,
                existingMessages = emptyList(),
                outputs = ConversationStreamingOutputs(
                    streamingText = MutableStateFlow(""),
                    streamingMessageId = MutableStateFlow<String?>(null),
                ),
            )
        }
    }

    private fun imageModel(id: String) = AIModel(
        id = id,
        name = id,
        capabilities = listOf(ModelCapability.ImageGen),
        imageGenProfile = "images_api",
    )

    private fun provider(kind: ProviderKind, model: AIModel) = Provider(
        id = "p-${kind.rawValue}",
        kind = kind,
        status = ProviderConnectionState.Connected,
        apiKey = "sk-test",
        models = listOf(model),
    )

    private data class Stored(val kind: AttachmentKind, val mime: String, val hasThumbnail: Boolean, val hasLocalImage: Boolean)

    private fun stored(message: ChatMessage): List<Stored> = message.attachments.orEmpty().map {
        Stored(it.kind, it.mimeType, !it.thumbnailBase64.isNullOrEmpty(), !it.localImageId.isNullOrEmpty() && it.base64Data == null)
    }

    @Test
    fun persistsLikeLegacy() = runTest {
        val model = imageModel("gpt-image-1")
        val provider = provider(ProviderKind.OpenAI, model)

        val legacy = Harness(slice("openAI", model.id, ref = null))
        legacy.legacyAnswersWithImage()
        legacy.send(provider, model)

        val studio = Harness(slice("openAI", model.id, ref = "openai_images_square"))
        studio.send(provider, model)

        assertEquals("legacy run sends no studio request", 0, legacy.transport.sent.size)
        coVerify(exactly = 0) { studio.service.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
        assertEquals(
            "studio request goes to the official default base URL",
            listOf("https://api.openai.com/v1/images/generations"),
            studio.transport.sent.map { it.url },
        )
        val legacyMessage = legacy.finalMessages.last()
        val studioMessage = studio.finalMessages.last()
        assertEquals(ChatMessageState.Delivered, legacyMessage.state)
        assertEquals(legacyMessage.state, studioMessage.state)
        assertEquals(legacyMessage.text, studioMessage.text)
        assertEquals(1, stored(legacyMessage).size)
        assertTrue(stored(legacyMessage).all { it.hasThumbnail && it.hasLocalImage })
        assertEquals(stored(legacyMessage), stored(studioMessage))
        assertEquals(legacyMessage.stopReason, studioMessage.stopReason)
    }

    @Test
    fun legacyOnlyStaysLegacy() = runTest {
        val model = imageModel("qwen-image-plus")
        val provider = provider(ProviderKind.Qwen, model)
        // legacy_only_no_profile: the published profiles carry no entry for this model.
        val harness = Harness(slice("qwen", "another-model", ref = "dashscope_square"))
        harness.legacyAnswersWithImage()

        harness.send(provider, model)

        assertEquals(0, harness.transport.sent.size)
        coVerify(exactly = 1) { harness.service.sendMessage(any(), any(), any(), any(), true, any(), any(), any()) }
        val message = harness.finalMessages.last()
        assertEquals(ChatMessageState.Delivered, message.state)
        assertEquals(listOf(AttachmentKind.Image), message.attachments.orEmpty().map { it.kind })
    }

    @Test
    fun cancelLeavesNoAttachments() = runTest {
        val model = imageModel("gpt-image-1")
        val provider = provider(ProviderKind.OpenAI, model)

        val legacyEntered = CompletableDeferred<Unit>()
        val legacy = Harness(slice("openAI", model.id, ref = null))
        coEvery { legacy.service.sendMessage(any(), any(), any(), any(), true, any(), any(), any()) } coAnswers {
            legacyEntered.complete(Unit)
            awaitCancellation()
        }
        val legacyJob = launch { legacy.send(provider, model) }
        legacyEntered.await()
        legacyJob.cancelAndJoin()

        val studioEntered = CompletableDeferred<Unit>()
        val studio = Harness(slice("openAI", model.id, ref = "openai_images_square"), FakeTransport(hang = studioEntered))
        val studioJob = launch { studio.send(provider, model) }
        studioEntered.await()
        studioJob.cancelAndJoin()

        assertEquals(1, studio.transport.sent.size)
        coVerify(exactly = 0) { studio.service.sendMessage(any(), any(), any(), any(), any(), any(), any(), any()) }
        verify(exactly = 0) { studio.attachmentStore.saveOriginalImage(any(), any()) }
        val legacyMessage = legacy.finalMessages.last()
        val studioMessage = studio.finalMessages.last()
        assertEquals(ChatMessageState.Interrupted, legacyMessage.state)
        assertEquals(legacyMessage.state, studioMessage.state)
        assertEquals(legacyMessage.stopReason, studioMessage.stopReason)
        assertTrue(studioMessage.attachments.isNullOrEmpty())
        assertTrue(legacyMessage.attachments.isNullOrEmpty())
    }
}
