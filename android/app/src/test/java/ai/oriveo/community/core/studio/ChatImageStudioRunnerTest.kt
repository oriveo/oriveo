package ai.oriveo.community.core.studio

import ai.oriveo.community.core.data.attachment.StoredImage
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.util.Base64
import java.util.Collections
import javax.imageio.ImageIO
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Chat image runner: the chat_image_dispatch.v1 wire cases go through the runner and the real executor
 * into a fake transport and send the legacy request; edits send the user's local images in order; a
 * failed round throws the mapped chat error; the runner's own transport sends with Studio compiled out.
 */
class ChatImageStudioRunnerTest {
    // Shared contract directory name, built at runtime so the source stays ASCII.
    private val sharedDir = String(charArrayOf(0x5171.toChar(), 0x4eab.toChar()))

    private val fixture: JsonObject by lazy {
        val path: Path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("$sharedDir/studio-contracts/chat_image_dispatch.v1.json") }
            .firstOrNull { Files.exists(it) }
            ?: error("chat_image_dispatch.v1.json not found")
        Json.parseToJsonElement(path.toFile().readText()).jsonObject
    }

    private val profiles: JsonObject by lazy { fixture.getValue("profiles").jsonObject }

    private val metadata = MetadataClient()

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content

    private fun png(width: Int, height: Int, rgb: Int = 0): ByteArray {
        val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
        for (x in 0 until width) for (y in 0 until height) image.setRGB(x, y, rgb)
        val out = ByteArrayOutputStream()
        check(ImageIO.write(image, "png", out)) { "no png writer" }
        return out.toByteArray()
    }

    private val resultPng: ByteArray by lazy { png(64, 64, 0x336699) }

    /** Android provider kind whose server catalog key is [serverKey] (togetherAI -> Together). */
    private fun kindOf(serverKey: String): ProviderKind =
        ProviderKind.entries.firstOrNull { metadata.catalogKey(it) == serverKey } ?: error("no provider kind for $serverKey")

    /** A slice listing only [modelId] under [serverKey] with profile [ref]. */
    private fun slice(serverKey: String, modelId: String, ref: String): ImageProfileSlice =
        ImageProfileResolver.sliceOf(
            profiles = profiles,
            providers = mapOf(
                serverKey to ImageProfileSlice.Provider(models = mapOf(modelId to ImageProfileSlice.ModelEntry(imageProfile = ref))),
            ),
        )

    /** Success body of [ref]'s route carrying [resultPng]; [usage] adds a token usage object. */
    private fun successBody(ref: String, usage: Boolean): String {
        val b64 = Base64.getEncoder().encodeToString(resultPng)
        val usageJson = if (usage) ""","usage":{"input_tokens":12,"output_tokens":34,"total_tokens":46}""" else ""
        return when (profiles.getValue(ref).jsonObject.str("route")) {
            "dashscope_multimodal" ->
                """{"output":{"choices":[{"message":{"role":"assistant","content":[{"image":"https://example.com/out.png"}]}}]}$usageJson}"""
            "minimax_image_generation" ->
                """{"data":{"image_base64":["$b64"]},"base_resp":{"status_code":0,"status_msg":"success"}$usageJson}"""
            else -> """{"data":[{"b64_json":"$b64"}]$usageJson}"""
        }
    }

    private inner class FakeTransport(
        private val status: Int,
        private val body: String,
    ) : StudioByokTransport {
        val sent: MutableList<ImageHttpRequest> = Collections.synchronizedList(mutableListOf())

        override suspend fun send(request: ImageHttpRequest, timeoutSeconds: Int, maxBodyBytes: Long): StudioByokTransport.SendOutcome {
            sent += request
            return StudioByokTransport.SendOutcome.Response(status, body.toByteArray())
        }

        override suspend fun fetchImage(url: String): StudioImageResponse.Outcome =
            StudioImageResponse.Outcome.Ok(StudioImageResponse.DeliveredImage(resultPng, "image/png", 64, 64))
    }

    private class FakeStore(private val local: Map<String, ByteArray> = emptyMap()) : ChatImageStudioRunner.ImageStore {
        val saved: MutableMap<String, ByteArray> = Collections.synchronizedMap(linkedMapOf())

        override fun loadImageBytes(localImageId: String): ByteArray? = local[localImageId]

        override fun saveOriginalImage(data: ByteArray, id: String): StoredImage {
            saved[id] = data
            return StoredImage(id, "image/png")
        }

        override fun loadThumbnailBase64(localImageId: String): String? = "thumb-$localImageId".takeIf { localImageId in saved }

        override fun delete(localImageId: String) {
            saved.remove(localImageId)
        }
    }

    private fun runner(transport: StudioByokTransport, store: FakeStore, slice: ImageProfileSlice) = ChatImageStudioRunner(
        transport = transport,
        images = store,
        profileSlice = { slice },
        catalogKey = metadata::catalogKey,
        pricing = { _, _ -> null },
    )

    private fun request(
        provider: ProviderKind,
        modelId: String,
        prompt: String = "a red bicycle",
        baseUrl: String? = "https://api.example.com/v1",
        attachments: List<Attachment> = emptyList(),
    ) = ChatImageStudioRunner.Request(
        provider = provider,
        modelId = modelId,
        apiKey = "sk-test",
        baseUrl = baseUrl,
        prompt = prompt,
        attachments = attachments,
    )

    private fun imageAttachment(id: String, localImageId: String?, kind: AttachmentKind = AttachmentKind.Image) = Attachment(
        id = id,
        kind = kind,
        fileName = "$id.png",
        mimeType = "image/png",
        localImageId = localImageId,
    )

    /** Value at a dotted [path] of [root] ("parameters.size"), null when absent. */
    private fun at(root: JsonObject, path: String): JsonElement? =
        path.split('.').fold(root as JsonElement?) { node, key -> (node as? JsonObject)?.get(key) }

    /** Mismatches of a finished studio result against the persist shape; empty when it matches. */
    private fun persistMismatches(caseId: String, result: ProviderChatResult?, store: FakeStore): List<String> {
        if (result == null) return listOf("$caseId: runner returned legacy")
        val problems = mutableListOf<String>()
        if (result.text != "") problems += "$caseId: text '${result.text}'"
        val attachments = result.attachments.orEmpty()
        if (attachments.size != 1) problems += "$caseId: ${attachments.size} attachments"
        for (attachment in attachments) {
            if (attachment.kind != AttachmentKind.Image) problems += "$caseId: kind ${attachment.kind}"
            if (attachment.localImageId == null || attachment.localImageId !in store.saved) {
                problems += "$caseId: localImageId ${attachment.localImageId} not stored"
            }
            if (attachment.mimeType != "image/png") problems += "$caseId: mime ${attachment.mimeType}"
            if (attachment.thumbnailBase64 != "thumb-${attachment.localImageId}") problems += "$caseId: thumbnail ${attachment.thumbnailBase64}"
            if (attachment.base64Data != null) problems += "$caseId: inline base64 kept"
        }
        return problems
    }

    @Test
    fun wireMatchesLegacy() = runBlocking {
        val cases = fixture.getValue("wire").jsonArray.map { it.jsonObject }
        assertTrue("wire group must not be empty", cases.isNotEmpty())
        val mismatches = mutableListOf<String>()
        for (case in cases) {
            val caseId = case.str("caseId")
            val input = case.getValue("input").jsonObject
            val expect = case.getValue("expect").jsonObject
            val serverKey = input.str("providerKind")
            val modelId = input.str("modelId")
            val ref = input.str("profileRef")
            val withUsage = serverKey == "openAI"
            val transport = FakeTransport(200, successBody(ref, withUsage))
            val store = FakeStore()
            val result = runner(transport, store, slice(serverKey, modelId, ref))
                .run(request(kindOf(serverKey), modelId, prompt = input.str("prompt")))

            if (transport.sent.size != 1) {
                mismatches += "$caseId: ${transport.sent.size} requests"
                continue
            }
            val sent = transport.sent.single()
            if (sent.method != expect.str("method")) mismatches += "$caseId: method ${sent.method}"
            if (!sent.url.endsWith(expect.str("pathSuffix"))) mismatches += "$caseId: url ${sent.url}"
            val body = (sent.body as? ImageRequestBody.Json)?.json
            if (body == null) {
                mismatches += "$caseId: body is not JSON"
                continue
            }
            for ((path, value) in expect.getValue("bodyIncludes").jsonObject) {
                val actual = at(body, path)
                if (actual != value) mismatches += "$caseId: $path = $actual, expected $value"
            }
            for (key in expect.getValue("bodyExcludes").jsonArray.map { it.jsonPrimitive.content }) {
                if (body.containsKey(key)) mismatches += "$caseId: body has $key"
            }
            mismatches += persistMismatches(caseId, result, store)
            if (result != null) {
                if (result.usageReported != withUsage) mismatches += "$caseId: usageReported ${result.usageReported}"
                val tokens = if (withUsage) 12 to 34 else 0 to 0
                if (result.promptTokens to result.completionTokens != tokens) {
                    mismatches += "$caseId: tokens ${result.promptTokens}/${result.completionTokens}"
                }
            }
        }
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())

        // A relay send stays on the legacy path: no result, nothing sent.
        val relayTransport = FakeTransport(200, successBody("openai_images_square", usage = false))
        val relay = runner(relayTransport, FakeStore(), slice("relay", "gpt-image-1", "openai_images_square"))
            .run(request(ProviderKind.Relay, "gpt-image-1"))
        assertNull(relay)
        assertEquals(0, relayTransport.sent.size)
    }

    @Test
    fun editSendsAttachmentsInOrder() = runBlocking {
        val first = png(32, 32, 0xff0000)
        val second = png(48, 48, 0x00ff00)
        val store = FakeStore(mapOf("img-1" to first, "img-4" to second))
        val transport = FakeTransport(200, successBody("openai_gpt_image", usage = false))
        val result = runner(transport, store, slice("openAI", "gpt-image-2", "openai_gpt_image")).run(
            request(
                ProviderKind.OpenAI,
                "gpt-image-2",
                attachments = listOf(
                    imageAttachment("a1", "img-1"),
                    imageAttachment("a2", "img-missing"),
                    imageAttachment("a3", null, kind = AttachmentKind.File),
                    imageAttachment("a4", "img-4"),
                ),
            ),
        )

        assertEquals(1, transport.sent.size)
        val sent = transport.sent.single()
        assertTrue(sent.url, sent.url.endsWith("/images/edits"))
        val files = (sent.body as? ImageRequestBody.Multipart)?.files ?: error("edit body is not multipart")
        assertEquals(listOf(first.toList(), second.toList()), files.map { it.data.toList() })
        val problems = persistMismatches("edit", result, store)
        assertTrue(problems.joinToString("\n"), problems.isEmpty())
    }

    @Test
    fun failureMapsToChatError() = runBlocking {
        val cases = listOf(
            401 to """{"error":{"message":"Incorrect API key provided"}}""",
            429 to """{"error":{"message":"Too many requests, slow down"}}""",
            503 to """{"error":{"message":"Service temporarily unavailable"}}""",
        )
        val expected = mapOf<Int, (String) -> ProviderServiceError>(
            401 to { ProviderServiceError.InvalidAPIKey(it) },
            429 to { ProviderServiceError.RateLimited(it) },
            503 to { ProviderServiceError.Upstream(statusCode = 502, detail = it) },
        )
        for ((status, body) in cases) {
            val store = FakeStore()
            val transport = FakeTransport(status, body)
            try {
                runner(transport, store, slice("openAI", "gpt-image-1", "openai_images_square"))
                    .run(request(ProviderKind.OpenAI, "gpt-image-1"))
                fail("status $status did not throw")
            } catch (error: ProviderServiceError) {
                assertEquals("status $status", expected.getValue(status)(body), error)
            }
            assertTrue("status $status stored images", store.saved.isEmpty())
        }
    }

    @Test
    fun missingBaseUrlStaysLegacy() = runBlocking {
        for (baseUrl in listOf(null, "", "   ")) {
            val transport = FakeTransport(200, successBody("openai_images_square", usage = false))
            val store = FakeStore()
            val result = runner(transport, store, slice("openAI", "gpt-image-1", "openai_images_square"))
                .run(request(ProviderKind.OpenAI, "gpt-image-1", baseUrl = baseUrl))
            assertNull("base url '$baseUrl'", result)
            assertEquals("base url '$baseUrl' sent", 0, transport.sent.size)
            assertTrue("base url '$baseUrl' stored images", store.saved.isEmpty())
        }
    }

    @Test
    fun worksWithStudioCompiledOut() = runBlocking {
        val seen: MutableList<Request> = Collections.synchronizedList(mutableListOf())
        val responseBody = successBody("openai_images_square", usage = false)
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            seen += chain.request()
            Response.Builder()
                .request(chain.request())
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(responseBody.toResponseBody("application/json".toMediaType()))
                .build()
        }.build()
        // The shared Studio transport refuses to build a call when Studio is compiled out.
        assertNull(StudioHttpTransport(client, isCompiledIn = false).newCall(Request.Builder().url("https://api.example.com/").build(), 60))

        val store = FakeStore()
        val result = runner(ChatImageStudioRunner.httpTransport(client), store, slice("openAI", "gpt-image-1", "openai_images_square"))
            .run(request(ProviderKind.OpenAI, "gpt-image-1"))

        assertEquals(1, seen.size)
        assertEquals("https://api.example.com/v1/images/generations", seen.single().url.toString())
        assertEquals("Bearer sk-test", seen.single().header("Authorization"))
        val problems = persistMismatches("compiled_out", result, store)
        assertTrue(problems.joinToString("\n"), problems.isEmpty())
    }
}
