package ai.oriveo.community.core.studio

import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.util.Base64
import javax.imageio.ImageIO
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * BYOK executor main path: every image_response_samples.v1 golden response goes through a fake
 * transport, is decoded and stored; local rejects never send; a failed store rolls back; batches run
 * concurrently with their own n, only a first pre_connect failure is retried, cancel drops every image,
 * usage is summed and the in-flight marker covers the send.
 */
class StudioByokExecutorTest {
    private fun contractPath(name: String): Path =
        generateSequence(Paths.get("").toAbsolutePath().normalize()) { it.parent }
            .take(8)
            .map { it.resolve("\u5171\u4eab/model-contracts/$name") }
            .firstOrNull { Files.exists(it) }
            ?: error("$name not found")

    private val samplesDir: Path by lazy { contractPath("image_response_samples.v1") }

    private fun readJson(path: Path): JsonObject = Json.parseToJsonElement(path.toFile().readText()).jsonObject

    private val profiles: JsonObject by lazy {
        readJson(contractPath("image_param_normalization.v1.json")).getValue("profiles").jsonObject
    }

    private fun profile(ref: String, override: JsonObject? = null): ImageProfile {
        val base = profiles.getValue(ref).jsonObject
        val raw = if (override == null) base else JsonObject(base + override)
        return ImageProfileResolver.validate(raw).profile ?: error("$ref does not validate")
    }

    private fun JsonObject.str(key: String): String = getValue(key).jsonPrimitive.content

    // A real encoded image of the given size; webp is a hand-made VP8X header (no JDK encoder).
    private fun realImage(mime: String, width: Int, height: Int): ByteArray {
        if (mime == "image/webp") return webpHeader(width, height)
        val format = when (mime) {
            "image/png" -> "png"
            "image/jpeg" -> "jpeg"
            else -> error("unsupported mime $mime")
        }
        val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
        val out = ByteArrayOutputStream()
        check(ImageIO.write(image, format, out)) { "no writer for $format" }
        return out.toByteArray()
    }

    private fun webpHeader(width: Int, height: Int): ByteArray {
        val bytes = ByteArray(30)
        fun ascii(at: Int, text: String) = text.forEachIndexed { i, c -> bytes[at + i] = c.code.toByte() }
        fun le(at: Int, value: Int, count: Int) = repeat(count) { bytes[at + it] = (value ushr (8 * it)).toByte() }
        ascii(0, "RIFF")
        le(4, 22, 4)
        ascii(8, "WEBP")
        ascii(12, "VP8X")
        le(16, 10, 4)
        le(24, width - 1, 3)
        le(27, height - 1, 3)
        return bytes
    }

    private class FakeTransport(
        private val status: Int,
        private val body: ByteArray,
        private val fetched: (String) -> StudioImageResponse.Outcome = { error("fetchImage not expected: $it") },
    ) : StudioByokTransport {
        val sent = mutableListOf<Pair<ImageHttpRequest, Int>>()
        val fetchedUrls = mutableListOf<String>()

        override suspend fun send(request: ImageHttpRequest, timeoutSeconds: Int, maxBodyBytes: Long): StudioByokTransport.SendOutcome {
            sent += request to timeoutSeconds
            return StudioByokTransport.SendOutcome.Response(status, body)
        }

        override suspend fun fetchImage(url: String): StudioImageResponse.Outcome {
            fetchedUrls += url
            return fetched(url)
        }
    }

    /** One send seen by [ScriptedTransport]: the request's JSON n and the attempt index for that n. */
    private data class Call(val n: Int?, val attempt: Int)

    /** Answers each send from [script] by batch n and attempt; records every call. */
    private class ScriptedTransport(
        private val fetched: suspend (String) -> StudioImageResponse.Outcome = { error("fetchImage not expected: $it") },
        private val script: suspend (n: Int?, attempt: Int, timeoutSeconds: Int) -> StudioByokTransport.SendOutcome,
    ) : StudioByokTransport {
        val calls = mutableListOf<Call>()
        val bodyLimits = mutableListOf<Long>()
        var cancelledSends = 0

        override suspend fun send(request: ImageHttpRequest, timeoutSeconds: Int, maxBodyBytes: Long): StudioByokTransport.SendOutcome {
            val n = (request.body as? ImageRequestBody.Json)?.json?.get("n")?.jsonPrimitive?.int
            val call = Call(n, calls.count { it.n == n })
            calls += call
            bodyLimits += maxBodyBytes
            try {
                return script(call.n, call.attempt, timeoutSeconds)
            } catch (e: CancellationException) {
                cancelledSends++
                throw e
            }
        }

        override suspend fun fetchImage(url: String): StudioImageResponse.Outcome = fetched(url)
    }

    private class FakeSink(private val failOnSave: Int = -1, private val hangOnSave: Int = -1) : StudioByokImageSink {
        val stored = linkedMapOf<String, ByteArray>()
        val saves = mutableListOf<String>()
        val deletes = mutableListOf<String>()
        val hanging = CompletableDeferred<Unit>()

        override suspend fun save(id: String, bytes: ByteArray) {
            saves += id
            if (saves.size == failOnSave) throw IOException("disk full")
            if (saves.size == hangOnSave) {
                hanging.complete(Unit)
                awaitCancellation()
            }
            stored[id] = bytes
        }

        override suspend fun delete(id: String) {
            deletes += id
            stored.remove(id)
        }
    }

    private fun input(
        profile: ImageProfile,
        operation: ImageOperation = ImageOperation.GENERATE,
        prompt: String = "a red fox in the snow",
        params: ImageParamRequest = ImageParamRequest(aspect = "1:1", n = 1),
        images: List<StudioByokImage> = emptyList(),
        baseUrl: String = "https://api.example.com/v1",
        modelId: String = "test-model",
        styleFragment: String? = null,
        effectFragments: List<String> = emptyList(),
    ) = StudioByokInput(
        roundId = "round-1",
        providerKind = "openai",
        apiKey = "test-key",
        baseUrl = baseUrl,
        modelId = modelId,
        profile = profile,
        operation = operation,
        prompt = prompt,
        params = params,
        images = images,
        styleFragment = styleFragment,
        effectFragments = effectFragments,
    )

    private val routeProfiles = mapOf(
        "openai_images" to "openai_gpt_image",
        "xai_images" to "xai_grok_imagine",
        "gemini_generate_content" to "gemini_flash_image",
        "chat_modalities" to "openrouter_gemini_chat",
        "openrouter_images" to "openrouter_gpt_images",
        "dashscope_multimodal" to "dashscope_qwen_image",
        "minimax_image_generation" to "minimax_image01",
    )

    private val placeholder = Regex("""<base64 bytes=(\d+) sha256=[0-9a-f]+>""")

    @Test
    fun goldenSamplesDeliverDecodedImages() = runBlocking {
        val index = readJson(samplesDir.resolve("index.json"))
        val samples = index.getValue("samples").jsonArray.map { it.jsonObject }
        assertTrue("fixture group must not be empty", samples.isNotEmpty())
        for (sample in samples) {
            val file = sample.str("file")
            val raw = readJson(samplesDir.resolve(file))
            val observed = raw.getValue("observed").jsonObject.getValue("images").jsonArray.map { it.jsonObject }
            val observedImages = observed.map { realImage(it.str("mime"), it.getValue("width").jsonPrimitive.int, it.getValue("height").jsonPrimitive.int) }
            // Placeholders of an observed image's byte count become that real image; others (signatures) stay filler.
            val responseText = placeholder.replace(raw.getValue("response").toString()) { match ->
                val at = observed.indexOfFirst { it.str("bytes") == match.groupValues[1] }
                if (at >= 0) Base64.getEncoder().encodeToString(observedImages[at]) else "AAAA"
            }
            var fetchIndex = 0
            val transport = FakeTransport(
                status = raw.getValue("meta").jsonObject.getValue("http").jsonPrimitive.int,
                body = responseText.toByteArray(Charsets.UTF_8),
            ) { StudioImageResponse.outcomeOf(observedImages[fetchIndex++]) }
            val sink = FakeSink()
            val operation = ImageOperation.fromWire(sample.str("operation")) ?: error("$file: unknown operation")
            val nRequested = sample.getValue("nRequested").jsonPrimitive.int
            val references = if (operation == ImageOperation.EDIT) {
                listOf(StudioByokImage(slot = 1, role = "base", mime = "image/png", bytes = realImage("image/png", 64, 64)))
            } else {
                emptyList()
            }
            val result = StudioByokExecutor(transport, sink, shrink = { _, _ -> null }).run(
                input(
                    profile = profile(routeProfiles.getValue(sample.str("route"))),
                    operation = operation,
                    params = ImageParamRequest(aspect = "1:1", n = nRequested),
                    images = references,
                ),
                CompletableDeferred(),
            )

            assertEquals(file, 1, transport.sent.size)
            assertEquals(file, nRequested, result.nRequested)
            val expect = sample.getValue("expect").jsonObject
            if (expect.str("result") == "ok") {
                assertEquals(file, StudioByokTasks.RoundStatus.COMPLETED, result.status)
                assertNull(file, result.errorKind)
                assertTrue(file, result.mayBeBilled)
                assertEquals(file, nRequested, result.delivered)
                assertEquals(file, nRequested, result.images.size)
                result.images.forEachIndexed { i, image ->
                    val want = observed[i]
                    assertEquals(file, want.str("mime"), image.mime)
                    assertEquals(file, want.getValue("width").jsonPrimitive.int, image.width)
                    assertEquals(file, want.getValue("height").jsonPrimitive.int, image.height)
                }
                assertEquals(file, result.images.map { it.id }, sink.stored.keys.toList())
                assertTrue(file, sink.stored.values.first().contentEquals(observedImages[0]))
            } else {
                assertEquals(file, StudioByokTasks.RoundStatus.FAILED, result.status)
                assertEquals(file, expect.str("result"), result.errorKind?.wire)
                assertEquals(file, responseText.take(1000), result.message)
                assertEquals(file, 0, result.delivered)
                assertTrue(file, result.images.isEmpty())
                assertTrue(file, sink.saves.isEmpty())
            }
        }
    }

    private suspend fun assertLocalReject(
        label: String,
        wantMessage: String,
        wantN: Int,
        input: StudioByokInput,
        shrinkCalls: MutableList<String>? = null,
    ) {
        val transport = FakeTransport(200, ByteArray(0))
        val sink = FakeSink()
        val result = StudioByokExecutor(transport, sink, shrink = { _, mime -> shrinkCalls?.add(mime); null }).run(input, CompletableDeferred())
        assertEquals(label, StudioByokTasks.RoundStatus.FAILED, result.status)
        assertEquals(label, StudioImageErrorKind.INVALID_PARAM, result.errorKind)
        assertEquals(label, wantMessage, result.message)
        assertEquals(label, wantN, result.nRequested)
        assertFalse(label, result.mayBeBilled)
        assertEquals(label, 0, result.delivered)
        assertTrue(label, result.images.isEmpty())
        assertTrue(label, transport.sent.isEmpty())
        assertTrue(label, sink.saves.isEmpty())
    }

    @Test
    fun localRejectsDoNotSend() = runBlocking {
        assertLocalReject(
            "operation not in profile",
            "invalid_profile",
            0,
            input(profile = profile("siliconflow_qwen_edit"), operation = ImageOperation.GENERATE),
        )
        assertLocalReject(
            "prompt over profile limit",
            "prompt_too_long",
            0,
            input(profile = profile("openai_gpt_image", JsonObject(mapOf("maxPromptChars" to JsonPrimitive(5)))), prompt = "abcdefghij"),
        )
        assertLocalReject(
            "malformed aspect",
            "invalid_request",
            0,
            input(profile = profile("openai_gpt_image"), params = ImageParamRequest(aspect = "wide")),
        )
        val shrinkCalls = mutableListOf<String>()
        assertLocalReject(
            "reference over the route image limit",
            "references_too_large",
            1,
            input(
                profile = profile("dashscope_qwen_image"),
                operation = ImageOperation.EDIT,
                images = listOf(StudioByokImage(slot = 1, role = "base", mime = "image/png", bytes = ByteArray(8_000_000) { 1 })),
            ),
            shrinkCalls,
        )
        assertEquals(listOf("image/png"), shrinkCalls)
        assertLocalReject(
            "base URL not http(s)",
            "invalid_request",
            1,
            input(profile = profile("openai_gpt_image"), baseUrl = "ftp://example.com"),
        )
    }

    @Test
    fun persistFailureRollsBack() = runBlocking {
        val png = Base64.getEncoder().encodeToString(realImage("image/png", 32, 32))
        val body = """{"data":[{"b64_json":"$png"},{"b64_json":"$png"}]}"""
        val transport = FakeTransport(200, body.toByteArray(Charsets.UTF_8))
        val sink = FakeSink(failOnSave = 2)
        val result = StudioByokExecutor(transport, sink).run(
            input(profile = profile("openai_gpt_image"), params = ImageParamRequest(aspect = "1:1", n = 2)),
            CompletableDeferred(),
        )

        assertEquals(1, transport.sent.size)
        assertEquals(2, sink.saves.size)
        assertEquals(2, sink.saves.toSet().size)
        assertTrue("first stored image is deleted again", sink.saves.first() in sink.deletes)
        assertTrue("nothing stays stored", sink.stored.isEmpty())
        assertEquals(StudioByokTasks.RoundStatus.FAILED, result.status)
        assertEquals(StudioImageErrorKind.STORAGE_FULL, result.errorKind)
        assertNull("storage_full carries no provider message", result.message)
        assertTrue(result.mayBeBilled)
        assertEquals(0, result.delivered)
        assertTrue(result.images.isEmpty())
    }

    private val pngBase64: String by lazy { Base64.getEncoder().encodeToString(realImage("image/png", 16, 16)) }

    private fun okBody(count: Int, usage: String? = null): ByteArray {
        val data = List(count) { """{"b64_json":"$pngBase64"}""" }.joinToString(",")
        val tail = if (usage == null) "" else ""","usage":$usage"""
        return """{"data":[$data]$tail}""".toByteArray(Charsets.UTF_8)
    }

    private fun response(status: Int, body: ByteArray): StudioByokTransport.SendOutcome = StudioByokTransport.SendOutcome.Response(status, body)

    private fun failure(error: Throwable): StudioByokTransport.SendOutcome = StudioByokTransport.SendOutcome.Failure(error, callCanceled = false)

    private val splitParams = ImageParamRequest(aspect = "1:1", n = 6)

    @Test
    fun batchesRewriteN() = runBlocking {
        val profile = profile("together_flux_kontext")
        assertEquals(listOf(4, 2), ImageParamNormalizer.normalize(profile, splitParams).params?.batches)
        // Every batch answers one image more than it asked for; the extra one must be dropped.
        val transport = ScriptedTransport { n, _, _ -> response(200, okBody((n ?: 0) + 1)) }
        val sink = FakeSink()
        val result = StudioByokExecutor(transport, sink).run(
            input(profile = profile, params = splitParams, styleFragment = "in watercolor", effectFragments = listOf("soft glow")),
            CompletableDeferred(),
        )

        assertEquals(listOf(2, 4), transport.calls.map { it.n ?: -1 }.sorted())
        assertEquals(StudioByokTasks.RoundStatus.COMPLETED, result.status)
        assertNull(result.errorKind)
        assertNull(result.message)
        assertEquals(6, result.nRequested)
        assertEquals(6, result.delivered)
        assertEquals(6, result.images.size)
        assertEquals(6, result.images.map { it.id }.toSet().size)
        assertEquals(result.images.map { it.id }, sink.stored.keys.toList())
        val composed = result.composedPrompt ?: error("no composed prompt")
        assertTrue(composed, "in watercolor" in composed)
        assertTrue(composed, "soft glow" in composed)
    }

    @Test
    fun preConnectRetriedOnce() = runBlocking {
        val refused = ConnectException("connection refused")
        assertEquals(StudioByokTasks.Phase.PRE_CONNECT, StudioByokTasks.transportPhase(refused, callCanceled = false))

        val recovers = ScriptedTransport { _, attempt, _ -> if (attempt == 0) failure(refused) else response(200, okBody(1)) }
        val recovered = StudioByokExecutor(recovers, FakeSink()).run(input(profile = profile("openai_gpt_image")), CompletableDeferred())
        assertEquals(listOf(Call(1, 0), Call(1, 1)), recovers.calls)
        assertEquals(StudioByokTasks.RoundStatus.COMPLETED, recovered.status)
        assertTrue("second attempt got a response", recovered.retried)
        assertTrue("2xx is billed", recovered.mayBeBilled)
        assertEquals(1, recovered.delivered)

        val sink = FakeSink()
        val stillDown = ScriptedTransport { _, _, _ -> failure(UnknownHostException("no such host")) }
        val failed = StudioByokExecutor(stillDown, sink).run(input(profile = profile("openai_gpt_image")), CompletableDeferred())
        assertEquals("retried exactly once", 2, stillDown.calls.size)
        assertEquals(StudioByokTasks.RoundStatus.FAILED, failed.status)
        assertEquals(StudioImageErrorKind.NETWORK, failed.errorKind)
        assertTrue(failed.retried)
        assertFalse("nothing reached the provider", failed.mayBeBilled)
        assertEquals(0, failed.delivered)
        assertTrue(sink.saves.isEmpty())
    }

    @Test
    fun afterSendNotRetried() = runBlocking {
        val reset = IOException("unexpected end of stream")
        val timedOut = SocketTimeoutException("timeout")
        assertEquals(StudioByokTasks.Phase.AFTER_SEND, StudioByokTasks.transportPhase(reset, callCanceled = false))
        assertEquals(StudioByokTasks.Phase.TIMEOUT, StudioByokTasks.transportPhase(timedOut, callCanceled = false))

        for ((label, error, kind) in listOf(
            Triple("after_send", reset, StudioImageErrorKind.NETWORK),
            Triple("timeout", timedOut, StudioImageErrorKind.TIMEOUT),
        )) {
            val transport = ScriptedTransport { _, _, _ -> failure(error) }
            val result = StudioByokExecutor(transport, FakeSink()).run(input(profile = profile("openai_gpt_image")), CompletableDeferred())
            assertEquals(label, 1, transport.calls.size)
            assertEquals(label, StudioByokTasks.RoundStatus.FAILED, result.status)
            assertEquals(label, kind, result.errorKind)
            assertFalse(label, result.retried)
            assertTrue(label, result.mayBeBilled)
        }

        val transport = ScriptedTransport { _, attempt, _ -> failure(if (attempt == 0) ConnectException("refused") else reset) }
        val result = StudioByokExecutor(transport, FakeSink()).run(input(profile = profile("openai_gpt_image")), CompletableDeferred())
        assertEquals("the retry itself is never retried", 2, transport.calls.size)
        assertEquals(StudioImageErrorKind.NETWORK, result.errorKind)
        assertTrue(result.retried)
        assertTrue("the retry may have reached the provider", result.mayBeBilled)
    }

    private fun assertCancelled(label: String, result: StudioByokResult, billed: Boolean) {
        assertEquals(label, StudioByokTasks.RoundStatus.CANCELLED, result.status)
        assertNull(label, result.errorKind)
        assertNull(label, result.message)
        assertEquals(label, 0, result.delivered)
        assertTrue(label, result.images.isEmpty())
        assertEquals(label, billed, result.mayBeBilled)
    }

    @Test
    fun cancelDropsImages() = runBlocking {
        val idle = ScriptedTransport { _, _, _ -> response(200, okBody(1)) }
        val early = CompletableDeferred<Unit>().also { it.complete(Unit) }
        val before = StudioByokExecutor(idle, FakeSink()).run(input(profile = profile("openai_gpt_image")), early)
        assertCancelled("cancelled before send", before, billed = false)
        assertTrue("nothing is sent", idle.calls.isEmpty())
        assertFalse(before.retried)

        // A single send cancelled while in flight, with no response yet, may already be billed.
        val inFlightStarted = CompletableDeferred<Unit>()
        val inFlight = ScriptedTransport { _, _, _ ->
            inFlightStarted.complete(Unit)
            awaitCancellation()
        }
        val inFlightCancel = CompletableDeferred<Unit>()
        val inFlightRun = async { StudioByokExecutor(inFlight, FakeSink()).run(input(profile = profile("openai_gpt_image")), inFlightCancel) }
        inFlightStarted.await()
        inFlightCancel.complete(Unit)
        assertCancelled("cancelled while the only send is in flight", inFlightRun.await(), billed = true)
        assertEquals(1, inFlight.cancelledSends)

        // Batch of 4 answers at once, batch of 2 hangs until the round is cancelled.
        val hangStarted = CompletableDeferred<Unit>()
        val split = ScriptedTransport { n, _, _ ->
            if (n == 4) {
                response(200, okBody(4))
            } else {
                hangStarted.complete(Unit)
                awaitCancellation()
            }
        }
        val splitSink = FakeSink()
        val splitCancel = CompletableDeferred<Unit>()
        val running = async { StudioByokExecutor(split, splitSink).run(input(profile = profile("together_flux_kontext"), params = splitParams), splitCancel) }
        hangStarted.await()
        splitCancel.complete(Unit)
        assertCancelled("cancelled while a batch is in flight", running.await(), billed = true)
        assertEquals("the hanging send is cancelled", 1, split.cancelledSends)
        assertTrue(splitSink.saves.isEmpty())

        val sink = FakeSink(hangOnSave = 2)
        val storeCancel = CompletableDeferred<Unit>()
        val storing = async {
            StudioByokExecutor(ScriptedTransport { _, _, _ -> response(200, okBody(2)) }, sink).run(
                input(profile = profile("openai_gpt_image"), params = ImageParamRequest(aspect = "1:1", n = 2)),
                storeCancel,
            )
        }
        sink.hanging.await()
        storeCancel.complete(Unit)
        assertCancelled("cancelled while storing", storing.await(), billed = true)
        assertEquals(2, sink.saves.size)
        assertTrue("every written image is rolled back", sink.deletes.containsAll(sink.saves))
        assertTrue(sink.stored.isEmpty())
    }

    @Test
    fun usageSummed() = runBlocking {
        val profile = profile("together_flux_kontext")
        val withUsage = ScriptedTransport { n, _, _ ->
            if (n == 4) {
                response(200, okBody(4, """{"input_tokens":10,"output_tokens":20,"total_tokens":30}"""))
            } else {
                response(200, okBody(2, """{"input_tokens":1,"output_tokens":2}"""))
            }
        }
        val summed = StudioByokExecutor(withUsage, FakeSink()).run(input(profile = profile, params = splitParams), CompletableDeferred())
        assertEquals(StudioByokTasks.RoundStatus.COMPLETED, summed.status)
        assertEquals(StudioImageResponse.Usage(inputTokens = 11, outputTokens = 22, totalTokens = 30), summed.usage)

        val noUsage = ScriptedTransport { n, _, _ -> response(200, okBody(n ?: 0)) }
        val none = StudioByokExecutor(noUsage, FakeSink()).run(input(profile = profile, params = splitParams), CompletableDeferred())
        assertEquals(StudioByokTasks.RoundStatus.COMPLETED, none.status)
        assertNull("no batch reports usage", none.usage)

        val upstream = "upstream exploded"
        val half = ScriptedTransport { n, _, _ ->
            if (n == 4) response(200, okBody(4, """{"input_tokens":5}""")) else response(500, upstream.toByteArray(Charsets.UTF_8))
        }
        val partial = StudioByokExecutor(half, FakeSink()).run(input(profile = profile, params = splitParams), CompletableDeferred())
        assertEquals(StudioByokTasks.RoundStatus.PARTIAL, partial.status)
        assertEquals(StudioImageErrorKind.UPSTREAM_ERROR, partial.errorKind)
        assertEquals("first non-empty batch message", upstream, partial.message)
        assertEquals(4, partial.delivered)
        assertEquals(StudioImageResponse.Usage(inputTokens = 5, outputTokens = null, totalTokens = null), partial.usage)
    }

    @Test
    fun messageFromErrorKindBatch() = runBlocking {
        // Batch 0 (n=4) answers four undecodable images, batch 1 (n=2) a 400 with a body.
        val undecodable = List(4) { """{"b64_json":"AAAA"}""" }.joinToString(",", prefix = """{"data":[""", postfix = "]}")
        val transport = ScriptedTransport { n, _, _ ->
            if (n == 4) response(200, undecodable.toByteArray(Charsets.UTF_8)) else response(400, "bad request".toByteArray(Charsets.UTF_8))
        }
        val result = StudioByokExecutor(transport, FakeSink()).run(
            input(profile = profile("together_flux_kontext"), params = splitParams),
            CompletableDeferred(),
        )

        assertEquals(StudioByokTasks.RoundStatus.FAILED, result.status)
        assertEquals("the first batch's kind wins", StudioImageErrorKind.DECODE_FAILED, result.errorKind)
        assertNull("message comes from the batch whose kind was chosen", result.message)
        assertEquals(0, result.delivered)
    }

    @Test
    fun extraBadImageDoesNotFailBatch() = runBlocking {
        // n=1, but the provider puts an undecodable image before the good one.
        val body = """{"data":[{"b64_json":"AAAA"},{"b64_json":"$pngBase64","revised_prompt":"a good fox"}]}"""
        val sink = FakeSink()
        val result = StudioByokExecutor(ScriptedTransport { _, _, _ -> response(200, body.toByteArray(Charsets.UTF_8)) }, sink).run(
            input(profile = profile("openai_gpt_image")),
            CompletableDeferred(),
        )

        assertEquals(StudioByokTasks.RoundStatus.COMPLETED, result.status)
        assertNull(result.errorKind)
        assertEquals(1, result.delivered)
        val image = result.images.single()
        assertEquals("a good fox", image.revisedPrompt)
        assertEquals(16, image.width)
        assertEquals(listOf(image.id), sink.stored.keys.toList())
    }

    @Test
    fun responseTooLargeIsUpstreamError() = runBlocking {
        val limit = 41_943_040L + 1_048_576L
        val transport = ScriptedTransport { _, _, _ -> response(200, ByteArray((limit + 1).toInt())) }
        val sink = FakeSink()
        val result = StudioByokExecutor(transport, sink).run(input(profile = profile("openai_gpt_image")), CompletableDeferred())

        assertEquals("one image per batch sets the read limit", listOf(limit), transport.bodyLimits)
        assertEquals(1, transport.calls.size)
        assertEquals(StudioByokTasks.RoundStatus.FAILED, result.status)
        assertEquals(StudioImageErrorKind.UPSTREAM_ERROR, result.errorKind)
        assertEquals("response_too_large", result.message)
        assertTrue("an oversized answer was sent and may be billed", result.mayBeBilled)
        assertFalse(result.retried)
        assertEquals(0, result.delivered)
        assertTrue(sink.saves.isEmpty())

        val split = ScriptedTransport { n, _, _ -> response(200, okBody(n ?: 0)) }
        StudioByokExecutor(split, FakeSink()).run(input(profile = profile("together_flux_kontext"), params = splitParams), CompletableDeferred())
        assertEquals(
            listOf(2 * 41_943_040L + 1_048_576L, 4 * 41_943_040L + 1_048_576L),
            split.bodyLimits.sorted(),
        )
    }

    @Test
    fun cancelKeepsReceivedUsage() = runBlocking {
        val idle = ScriptedTransport { _, _, _ -> response(200, okBody(1, """{"input_tokens":1}""")) }
        val early = CompletableDeferred<Unit>().also { it.complete(Unit) }
        val before = StudioByokExecutor(idle, FakeSink()).run(input(profile = profile("openai_gpt_image")), early)
        assertCancelled("cancelled before send", before, billed = false)
        assertNull("nothing received", before.usage)

        // Batch of 4 answers with usage and URL images; batch of 2 hangs. Cancel once batch 4 is fetching.
        val fetching = CompletableDeferred<Unit>()
        val hangStarted = CompletableDeferred<Unit>()
        val urls = List(4) { """{"url":"https://img.example.com/$it.png"}""" }.joinToString(",")
        val split = ScriptedTransport(
            fetched = {
                fetching.complete(Unit)
                StudioImageResponse.outcomeOf(realImage("image/png", 16, 16))
            },
        ) { n, _, _ ->
            if (n == 4) {
                response(200, """{"data":[$urls],"usage":{"input_tokens":10,"output_tokens":20,"total_tokens":30}}""".toByteArray(Charsets.UTF_8))
            } else {
                hangStarted.complete(Unit)
                awaitCancellation()
            }
        }
        val cancel = CompletableDeferred<Unit>()
        val running = async { StudioByokExecutor(split, FakeSink()).run(input(profile = profile("together_flux_kontext"), params = splitParams), cancel) }
        hangStarted.await()
        fetching.await()
        cancel.complete(Unit)
        val result = running.await()
        assertCancelled("cancelled while a batch is in flight", result, billed = true)
        assertEquals(StudioImageResponse.Usage(inputTokens = 10, outputTokens = 20, totalTokens = 30), result.usage)

        val sink = FakeSink(hangOnSave = 2)
        val storeCancel = CompletableDeferred<Unit>()
        val storing = async {
            StudioByokExecutor(ScriptedTransport { _, _, _ -> response(200, okBody(2, """{"output_tokens":7}""")) }, sink).run(
                input(profile = profile("openai_gpt_image"), params = ImageParamRequest(aspect = "1:1", n = 2)),
                storeCancel,
            )
        }
        sink.hanging.await()
        storeCancel.complete(Unit)
        val stored = storing.await()
        assertCancelled("cancelled while storing", stored, billed = true)
        assertEquals(StudioImageResponse.Usage(inputTokens = null, outputTokens = 7, totalTokens = null), stored.usage)
    }

    @Test
    fun inflightMarkerCoversSend() = runBlocking {
        val dir = Files.createTempDirectory("byok-inflight").toFile()
        try {
            val store = StudioByokInflightStore(dir)
            val marker = File(dir, "round-1.json")
            val profile = profile("openai_gpt_image")
            val timeout = StudioByokTasks.effectiveTimeoutSeconds(profile.timeoutSeconds)
            var seen: JsonObject? = null
            var sentTimeout = -1
            val transport = ScriptedTransport { _, _, timeoutSeconds ->
                seen = Json.parseToJsonElement(marker.readText()).jsonObject
                sentTimeout = timeoutSeconds
                response(200, okBody(1))
            }
            val result = StudioByokExecutor(transport, FakeSink(), inflight = store, now = { 1_234L })
                .run(input(profile = profile), CompletableDeferred())
            assertEquals(StudioByokTasks.RoundStatus.COMPLETED, result.status)
            val written = seen ?: error("marker missing during send")
            assertEquals(1_234L, written.getValue("startedAtMs").jsonPrimitive.long)
            assertEquals(timeout, written.getValue("timeoutSeconds").jsonPrimitive.int)
            assertEquals(timeout, sentTimeout)
            assertFalse("cleared after completion", marker.exists())

            val rejected = StudioByokExecutor(transport, FakeSink(), inflight = store, now = { 1L })
                .run(input(profile = profile("siliconflow_qwen_edit")), CompletableDeferred())
            assertEquals(StudioImageErrorKind.INVALID_PARAM, rejected.errorKind)
            assertTrue("a local reject never marks", dir.listFiles().isNullOrEmpty())

            val started = CompletableDeferred<Unit>()
            val hanging = ScriptedTransport { _, _, _ ->
                started.complete(Unit)
                awaitCancellation()
            }
            val job = async { StudioByokExecutor(hanging, FakeSink(), inflight = store).run(input(profile = profile), CompletableDeferred()) }
            started.await()
            assertTrue("marked while sending", marker.exists())
            job.cancel()
            job.join()
            assertTrue(job.isCancelled)
            assertFalse("cleared when the caller is cancelled", marker.exists())
        } finally {
            dir.deleteRecursively()
        }
    }
}
