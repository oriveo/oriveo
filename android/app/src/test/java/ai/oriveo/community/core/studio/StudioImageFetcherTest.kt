package ai.oriveo.community.core.studio

import ai.oriveo.community.core.studio.StudioImageResponse.Failure
import ai.oriveo.community.core.studio.StudioImageResponse.Outcome
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Paths
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * URL image fetcher against the fetchPolicy / fetchCases groups of image_response_samples.v1.
 */
class StudioImageFetcherTest {
    private val fixture: JsonObject by lazy {
        val path = generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("\u5171\u4eab/model-contracts/image_response_samples.v1/index.json") }
            .firstOrNull { Files.exists(it) }
            ?: error("image_response_samples.v1 not found")
        Json.parseToJsonElement(path.toFile().readText()).jsonObject
    }

    private fun decodeSample(name: String): ByteArray = Base64.getDecoder().decode(
        fixture.getValue("decodeCases").jsonArray.map { it.jsonObject }
            .single { it.getValue("name").jsonPrimitive.content == name }
            .getValue("b64").jsonPrimitive.content,
    )

    private val png: ByteArray by lazy { decodeSample("png_rgba_3x2") }
    private val html: ByteArray by lazy { decodeSample("not_an_image_html") }

    private fun withServer(block: suspend (MockWebServer) -> Outcome): Outcome {
        val server = MockWebServer().also { it.start() }
        return try {
            runBlocking { block(server) }
        } finally {
            server.shutdown()
        }
    }

    private suspend fun fetch(server: MockWebServer, fetcher: StudioImageFetcher = StudioImageFetcher(OkHttpClient())): Outcome =
        fetcher.fetch(server.url("/image.png").toString())

    private fun run(name: String): Outcome = when (name) {
        "fetch_ok_png" -> withServer { server ->
            server.enqueue(MockResponse().setResponseCode(200).setHeader("Content-Type", "image/png").setBody(Buffer().write(png)))
            fetch(server)
        }
        "fetch_ok_octet_stream_content_type" -> withServer { server ->
            server.enqueue(MockResponse().setResponseCode(200).setHeader("Content-Type", "application/octet-stream").setBody(Buffer().write(png)))
            fetch(server)
        }
        "fetch_http_404" -> withServer { server ->
            server.enqueue(MockResponse().setResponseCode(404).setBody(Buffer().write(png)))
            fetch(server)
        }
        "fetch_connection_error" -> {
            val server = MockWebServer().also { it.start() }
            val url = server.url("/image.png").toString()
            server.shutdown()
            runBlocking { StudioImageFetcher(OkHttpClient()).fetch(url) }
        }
        "fetch_timeout" -> withServer { server ->
            // Each chunk arrives inside the socket read timeout, so only the total budget stops it.
            server.enqueue(MockResponse().setResponseCode(200).setBody(Buffer().write(png)).throttleBody(8, 400, TimeUnit.MILLISECONDS))
            val client = OkHttpClient.Builder().readTimeout(10, TimeUnit.SECONDS).build()
            fetch(server, StudioImageFetcher(client, timeout = 500.milliseconds))
        }
        "fetch_content_length_over_limit" -> withServer { server ->
            // The body is a valid png within the cap; only the declared Content-Length (cap + 1) can reject it.
            server.enqueue(
                MockResponse().setResponseCode(200).setBody(Buffer().write(png))
                    .setHeader("Content-Length", png.size + 1L),
            )
            fetch(server, StudioImageFetcher(OkHttpClient(), maxBytes = png.size.toLong(), timeout = 5.seconds))
        }
        "fetch_body_over_limit_without_length" -> withServer { server ->
            server.enqueue(MockResponse().setResponseCode(200).setChunkedBody(Buffer().write(png), 16))
            fetch(server, StudioImageFetcher(OkHttpClient(), maxBytes = png.size - 1L))
        }
        "fetch_body_not_an_image" -> withServer { server ->
            server.enqueue(MockResponse().setResponseCode(200).setHeader("Content-Type", "image/png").setBody(Buffer().write(html)))
            fetch(server)
        }
        "fetch_non_http_scheme" -> withServer { server ->
            val fetcher = StudioImageFetcher(OkHttpClient())
            val outcomes = listOf(
                fetcher.fetch("ftp://${server.hostName}:${server.port}/image.png"),
                fetcher.fetch("file:///tmp/image.png"),
                fetcher.fetch("data:image/png;base64,AAAA"),
            )
            assertEquals("no request is made", 0, server.requestCount)
            outcomes.distinct().single()
        }
        else -> error("unhandled fetch case $name")
    }

    @Test
    fun fetchPolicy() {
        val policy = fixture.getValue("fetchPolicy").jsonObject
        assertEquals(policy.getValue("maxBytes").jsonPrimitive.long, StudioImageFetcher.MAX_BYTES)
        assertEquals(policy.getValue("timeoutSeconds").jsonPrimitive.long, StudioImageFetcher.TIMEOUT_SECONDS)
        assertEquals(policy.getValue("schemes").jsonArray.map { it.jsonPrimitive.content }.toSet(), StudioImageFetcher.SCHEMES)
        assertEquals(policy.getValue("checkContentType").jsonPrimitive.boolean, StudioImageFetcher.CHECK_CONTENT_TYPE)
        assertEquals(policy.getValue("redirects").jsonPrimitive.content, StudioImageFetcher.REDIRECTS)
        assertEquals(setOf("maxBytes", "timeoutSeconds", "schemes", "checkContentType", "redirects"), policy.keys)
    }

    @Test
    fun cancel_disconnects_call() {
        val server = MockWebServer().also { it.start() }
        try {
            val body = ByteArray(64 * 1024)
            // Full body takes about 6.4 s at this rate; a prompt cancel must not wait for it.
            server.enqueue(MockResponse().setResponseCode(200).setBody(Buffer().write(body)).throttleBody(1024, 100, TimeUnit.MILLISECONDS))
            val canceled = CountDownLatch(1)
            val failed = CountDownLatch(1)
            val bodyBytes = AtomicLong(-1)
            val listener = object : EventListener() {
                override fun canceled(call: Call) = canceled.countDown()
                override fun callFailed(call: Call, ioe: IOException) = failed.countDown()
                override fun responseBodyEnd(call: Call, byteCount: Long) = bodyBytes.set(byteCount)
            }
            val fetcher = StudioImageFetcher(OkHttpClient.Builder().eventListener(listener).build())
            runBlocking {
                val job = launch(Dispatchers.Default) { fetcher.fetch(server.url("/image.png").toString()) }
                assertNotNull("request reaches the server", server.takeRequest(5, TimeUnit.SECONDS))
                delay(300)
                job.cancel()
                assertNotNull("cancelled fetch returns promptly", withTimeoutOrNull(1_500) { job.join() })
                assertTrue("job ends as cancelled", job.isCancelled)
            }
            assertTrue("call is cancelled", canceled.await(1, TimeUnit.SECONDS))
            assertTrue("call ends in failure right after cancel", failed.await(1, TimeUnit.SECONDS))
            assertTrue("body is not read to the end", bodyBytes.get() < body.size)
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun fetchCases() {
        val cases = fixture.getValue("fetchCases").jsonArray.map { it.jsonObject }
        assertEquals(9, cases.size)
        for (case in cases) {
            val name = case.getValue("name").jsonPrimitive.content
            val expect = case.getValue("expect").jsonObject
            val outcome = run(name)
            if (expect.getValue("ok").jsonPrimitive.boolean) {
                val image = (outcome as? Outcome.Ok)?.image ?: error("$name: expected ok, got $outcome")
                assertEquals(name, expect.getValue("mime").jsonPrimitive.content, image.mime)
                assertEquals(name, expect.getValue("width").jsonPrimitive.int, image.width)
                assertEquals(name, expect.getValue("height").jsonPrimitive.int, image.height)
                assertTrue(name, png.contentEquals(image.bytes))
            } else {
                val failure = Failure.entries.single { it.wire == expect.getValue("failure").jsonPrimitive.content }
                assertEquals(name, Outcome.Failed(failure), outcome)
            }
        }
    }
}
