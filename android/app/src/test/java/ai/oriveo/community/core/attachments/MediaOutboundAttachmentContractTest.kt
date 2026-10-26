package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.capability.truth.resolveInputCapabilityProjections
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.CapabilityEvidenceProductionAdapter
import ai.oriveo.community.core.provider.DeepSeekService
import ai.oriveo.community.core.provider.MessageBuilder
import ai.oriveo.community.core.provider.MetadataTestFixtures
import ai.oriveo.community.core.provider.MiniMaxService
import ai.oriveo.community.core.provider.ProviderTestFixtures
import ai.oriveo.community.core.provider.messagesForCapabilityProjection
import ai.oriveo.community.core.provider.videoPlaceholder
import ai.oriveo.community.core.provider.withInputOutbound
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.headersOf
import java.io.File
import java.util.Base64
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Shared fixture `shared/test-fixtures/attachments/media-outbound.v1.json`:
 * - videoPlaceholderCases: a route that cannot send videos writes one placeholder line per video (the route's image placeholder with Image replaced by Video, without the file name),
 *   and the request body has no video block or bytes; requests go out through each route's production service and a MockEngine captures the body.
 * - nativeFileCases: an official connection sends a native file block only when the file_input projection is native_part, otherwise the file is injected as text and no file placeholder is written.
 * One `MEDIA_OUTBOUND_<id>` test per case; the full set of ids matches the fixture.
 */
class MediaOutboundAttachmentContractTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val openClients = mutableListOf<HttpClient>()
    private val fixture: JsonObject by lazy { readJson("shared/test-fixtures/attachments/media-outbound.v1.json") }

    private fun case(group: String, id: String): JsonObject =
        fixture.getValue(group).jsonArray.map { it.jsonObject }.single { it["id"]!!.jsonPrimitive.content == id }

    @After
    fun tearDown() {
        MetadataTestFixtures.clear()
        openClients.forEach { it.close() }
        openClients.clear()
    }

    @Test
    fun `fixture ids are exactly the MEDIA_OUTBOUND tests`() {
        val ids = listOf("videoPlaceholderCases", "nativeFileCases")
            .flatMap { group -> fixture.getValue(group).jsonArray.map { it.jsonObject["id"]!!.jsonPrimitive.content } }
            .toSet()
        val tests = javaClass.declaredMethods.map { it.name }.filter { it.startsWith("MEDIA_OUTBOUND_") }
            .map { it.removePrefix("MEDIA_OUTBOUND_") }.toSet()
        assertEquals(ids, tests)
    }

    // ── videoPlaceholderCases ──

    @Test
    fun MEDIA_OUTBOUND_video_deepseek_chat() = runTest { assertVideoCase("video_deepseek_chat") }

    @Test
    fun MEDIA_OUTBOUND_video_minimax_chat() = runTest { assertVideoCase("video_minimax_chat") }

    @Test
    fun MEDIA_OUTBOUND_video_two_videos_two_lines() = runTest { assertVideoCase("video_two_videos_two_lines") }

    private suspend fun assertVideoCase(id: String) {
        val case = case("videoPlaceholderCases", id)
        val placeholder = case.getValue("placeholder").jsonPrimitive.content
        val expectLines = case.getValue("expectLines").jsonPrimitive.int
        val route = case.getValue("routes").jsonObject.getValue("android").jsonPrimitive.content
        val videos = (1..case.getValue("videos").jsonPrimitive.int).map { index ->
            Attachment(id = "vid-$index", kind = AttachmentKind.Video, fileName = "clip$index.mp4", mimeType = "video/mp4", base64Data = VIDEO_BYTES)
        }
        val profile = when (route) {
            "DeepSeekChat" -> AttachmentTransportProfile.DeepSeekChat
            "ChatCompletions(MiniMax)" -> AttachmentTransportProfile.ChatCompletions(ProviderKind.MiniMax)
            else -> error("$id: unknown android route $route")
        }
        // Video placeholder = the route's image placeholder with Image replaced by Video (production videoPlaceholder).
        assertEquals(id, placeholder, videoPlaceholder(requireNotNull(profile.imagePlaceholderText)))
        // The route does not send videos at all: the catalog video_input is not consulted and the production default path is used (no metadata injected).
        assertFalse(id, profile.sendsVideos)

        val body = when (profile) {
            AttachmentTransportProfile.DeepSeekChat -> {
                chatBody { client ->
                    DeepSeekService(client, json).sendMessageStream(
                        "key", "deepseek-v4-pro", listOf(message(ProviderKind.DeepSeek, "deepseek-v4-pro", videos)), null,
                        false, ReasoningMode.Automatic, false, ChatRequestOptions(),
                    ).toList()
                }
            }
            else -> {
                chatBody { client ->
                    MiniMaxService(client, json).sendMessageStream(
                        "key", "MiniMax-M3", listOf(message(ProviderKind.MiniMax, "MiniMax-M3", videos)), "https://api.minimax.io/v1",
                        false, ReasoningMode.Automatic, false, ChatRequestOptions(),
                    ).toList()
                }
            }
        }
        assertEquals("$id: $body", expectLines, body.split(placeholder).size - 1)
        assertFalse("$id request body carries video bytes: $body", body.contains(VIDEO_BYTES))
        assertFalse("$id the placeholder must not carry the file name: $body", body.contains(".mp4"))
        listOf("\"video_url\"", "\"input_video\"", "\"type\":\"video\"", "video/mp4").forEach { block ->
            assertFalse("$id request body carries the video block $block: $body", body.contains(block))
        }
    }

    // ── nativeFileCases ──

    @Test
    fun MEDIA_OUTBOUND_file_native_when_projection_native() = assertNativeFileCase("file_native_when_projection_native")

    @Test
    fun MEDIA_OUTBOUND_file_text_when_projection_placeholder() = assertNativeFileCase("file_text_when_projection_placeholder")

    @Test
    fun MEDIA_OUTBOUND_file_text_when_route_text_only() = assertNativeFileCase("file_text_when_route_text_only")

    /**
     * Official connection: the production three-key projection -> [withInputOutbound] -> the [messagesForCapabilityProjection] outbound gate -> the route builder.
     * The route that can send native files is Anthropic (document block); the text-only route is DeepSeek Chat.
     */
    private fun assertNativeFileCase(id: String) {
        val case = case("nativeFileCases", id)
        assertEquals(id, "official", case.getValue("connection").jsonPrimitive.content)
        assertTrue(id, case.getValue("extractedText").jsonPrimitive.boolean)
        val routeNative = case.getValue("routeNativeFiles").jsonPrimitive.boolean
        val fileOutbound = case.getValue("fileInputOutbound").jsonPrimitive.content
        val expect = case.getValue("expect").jsonObject
        val kind = if (routeNative) ProviderKind.Anthropic else ProviderKind.DeepSeek
        val transport = if (routeNative) "anthropic_messages" else "openai_chat"
        val wire = if (routeNative) "anthropic.document" else "openai_chat.file"
        val fileControl = when (fileOutbound) {
            "native_part" -> """{"state":"auto_available","wireFamily":"$wire"}"""
            "placeholder" -> """{"state":"unavailable","reasonCode":"model_capability_absent"}"""
            else -> error("$id: unknown fileInputOutbound $fileOutbound")
        }
        MetadataTestFixtures.applyRaw(
            """{"version":1,"providers":{"${kind.rawValue}":{"resolveMap":{"$FILE_MODEL":"$FILE_MODEL"},"models":{"$FILE_MODEL":""" +
                """{"canonicalModelId":"$FILE_MODEL","transport":"$transport","capabilityControls":{"file_input":$fileControl}}}}}}""",
        )
        val model = AIModel(id = FILE_MODEL, name = FILE_MODEL, nativeFileMimes = listOf(PDF_MIME), pdfNativeDefault = true)
        val provider = Provider(id = "official-${kind.rawValue}", kind = kind)
        val inputs = requireNotNull(resolveInputCapabilityProjections(provider, model, finalTransport = transport)) { id }
        if (routeNative) {
            assertEquals(id, fileOutbound, if (inputs.file.outbound == CapabilityEvidenceFacade.InputCapabilityOutbound.NATIVE_PART) "native_part" else "placeholder")
        }
        val projection = CapabilityEvidenceProductionAdapter.capabilityProjection(
            provider = provider,
            model = model,
            keys = setOf(CapabilityEvidenceFacade.VISION_INPUT),
            finalTransport = transport,
        ).withInputOutbound(inputs)
        val gated = messagesForCapabilityProjection(
            listOf(ProviderTestFixtures.userMessage("read", kind, FILE_MODEL).copy(attachments = listOf(textPdf()))),
            projection,
        )
        val body = if (routeNative) {
            MessageBuilder.buildAnthropicMessages(gated, model)
        } else {
            MessageBuilder.buildOpenAIMessages(gated, ProviderKind.DeepSeek, activeModel = model)
        }
        val nativePart = body.contains(ORIGINAL_PDF) && (body.contains("\"type\":\"document\"") || body.contains("\"type\":\"file\""))
        assertEquals("$id: $body", expect.getValue("nativeFilePart").jsonPrimitive.boolean, nativePart)
        assertEquals("$id: $body", expect.getValue("textInjected").jsonPrimitive.boolean, body.contains(EXTRACTED_TEXT))
        assertEquals("$id: $body", expect.getValue("placeholderLine").jsonPrimitive.boolean, body.contains("omitted"))
    }

    // ── helpers ──

    private fun textPdf() = Attachment(
        id = "text-pdf",
        kind = AttachmentKind.File,
        fileName = "report.pdf",
        mimeType = PDF_MIME,
        base64Data = Base64.getEncoder().encodeToString(EXTRACTED_TEXT.toByteArray()),
        extractedSizeBytes = 5_000,
        originalBase64Data = ORIGINAL_PDF,
    )

    private fun message(kind: ProviderKind, modelId: String, videos: List<Attachment>): ChatMessage =
        ProviderTestFixtures.userMessage("watch this", kind, modelId).copy(attachments = videos)

    /** Runs one production Chat streaming request and returns the raw text of the first request body. */
    private suspend fun chatBody(send: suspend (HttpClient) -> Unit): String {
        var captured: String? = null
        val client = client { request ->
            if (captured == null) captured = bodyText(request.body)
            respond("data: [DONE]\n\n", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/event-stream"))
        }
        runCatching { send(client) }
        return requireNotNull(captured) { "chat route did not issue a request" }
    }

    private fun client(handler: suspend io.ktor.client.engine.mock.MockRequestHandleScope.(io.ktor.client.request.HttpRequestData) -> io.ktor.client.request.HttpResponseData): HttpClient =
        HttpClient(MockEngine(handler)).also { openClients.add(it) }

    private fun bodyText(body: OutgoingContent): String = when (body) {
        is TextContent -> body.text
        is OutgoingContent.ByteArrayContent -> body.bytes().decodeToString()
        else -> error("Unsupported request body type: ${body::class.java.name}")
    }

    private fun repoRoot(): File = File(System.getProperty("user.dir") ?: ".").absoluteFile.parentFile!!.parentFile!!

    private fun readJson(relativePath: String): JsonObject =
        json.parseToJsonElement(File(repoRoot(), relativePath).readText()).jsonObject

    private companion object {
        const val VIDEO_BYTES = "VklERU9fUExBQ0VIT0xERVI="
        const val PDF_MIME = "application/pdf"
        const val FILE_MODEL = "media-outbound-model"
        const val ORIGINAL_PDF = "TkFUSVZFX1BERl9CWVRFUw=="
        const val EXTRACTED_TEXT = "extracted report body"
    }
}
