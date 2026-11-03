package ai.oriveo.community.core.studio

import ai.oriveo.community.core.data.attachment.AttachmentStore
import java.util.Collections
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive

/** One reference image of a BYOK round; [bytes] are the original picked bytes. */
class StudioByokImage(val slot: Int, val role: String, val mime: String, val bytes: ByteArray)

/**
 * Input of one BYOK image round. [profile] is an already validated ImageProfile (the executor only checks
 * that [operation] is one of its operations); the prompt limit is profile.maxPromptChars,
 * [DEFAULT_MAX_PROMPT_CHARS] when absent. [styleFragment] / [effectFragments] go into the prompt composer as is.
 */
data class StudioByokInput(
    val roundId: String,
    val providerKind: String,
    val apiKey: String,
    val baseUrl: String,
    val modelId: String,
    val profile: ImageProfile,
    val operation: ImageOperation,
    val prompt: String,
    val params: ImageParamRequest,
    val advanced: ImageRequestAdvanced = ImageRequestAdvanced(),
    val images: List<StudioByokImage> = emptyList(),
    val styleFragment: String? = null,
    val effectFragments: List<String> = emptyList(),
) {
    companion object {
        const val DEFAULT_MAX_PROMPT_CHARS = 32_000
    }
}

/** One stored output image; [id] is its local image id in the attachment store. */
data class StudioByokOutputImage(
    val id: String,
    val mime: String,
    val width: Int,
    val height: Int,
    val revisedPrompt: String?,
)

/** Result of one BYOK round; never thrown, always returned. */
data class StudioByokResult(
    val status: StudioByokTasks.RoundStatus,
    val errorKind: StudioImageErrorKind?,
    val message: String?,
    val mayBeBilled: Boolean,
    val retried: Boolean,
    val nRequested: Int,
    val delivered: Int,
    val composedPrompt: String?,
    val adjustments: Adjustments,
    val usage: StudioImageResponse.Usage?,
    val images: List<StudioByokOutputImage>,
) {
    data class Adjustments(
        val prompt: List<StudioPromptComposer.Adjustment> = emptyList(),
        val params: List<ImageParamAdjustment> = emptyList(),
    )
}

/** HTTP side of the executor; the real one wraps OkHttp, tests pass a fake. */
interface StudioByokTransport {
    sealed interface SendOutcome {
        /** A response arrived (any status); [body] holds at most maxBodyBytes + 1 bytes. */
        class Response(val status: Int, val body: ByteArray) : SendOutcome

        /** No response; [callCanceled] is true when the call itself was canceled. */
        class Failure(val error: Throwable, val callCanceled: Boolean) : SendOutcome
    }

    /**
     * Reads at most [maxBodyBytes] + 1 body bytes, so a longer body comes back exactly one byte over the limit.
     * A failure that never left the device must classify as pre_connect.
     */
    suspend fun send(request: ImageHttpRequest, timeoutSeconds: Int, maxBodyBytes: Long): SendOutcome

    /** Downloads one URL image (normally [StudioImageFetcher.fetch]). */
    suspend fun fetchImage(url: String): StudioImageResponse.Outcome
}

/** Where output images are written; ids are fresh UUIDs from the executor. */
interface StudioByokImageSink {
    suspend fun save(id: String, bytes: ByteArray)

    suspend fun delete(id: String)

    companion object {
        /** Default sink: raw bytes into the attachment image library, on [Dispatchers.IO]. */
        fun attachments(store: AttachmentStore): StudioByokImageSink = object : StudioByokImageSink {
            override suspend fun save(id: String, bytes: ByteArray) = withContext(Dispatchers.IO) { store.saveImageRaw(id, bytes) }

            override suspend fun delete(id: String) = withContext(Dispatchers.IO) { store.delete(id) }
        }
    }
}

/**
 * Runs one BYOK image round: profile check, prompt compose, param normalize, reference fit, request build,
 * send, classify, parse, URL fetch, assemble, aggregate, then store.
 */
class StudioByokExecutor(
    private val transport: StudioByokTransport,
    private val sink: StudioByokImageSink,
    private val shrink: suspend (ByteArray, String) -> Pair<ByteArray, String>? = StudioReferenceShrinker::shrink,
    private val newId: () -> String = { UUID.randomUUID().toString() },
    private val inflight: StudioByokInflightStore? = null,
    private val now: () -> Long = System::currentTimeMillis,
) {
    /** Outcome of one batch before aggregation. */
    private class BatchOutcome(
        val images: List<Pair<StudioImageResponse.DeliveredImage, String?>>,
        val errorKind: StudioImageErrorKind?,
        val message: String?,
        val usage: StudioImageResponse.Usage?,
    )

    /**
     * Per-round flags shared by concurrent batches; written from batch coroutines, read after they end.
     * [sent] is set once an attempt ends any way but a pre_connect failure, a cancelled in-flight send included.
     */
    private class RoundFlags {
        @Volatile var sent = false
        @Volatile var billed = false
        @Volatile var retried = false

        /** Usage of every batch whose response was parsed, kept for a cancelled round. */
        val usages: MutableList<StudioImageResponse.Usage> = Collections.synchronizedList(mutableListOf())
    }

    /**
     * Never throws except for coroutine cancellation. Batches run concurrently; completing [cancel] before the
     * first send returns cancelled without sending, completing it later cancels the batches (or the store) and
     * rolls back every written image. The in-flight marker covers the whole send.
     */
    suspend fun run(input: StudioByokInput, cancel: CompletableDeferred<Unit>): StudioByokResult {
        val profile = input.profile
        // Rejects before a successful normalize report nRequested 0: no batch size is known yet.
        if (input.operation !in profile.operations) return localReject(INVALID_PROFILE, 0)

        // References are numbered in send order: base first, then ascending slot (same order fit and build use).
        val ordered = input.images.sortedWith(compareBy({ it.role != BASE_ROLE }, { it.slot }))
        val composed = StudioPromptComposer.compose(
            StudioPromptComposer.SPEC,
            StudioPromptComposer.Input(
                userPrompt = input.prompt,
                references = ordered.mapIndexed { index, image -> StudioPromptComposer.Reference(index + 1, image.role) },
                styleFragment = input.styleFragment,
                effectFragments = input.effectFragments,
                maxPromptChars = profile.maxPromptChars ?: StudioByokInput.DEFAULT_MAX_PROMPT_CHARS,
            ),
        )
        val prompt = composed.composed
            ?: return localReject(composed.error?.wire ?: StudioPromptComposer.Error.PROMPT_TOO_LONG.wire, 0)

        val normalized = ImageParamNormalizer.normalize(profile, input.params)
        val params = normalized.params
            ?: return localReject(
                normalized.error?.wire ?: ImageParamError.INVALID_REQUEST.wire,
                0,
                prompt,
                StudioByokResult.Adjustments(prompt = composed.adjustments),
            )
        val adjustments = StudioByokResult.Adjustments(prompt = composed.adjustments, params = params.adjustments)
        val nRequested = params.batches.sum()
        if (params.batches.isEmpty()) return localReject(ImageParamError.INVALID_REQUEST.wire, nRequested, prompt, adjustments)

        val fit = StudioReferenceBudget.fit(
            route = profile.route.wire,
            editTransport = profile.editTransport?.wire,
            prompt = prompt,
            images = ordered,
            describe = { StudioReferenceBudget.Item(it.slot, it.role, it.mime, it.bytes.size.toLong()) },
            shrink = { image -> shrink(image.bytes, image.mime)?.let { (bytes, mime) -> StudioByokImage(image.slot, image.role, mime, bytes) } },
        )
        if (fit.status != StudioReferenceBudget.Status.FITS) {
            return localReject(REFERENCES_TOO_LARGE, nRequested, prompt, adjustments)
        }
        val references = fit.images.map { ImageRequestImage(it.slot, it.role, it.mime, it.bytes) }

        val requests = params.batches.map { count ->
            val built = ImageRequestBuilder.build(
                profile,
                ImageRequestInput(
                    operation = input.operation,
                    modelId = input.modelId,
                    prompt = prompt,
                    wire = batchWire(params.wire, count),
                    images = references,
                    advanced = input.advanced,
                    baseUrl = input.baseUrl,
                    apiKey = input.apiKey,
                ),
            )
            built.request
                ?: return localReject(built.error?.wire ?: ImageRequestError.INVALID_REQUEST.wire, nRequested, prompt, adjustments)
        }

        val flags = RoundFlags()
        val base = StudioByokResult(
            status = StudioByokTasks.RoundStatus.CANCELLED,
            errorKind = null,
            message = null,
            mayBeBilled = false,
            retried = false,
            nRequested = nRequested,
            delivered = 0,
            composedPrompt = prompt,
            adjustments = adjustments,
            usage = null,
            images = emptyList(),
        )
        if (cancel.isCompleted) return cancelled(base, flags)

        val timeout = StudioByokTasks.effectiveTimeoutSeconds(profile.timeoutSeconds)
        try {
            inflight?.mark(input.roundId, now(), timeout)
            return coroutineScope {
                val work = async {
                    val outcomes = requests.mapIndexed { index, request ->
                        async { sendBatch(request, params.batches[index], timeout, flags) }
                    }.awaitAll()
                    val aggregate = StudioByokTasks.aggregate(
                        n = nRequested,
                        batches = params.batches,
                        results = outcomes.map { StudioByokTasks.BatchResult(it.images.size, it.errorKind) },
                        cancelled = false,
                    )
                    // The message belongs to the batch whose kind the aggregate picked (the first batch with a kind).
                    val message = if (aggregate.status == StudioByokTasks.RoundStatus.COMPLETED) {
                        null
                    } else {
                        outcomes.firstOrNull { it.errorKind != null }
                            ?.takeIf { it.errorKind == aggregate.errorKind }
                            ?.message
                            ?.takeIf { it.isNotEmpty() }
                    }
                    val result = base.copy(
                        status = aggregate.status,
                        errorKind = aggregate.errorKind,
                        message = message,
                        mayBeBilled = flags.billed,
                        retried = flags.retried,
                        delivered = aggregate.delivered,
                        usage = sumUsage(outcomes.map { it.usage }),
                    )
                    persist(result, outcomes.flatMap { it.images }.take(aggregate.delivered))
                }
                val finished = select<StudioByokResult?> {
                    work.onAwait { it }
                    cancel.onAwait { null }
                }
                if (finished != null) {
                    finished
                } else {
                    work.cancelAndJoin()
                    cancelled(base, flags)
                }
            }
        } finally {
            withContext(NonCancellable) { inflight?.clear(input.roundId) }
        }
    }

    /** Sends one batch; only a pre_connect failure of the first attempt is retried, once. */
    private suspend fun sendBatch(request: ImageHttpRequest, count: Int, timeout: Int, flags: RoundFlags): BatchOutcome {
        var attempt = 0
        while (true) {
            // A send that is cancelled before it ends counts as sent: the body may already be on the wire.
            val outcome = try {
                transport.send(request, timeout, maxBodyBytes(count))
            } catch (e: CancellationException) {
                flags.sent = true
                throw e
            }
            when (val sent = outcome) {
                is StudioByokTransport.SendOutcome.Failure -> {
                    val phase = StudioByokTasks.transportPhase(sent.error, sent.callCanceled)
                    val decision = StudioByokTasks.retryDecision(phase, attempt)
                    if (phase != StudioByokTasks.Phase.PRE_CONNECT) flags.sent = true
                    if (decision.mayBeBilled) flags.billed = true
                    if (decision.retried) flags.retried = true
                    if (decision.retry) {
                        attempt++
                        continue
                    }
                    return BatchOutcome(emptyList(), decision.errorKind ?: StudioImageErrorKind.NETWORK, message = null, usage = null)
                }
                is StudioByokTransport.SendOutcome.Response -> {
                    flags.sent = true
                    if (sent.status in 200..299) flags.billed = true
                    if (attempt > 0) flags.retried = true
                    if (sent.body.size > maxBodyBytes(count)) {
                        flags.billed = true
                        return BatchOutcome(emptyList(), StudioImageErrorKind.UPSTREAM_ERROR, RESPONSE_TOO_LARGE, usage = null)
                    }
                    return responseBatch(sent, count, flags)
                }
            }
        }
    }

    private fun cancelled(base: StudioByokResult, flags: RoundFlags): StudioByokResult {
        val aggregate = StudioByokTasks.aggregate(n = base.nRequested, batches = emptyList(), results = emptyList(), cancelled = true)
        return base.copy(
            status = aggregate.status,
            errorKind = aggregate.errorKind,
            mayBeBilled = flags.billed || flags.sent,
            retried = flags.retried,
            delivered = aggregate.delivered,
            usage = sumUsage(flags.usages.toList()),
        )
    }

    /**
     * Decodes on [Dispatchers.Default]. Every returned image is materialized, then the first [count] that
     * decoded are kept, so an extra bad image does not fail the batch.
     */
    private suspend fun responseBatch(
        response: StudioByokTransport.SendOutcome.Response,
        count: Int,
        flags: RoundFlags,
    ): BatchOutcome = withContext(Dispatchers.Default) {
        val text = response.body.decodeToString()
        val body = bodyElement(text)
        val kind = StudioImageError.classify(response.status, body, count)
        if (kind != null && kind != StudioImageErrorKind.PARTIAL) {
            return@withContext BatchOutcome(emptyList(), kind, message = text.take(MESSAGE_LIMIT), usage = null)
        }
        val parsed = StudioImageResponse.parse(body)
        parsed.usage?.let { flags.usages += it }
        val sources = parsed.images
        val outcomes = sources.map { StudioImageResponse.materialize(it) { url -> transport.fetchImage(url) } }
        val assembly = StudioImageResponse.assemble(count, outcomes)
        val delivered = outcomes.zip(sources).mapNotNull { (outcome, source) ->
            (outcome as? StudioImageResponse.Outcome.Ok)?.let { it.image to source.revisedPrompt }
        }.take(count)
        val errorKind = when (val delivery = assembly.result) {
            StudioImageResponse.Delivery.Ok -> null
            StudioImageResponse.Delivery.Partial -> StudioImageErrorKind.PARTIAL
            is StudioImageResponse.Delivery.Failed -> errorKindOf(delivery.failure)
            null -> StudioImageErrorKind.DECODE_FAILED
        }
        BatchOutcome(delivered, errorKind, message = null, usage = parsed.usage)
    }

    /** Stores every image under a fresh id; any failure deletes all of them and turns the round into storage_full. */
    private suspend fun persist(
        result: StudioByokResult,
        images: List<Pair<StudioImageResponse.DeliveredImage, String?>>,
    ): StudioByokResult {
        val written = mutableListOf<String>()
        val stored = mutableListOf<StudioByokOutputImage>()
        for ((image, revisedPrompt) in images) {
            val id = newId()
            try {
                written += id
                sink.save(id, image.bytes)
            } catch (e: CancellationException) {
                withContext(NonCancellable) { rollback(written) }
                throw e
            } catch (e: Exception) {
                rollback(written)
                return result.copy(
                    status = StudioByokTasks.RoundStatus.FAILED,
                    errorKind = StudioImageErrorKind.STORAGE_FULL,
                    message = null,
                    delivered = 0,
                    images = emptyList(),
                )
            }
            stored += StudioByokOutputImage(id, image.mime, image.width, image.height, revisedPrompt)
        }
        return result.copy(images = stored)
    }

    /** Deletes every id, the one whose write failed included; a failing delete does not stop the rest. */
    private suspend fun rollback(ids: List<String>) {
        for (id in ids) {
            try {
                sink.delete(id)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                continue
            }
        }
    }

    private fun localReject(
        message: String,
        nRequested: Int,
        composedPrompt: String? = null,
        adjustments: StudioByokResult.Adjustments = StudioByokResult.Adjustments(),
    ) = StudioByokResult(
        status = StudioByokTasks.RoundStatus.FAILED,
        errorKind = StudioImageErrorKind.INVALID_PARAM,
        message = message,
        mayBeBilled = false,
        retried = false,
        nRequested = nRequested,
        delivered = 0,
        composedPrompt = composedPrompt,
        adjustments = adjustments,
        usage = null,
        images = emptyList(),
    )

    private companion object {
        const val BASE_ROLE = "base"
        const val INVALID_PROFILE = "invalid_profile"
        const val REFERENCES_TOO_LARGE = "references_too_large"
        const val MESSAGE_LIMIT = 1000
        const val RESPONSE_TOO_LARGE = "response_too_large"
        const val BYTES_PER_IMAGE = 41_943_040L
        const val BODY_OVERHEAD_BYTES = 1_048_576L

        /** Response body cap of a batch of [count] images. */
        fun maxBodyBytes(count: Int): Long = count.coerceAtLeast(0) * BYTES_PER_IMAGE + BODY_OVERHEAD_BYTES
        val N_KEYS = setOf("n", "parameters.n")

        /** Copy of [wire] with an existing n / parameters.n set to the batch size. */
        fun batchWire(wire: Map<String, JsonPrimitive>, count: Int): Map<String, JsonPrimitive> =
            wire.mapValues { (key, value) -> if (key in N_KEYS) JsonPrimitive(count) else value }

        /** Parsed JSON body, the raw text as a JSON string when it is not JSON, null when empty. */
        fun bodyElement(text: String): JsonElement? {
            if (text.isEmpty()) return null
            return try {
                Json.parseToJsonElement(text)
            } catch (e: SerializationException) {
                JsonPrimitive(text)
            }
        }

        /** Field-wise sum of the batches' usage; null when no batch reported any. */
        fun sumUsage(usages: List<StudioImageResponse.Usage?>): StudioImageResponse.Usage? {
            val present = usages.filterNotNull()
            if (present.isEmpty()) return null
            fun sum(field: (StudioImageResponse.Usage) -> Long?): Long? = present.mapNotNull(field).takeIf { it.isNotEmpty() }?.sum()
            return StudioImageResponse.Usage(sum { it.inputTokens }, sum { it.outputTokens }, sum { it.totalTokens })
        }

        fun errorKindOf(failure: StudioImageResponse.Failure): StudioImageErrorKind = when (failure) {
            StudioImageResponse.Failure.NETWORK -> StudioImageErrorKind.NETWORK
            StudioImageResponse.Failure.TIMEOUT -> StudioImageErrorKind.TIMEOUT
            StudioImageResponse.Failure.DECODE_FAILED -> StudioImageErrorKind.DECODE_FAILED
        }
    }
}
