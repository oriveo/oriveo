package ai.oriveo.community.core.studio

import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.imageio.ImageIO
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartReader
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Production BYOK transport over MockWebServer: JSON and multipart bodies on the wire, HTTP errors as
 * responses, call timeout and coroutine cancel mapped to their transport phases, and the executor's
 * golden chain through the real transport and image fetcher.
 */
class StudioByokHttpTransportTest {
    private val server = MockWebServer().also { it.start() }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun transport(client: OkHttpClient = OkHttpClient(), compiledIn: Boolean = true) =
        StudioByokHttpTransport(StudioHttpTransport(client, isCompiledIn = compiledIn), StudioImageFetcher(client))

    private fun jsonRequest(headers: Map<String, String> = mapOf("Content-Type" to "application/json")) = ImageHttpRequest(
        method = "POST",
        url = server.url("/v1/images/generations").toString(),
        headers = mapOf("Authorization" to "Bearer test-key") + headers,
        body = ImageRequestBody.Json(JsonObject(mapOf("model" to JsonPrimitive("test-model"), "prompt" to JsonPrimitive("a fox")))),
    )

    private fun failure(outcome: StudioByokTransport.SendOutcome): StudioByokTransport.SendOutcome.Failure =
        outcome as? StudioByokTransport.SendOutcome.Failure ?: error("expected a failure, got $outcome")

    private fun response(outcome: StudioByokTransport.SendOutcome): StudioByokTransport.SendOutcome.Response =
        outcome as? StudioByokTransport.SendOutcome.Response ?: error("expected a response, got $outcome")

    @Test
    fun jsonRequestSent() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("{\"data\":[]}"))
        val sent = response(transport().send(jsonRequest(), timeoutSeconds = 30, maxBodyBytes = BODY_LIMIT))

        assertEquals(200, sent.status)
        assertEquals("{\"data\":[]}", sent.body.decodeToString())
        val recorded = server.takeRequest(5, TimeUnit.SECONDS) ?: error("no request recorded")
        assertEquals("POST", recorded.method)
        assertEquals("/v1/images/generations", recorded.path)
        assertEquals("Bearer test-key", recorded.getHeader("Authorization"))
        assertEquals("application/json", recorded.getHeader("Content-Type")?.toMediaType()?.let { "${it.type}/${it.subtype}" })
        assertEquals(
            JsonObject(mapOf("model" to JsonPrimitive("test-model"), "prompt" to JsonPrimitive("a fox"))),
            Json.parseToJsonElement(recorded.body.readUtf8()),
        )
    }

    @Test
    fun multipartFilesSent() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("{\"data\":[]}"))
        val png = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x00, 0x7F)
        val request = ImageHttpRequest(
            method = "POST",
            url = server.url("/v1/images/edits").toString(),
            headers = mapOf("Authorization" to "Bearer test-key", "Content-Type" to "multipart/form-data"),
            body = ImageRequestBody.Multipart(
                fields = listOf("model" to "test-model", "prompt" to "a fox"),
                files = listOf(ImageRequestBody.File(name = "image[]", filename = "image-1.png", mime = "image/png", data = png)),
            ),
        )
        assertEquals(200, response(transport().send(request, timeoutSeconds = 30, maxBodyBytes = BODY_LIMIT)).status)

        val recorded = server.takeRequest(5, TimeUnit.SECONDS) ?: error("no request recorded")
        assertEquals("Bearer test-key", recorded.getHeader("Authorization"))
        val contentType = recorded.getHeader("Content-Type")?.toMediaType() ?: error("no content type")
        assertEquals("multipart/form-data", "${contentType.type}/${contentType.subtype}")
        val boundary = contentType.parameter("boundary") ?: error("OkHttp boundary was overwritten")
        val parts = mutableListOf<Triple<String?, String?, ByteArray>>()
        MultipartReader(recorded.body, boundary).use { reader ->
            while (true) {
                val part = reader.nextPart() ?: break
                parts += Triple(part.headers["Content-Disposition"], part.headers["Content-Type"], part.body.readByteArray())
            }
        }
        assertEquals(3, parts.size)
        assertEquals("form-data; name=\"model\"", parts[0].first)
        assertEquals("test-model", parts[0].third.decodeToString())
        assertEquals("form-data; name=\"prompt\"", parts[1].first)
        assertEquals("a fox", parts[1].third.decodeToString())
        assertEquals("form-data; name=\"image[]\"; filename=\"image-1.png\"", parts[2].first)
        assertEquals("image/png", parts[2].second)
        assertArrayEquals(png, parts[2].third)
    }

    @Test
    fun httpErrorReturnsStatusAndBody() = runBlocking {
        val body = "{\"error\":{\"message\":\"rate limited\"}}"
        server.enqueue(MockResponse().setResponseCode(429).setBody(body))
        val sent = response(transport().send(jsonRequest(), timeoutSeconds = 30, maxBodyBytes = BODY_LIMIT))

        assertEquals(429, sent.status)
        assertEquals(body, sent.body.decodeToString())
    }

    @Test
    fun callTimeoutIsTimeoutPhase() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("{\"data\":[]}").setHeadersDelay(5, TimeUnit.SECONDS))
        val failed = failure(transport().send(jsonRequest(), timeoutSeconds = 1, maxBodyBytes = BODY_LIMIT))

        assertFalse("a call timeout is not a user cancel", failed.callCanceled)
        assertEquals(StudioByokTasks.Phase.TIMEOUT, StudioByokTasks.transportPhase(failed.error, failed.callCanceled))
    }

    @Test
    fun coroutineCancelCancelsCall() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("{\"data\":[]}").setHeadersDelay(30, TimeUnit.SECONDS))
        val canceled = CountDownLatch(1)
        var failedCall: Call? = null
        var failedError: IOException? = null
        val client = OkHttpClient.Builder().eventListener(object : EventListener() {
            override fun canceled(call: Call) {
                canceled.countDown()
            }

            override fun callFailed(call: Call, ioe: IOException) {
                failedCall = call
                failedError = ioe
            }
        }).build()
        val pending = async(Dispatchers.Default) { transport(client).send(jsonRequest(), timeoutSeconds = 60, maxBodyBytes = BODY_LIMIT) }
        server.takeRequest(5, TimeUnit.SECONDS) ?: error("request never reached the server")

        pending.cancel()
        withTimeout(5_000) { pending.join() }

        assertTrue(pending.isCancelled)
        assertTrue("coroutine cancel must cancel the OkHttp call", canceled.await(1, TimeUnit.SECONDS))
        val call = failedCall ?: error("call did not fail")
        val error = failedError ?: error("call did not fail")
        assertEquals(StudioByokTasks.Phase.CANCELLED, StudioByokTasks.transportPhase(error, call.isCanceled()))
    }

    @Test
    fun compiledOutSendsNothing() = runBlocking {
        val failed = failure(transport(compiledIn = false).send(jsonRequest(), timeoutSeconds = 30, maxBodyBytes = BODY_LIMIT))

        assertTrue(failed.error.cause is IllegalStateException)
        assertFalse(failed.callCanceled)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun notSentFailureIsPreConnect() = runBlocking {
        val compiledOut = failure(transport(compiledIn = false).send(jsonRequest(), timeoutSeconds = 30, maxBodyBytes = BODY_LIMIT))
        assertEquals(StudioByokTasks.Phase.PRE_CONNECT, StudioByokTasks.transportPhase(compiledOut.error, compiledOut.callCanceled))
        assertTrue("the original error stays the cause", compiledOut.error.cause is IllegalStateException)

        val badUrl = jsonRequest().copy(url = "not a url")
        val unbuildable = failure(transport().send(badUrl, timeoutSeconds = 30, maxBodyBytes = BODY_LIMIT))
        assertEquals(StudioByokTasks.Phase.PRE_CONNECT, StudioByokTasks.transportPhase(unbuildable.error, unbuildable.callCanceled))
        assertTrue("the original error stays the cause", unbuildable.error.cause is IllegalArgumentException)
        assertEquals(0, server.requestCount)

        // Through the executor: not sent, not billed, retried once.
        val rawProfile = readJson(contractPath("image_param_normalization.v1.json")).getValue("profiles").jsonObject
            .getValue("openai_gpt_image").jsonObject
        val profile = ImageProfileResolver.validate(rawProfile).profile ?: error("profile does not validate")
        val result = StudioByokExecutor(transport(compiledIn = false), MemorySink()).run(
            StudioByokInput(
                roundId = "round-1",
                providerKind = "openai",
                apiKey = "test-key",
                baseUrl = server.url("/v1").toString().trimEnd('/'),
                modelId = "test-model",
                profile = profile,
                operation = ImageOperation.GENERATE,
                prompt = "a red fox in the snow",
                params = ImageParamRequest(aspect = "1:1", n = 1),
            ),
            CompletableDeferred(),
        )
        assertEquals(StudioByokTasks.RoundStatus.FAILED, result.status)
        assertEquals(StudioImageErrorKind.NETWORK, result.errorKind)
        assertTrue("the first not-sent failure is retried once", result.retried)
        assertFalse("nothing left the device", result.mayBeBilled)
        assertEquals(0, server.requestCount)
    }

    private fun contractPath(name: String): Path =
        generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("${SHARED_DIR}/model-contracts/$name") }
            .firstOrNull { Files.exists(it) }
            ?: error("$name not found")

    private companion object {
        const val BODY_LIMIT = 41_943_040L + 1_048_576L

        // Repository shared-contracts directory name, built from code points to keep the source ASCII.
        val SHARED_DIR = String(intArrayOf(0x5171, 0x4EAB), 0, 2)
    }

    private fun readJson(path: Path): JsonObject = Json.parseToJsonElement(path.toFile().readText()).jsonObject

    private class MemorySink : StudioByokImageSink {
        val stored = linkedMapOf<String, ByteArray>()

        override suspend fun save(id: String, bytes: ByteArray) {
            stored[id] = bytes
        }

        override suspend fun delete(id: String) {
            stored.remove(id)
        }
    }

    @Test
    fun goldenChainThroughRealTransport() = runBlocking {
        val sample = readJson(contractPath("image_response_samples.v1/openai_images.zhipu.glm-image.generate.json"))
        val observed = sample.getValue("observed").jsonObject.getValue("images").jsonArray.single().jsonObject
        val width = observed.getValue("width").jsonPrimitive.content.toInt()
        val height = observed.getValue("height").jsonPrimitive.content.toInt()
        val jpeg = ByteArrayOutputStream().also { out ->
            check(ImageIO.write(BufferedImage(width, height, BufferedImage.TYPE_INT_RGB), "jpeg", out)) { "no jpeg writer" }
        }.toByteArray()
        val response = sample.getValue("response").jsonObject
        val providerUrl = response.getValue("data").jsonArray.single().jsonObject.getValue("url").jsonPrimitive.content
        val imageUrl = server.url("/files/out.png?sig=redacted").toString()
        val responseText = response.toString().replace(providerUrl, imageUrl)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                if (request.method == "POST") {
                    MockResponse().setResponseCode(sample.getValue("meta").jsonObject.getValue("http").jsonPrimitive.content.toInt())
                        .setBody(responseText)
                } else {
                    MockResponse().setResponseCode(200).setBody(Buffer().write(jpeg))
                }
        }
        val rawProfile = readJson(contractPath("image_param_normalization.v1.json")).getValue("profiles").jsonObject
            .getValue("openai_gpt_image").jsonObject
        val profile = ImageProfileResolver.validate(rawProfile).profile ?: error("profile does not validate")
        val sink = MemorySink()
        val result = StudioByokExecutor(transport(), sink, shrink = { _, _ -> null }).run(
            StudioByokInput(
                roundId = "round-1",
                providerKind = "openai",
                apiKey = "test-key",
                baseUrl = server.url("/v1").toString().trimEnd('/'),
                modelId = "test-model",
                profile = profile,
                operation = ImageOperation.GENERATE,
                prompt = "a red fox in the snow",
                params = ImageParamRequest(aspect = "1:1", n = 1),
                images = emptyList(),
            ),
            CompletableDeferred(),
        )

        assertEquals(StudioByokTasks.RoundStatus.COMPLETED, result.status)
        assertNull(result.errorKind)
        assertEquals(1, result.delivered)
        val image = result.images.single()
        assertEquals("image/jpeg", image.mime)
        assertEquals(width, image.width)
        assertEquals(height, image.height)
        assertArrayEquals(jpeg, sink.stored.getValue(image.id))
        assertEquals(2, server.requestCount)
        val first = server.takeRequest(5, TimeUnit.SECONDS) ?: error("no request recorded")
        assertEquals("POST", first.method)
        assertEquals("Bearer test-key", first.getHeader("Authorization"))
        assertEquals("/files/out.png?sig=redacted", (server.takeRequest(5, TimeUnit.SECONDS) ?: error("no fetch recorded")).path)
    }
}
