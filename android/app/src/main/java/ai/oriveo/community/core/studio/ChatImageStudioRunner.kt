package ai.oriveo.community.core.studio

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.attachment.StoredImage
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ProviderChatResult
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.provider.CostCalculator
import ai.oriveo.community.core.provider.UsageBreakdown
import java.io.IOException
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

/**
 * Runs one chat image send on the studio executor when [ChatImageDispatch] picks studio: resolves the image
 * profile, decides, builds the round with the fixed chat params, runs it and stores every output image like
 * the legacy path (original bytes plus thumbnail). Returns null when the send stays on the legacy path;
 * a failed round throws the mapped [ProviderServiceError]; cancellation is the caller's coroutine
 * cancellation. Behavior follows chat_image_dispatch.v1.
 */
class ChatImageStudioRunner(
    private val transport: StudioByokTransport,
    private val images: ImageStore,
    private val profileSlice: () -> ImageProfileSlice?,
    private val catalogKey: (ProviderKind) -> String?,
    private val pricing: (modelId: String, provider: ProviderKind) -> MetadataClient.ResolvedModelMetadata?,
    private val newId: () -> String = { UUID.randomUUID().toString() },
) {
    /**
     * One chat image send; [attachments] are the attachments of the user message being answered. A null or
     * blank [baseUrl] keeps the legacy path.
     */
    data class Request(
        val provider: ProviderKind,
        val modelId: String,
        val apiKey: String,
        val baseUrl: String?,
        val prompt: String,
        val attachments: List<Attachment>,
    )

    /** Local image library used by a chat image send (production: [AttachmentStore]). */
    interface ImageStore {
        fun loadImageBytes(localImageId: String): ByteArray?

        /** Stores finished image bytes as is plus a thumbnail; null when the bytes do not decode. */
        fun saveOriginalImage(data: ByteArray, id: String): StoredImage?

        fun loadThumbnailBase64(localImageId: String): String?

        fun delete(localImageId: String)
    }

    /**
     * Studio result of a chat image send that the legacy gate already routed to image generation, or null
     * when the dispatch keeps the legacy path or no base URL is known (nothing is sent then).
     */
    suspend fun run(request: Request): ProviderChatResult? {
        val connectionBaseUrl = request.baseUrl?.takeIf { it.isNotBlank() } ?: return null
        // Relay has no official catalog key; managed kinds keep their raw value, both stay legacy in decide.
        val providerKey = catalogKey(request.provider) ?: request.provider.rawValue
        val slice = profileSlice() ?: return null
        val profile = ImageProfileResolver.resolve(slice, providerKey, request.modelId).profile
        val imageAttachments = request.attachments.filter { it.kind == AttachmentKind.Image }
        val localBytes = withContext(Dispatchers.IO) {
            imageAttachments.mapNotNull { attachment ->
                attachment.localImageId?.let { id -> images.loadImageBytes(id)?.let { attachment.id to it } }
            }.toMap()
        }
        val decision = ChatImageDispatch.decide(
            providerKind = providerKey,
            legacyImageDispatch = true,
            profile = profile,
            attachments = imageAttachments.map { ChatImageDispatch.Candidate(it.id, hasBytes = it.id in localBytes) },
        )
        if (decision !is ChatImageDispatch.Decision.Studio || profile == null) return null
        // The studio base URL depends on the route, so it is derived once the profile is known.
        val baseUrl = ChatImageDispatch.studioBaseUrl(profile.route.wire, connectionBaseUrl) ?: return null

        val byId = imageAttachments.associateBy { it.id }
        val references = decision.images.map { pick ->
            StudioByokImage(pick.slot, pick.role, byId.getValue(pick.attachmentId).mimeType, localBytes.getValue(pick.attachmentId))
        }
        val storedMimes = ConcurrentHashMap<String, String>()
        val executor = StudioByokExecutor(transport = transport, sink = sink(storedMimes), newId = newId)
        val result = executor.run(
            StudioByokInput(
                roundId = newId(),
                providerKind = providerKey,
                apiKey = request.apiKey,
                baseUrl = baseUrl,
                modelId = request.modelId,
                profile = profile,
                operation = decision.operation,
                prompt = request.prompt,
                params = ChatImageDispatch.chatParams,
                images = references,
            ),
            CompletableDeferred(),
        )
        return when (result.status) {
            StudioByokTasks.RoundStatus.COMPLETED, StudioByokTasks.RoundStatus.PARTIAL -> chatResult(request, result, storedMimes)
            StudioByokTasks.RoundStatus.CANCELLED -> throw CancellationException("chat image round cancelled")
            StudioByokTasks.RoundStatus.FAILED -> {
                val kind = result.errorKind ?: StudioImageErrorKind.DECODE_FAILED
                throw ChatImageDispatch.chatFailure(kind, result.message.orEmpty()) ?: ProviderServiceError.EmptyResponse
            }
        }
    }

    /** Executor sink over [images]: same store call as the legacy path; a non-decodable image fails the round. */
    private fun sink(storedMimes: MutableMap<String, String>): StudioByokImageSink = object : StudioByokImageSink {
        override suspend fun save(id: String, bytes: ByteArray) = withContext(Dispatchers.IO) {
            val stored = images.saveOriginalImage(bytes, id) ?: throw IOException("generated image does not decode")
            storedMimes[id] = stored.mimeType
        }

        override suspend fun delete(id: String) = withContext(Dispatchers.IO) { images.delete(id) }
    }

    /** Chat result of a finished round: empty text, one image attachment per output in order, legacy usage and cost. */
    private suspend fun chatResult(
        request: Request,
        result: StudioByokResult,
        storedMimes: Map<String, String>,
    ): ProviderChatResult {
        if (result.images.isEmpty()) throw ProviderServiceError.EmptyResponse
        val attachments = withContext(Dispatchers.IO) {
            result.images.map { image ->
                // The store reports the real stored format (it may re-encode); the legacy path uses it too.
                val mime = storedMimes[image.id] ?: image.mime
                Attachment(
                    id = newId(),
                    kind = AttachmentKind.Image,
                    fileName = "$GENERATED_FILE_NAME.${extensionOf(mime)}",
                    mimeType = mime,
                    localImageId = image.id,
                    thumbnailBase64 = images.loadThumbnailBase64(image.id),
                )
            }
        }
        val usage = result.usage
        val breakdown = UsageBreakdown(
            promptTokens = usage?.inputTokens?.toIntClamped() ?: 0,
            completionTokens = usage?.outputTokens?.toIntClamped() ?: 0,
        )
        val (cost, source) = CostCalculator.calcCost(breakdown, pricing(request.modelId, request.provider), at = Instant.now())
        return ProviderChatResult(
            text = "",
            promptTokens = breakdown.promptTokens,
            completionTokens = breakdown.completionTokens,
            estimatedCost = cost,
            attachments = attachments,
            costSource = source.name,
            usageReported = usage != null,
        )
    }

    companion object {
        private const val GENERATED_FILE_NAME = "generated_image"

        /** Plain client for chat image sends: no App Check or auth interceptors, the provider key goes in the request. */
        private val defaultClient: OkHttpClient by lazy { OkHttpClient() }

        /**
         * Studio transport for chat sends: always compiled in, so chat image generation keeps working when the
         * Studio compile switch is off.
         */
        fun httpTransport(client: OkHttpClient): StudioByokTransport =
            StudioByokHttpTransport(StudioHttpTransport(client, isCompiledIn = true), StudioImageFetcher(client))

        /** Production runner over the attachment store and the published metadata snapshot. */
        fun create(
            store: AttachmentStore,
            metadata: MetadataClient = MetadataClient.instance,
            client: OkHttpClient = defaultClient,
        ): ChatImageStudioRunner = ChatImageStudioRunner(
            transport = httpTransport(client),
            images = attachmentImages(store),
            profileSlice = metadata::imageProfileSlice,
            catalogKey = metadata::catalogKey,
            pricing = { modelId, provider -> metadata.resolveCatalogModel(modelId, provider) },
        )

        fun attachmentImages(store: AttachmentStore): ImageStore = object : ImageStore {
            override fun loadImageBytes(localImageId: String): ByteArray? = store.loadImageBytes(localImageId)

            override fun saveOriginalImage(data: ByteArray, id: String): StoredImage? = store.saveOriginalImage(data, id)

            override fun loadThumbnailBase64(localImageId: String): String? = store.loadThumbnailBase64(localImageId)

            override fun delete(localImageId: String) = store.delete(localImageId)
        }

        private fun extensionOf(mime: String): String = when {
            mime.contains("jpeg") || mime.contains("jpg") -> "jpg"
            mime.contains("webp") -> "webp"
            else -> "png"
        }

        private fun Long.toIntClamped(): Int = coerceIn(0L, Int.MAX_VALUE.toLong()).toInt()
    }
}
