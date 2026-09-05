package ai.oriveo.community.core.provider

import ai.oriveo.community.core.attachments.AttachmentInjector
import ai.oriveo.community.core.attachments.AttachmentRoute
import ai.oriveo.community.core.attachments.AttachmentRouter
import ai.oriveo.community.core.attachments.AttachmentWrapperVersion
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractedText
import ai.oriveo.community.core.attachments.FileExtractionLimits
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Base64

/**
 * Shared message-construction helper.
 *
 * Builds the multi-part message body (as a JSON string) that carries attachments, in whatever
 * shape the target provider expects. Every provider formats image, file and text attachments
 * differently, so the dispatch lives here in one place instead of being copied per service.
 */
object MessageBuilder {

    /**
     * Normalizes the outbound message list right before a request goes out.
     *
     * Two steps:
     *  1. Filtering. Messages with no content at all (no text and no attachments) are dropped.
     *     Everything in the user role is kept, along with every history assistant message that has
     *     content and is not failed (delivered, an interrupted partial the user stopped on purpose,
     *     or a generating partial that a race left un-finalized), plus the explicit continue/retry
     *     target ([keepAssistantId]). Only failed turns are dropped: a question whose answer failed
     *     is not usable context, and on some surfaces the empty placeholder of a failed message gets
     *     filled in with localized error copy, so keeping it would send the error string to the
     *     model as if it were the assistant's answer. The empty-content check runs before the
     *     keepAssistantId check: a failed assistant being retried is dropped when its text is empty
     *     even though it is the keepId, because the retry revives it as a prefill afterwards.
     *  2. Collapsing adjacent same-role messages. Once step 1 has removed an empty assistant from
     *     the middle, the two user messages it used to separate become adjacent and the roles no
     *     longer alternate. Strict OpenAI-compatible relays require user/assistant to alternate and
     *     reject two consecutive messages in the same role outright.
     *     - Adjacent user messages: discard the earlier one and keep only the newest. The answer to
     *       the earlier question already failed or was abandoned, and two independent questions must
     *       not be fused into one prompt for the model to answer together (that is the root cause of
     *       the "asked something new after stopping and got both answered at once" report).
     *     - Adjacent assistant messages (rare): merge them instead, joining text with a blank line
     *       and concatenating attachments in order, so no real answer content is lost.
     *
     * Note: an interrupted or failed assistant that does have partial text naturally separates the
     * two user messages around it, so in most cases the adjacent-user rule never fires at all. Only
     * "stopped early, partial is empty" reaches the branch that discards the older user message.
     */
    fun sanitizeOutboundMessages(
        messages: List<ChatMessage>,
        keepAssistantId: String? = null,
    ): List<ChatMessage> {
        val filtered = messages.mapNotNull { msg ->
            // An assistant message must never carry an image or video media content part. In the
            // OpenAI-compatible protocols image_url is only valid in the user role. Images the model
            // generated are stored on the assistant message, and sending them back verbatim is
            // rejected by upstreams such as Qwen ("incorrect modal `image` placed in the wrong
            // position, e.g. in assistant"). After the user switches to a text-only model, such a
            // history image turns into an Upstream 400, so outbound normalization strips media
            // attachments off assistant messages. If that leaves the message with neither text nor
            // any remaining attachment, the hasContent check below drops it entirely.
            val normalized = if (msg.role == ChatRole.Assistant && !msg.attachments.isNullOrEmpty()) {
                val kept = msg.attachments.filter {
                    it.kind != AttachmentKind.Image && it.kind != AttachmentKind.Video
                }
                msg.copy(attachments = kept.takeIf { it.isNotEmpty() })
            } else {
                msg
            }

            val hasContent = normalized.text.isNotBlank() || !normalized.attachments.isNullOrEmpty()
            if (!hasContent) return@mapNotNull null
            // Keep: every user message; the explicit continue/retry target (keepAssistantId, revived
            // as a prefill even when it is failed); and every non-failed history message that has
            // content (delivered, an interrupted partial the user stopped on purpose, a generating
            // partial that a race left un-finalized). Those naturally separate the two user messages
            // around them, so the model does not treat the previous question as unanswered and
            // answer it again. Only failed turns are dropped: a failed question is not valid
            // context, and the empty placeholder of a failed message gets filled in with localized
            // error copy on some surfaces, so keeping it would feed the error string to the model as
            // a fake answer and repeat it every turn. Retrying after a failure revives the message
            // as a prefill through keepAssistantId, so that path is unaffected.
            val keep = normalized.role == ChatRole.User ||
                normalized.id == keepAssistantId ||
                normalized.state != ChatMessageState.Failed
            if (keep) normalized else null
        }

        val merged = mutableListOf<ChatMessage>()
        for (msg in filtered) {
            val last = merged.lastOrNull()
            if (last != null && last.role == msg.role) {
                if (msg.role == ChatRole.User) {
                    // Two adjacent user messages can only come from the assistant between them
                    // having been dropped (the previous answer failed, or the user interrupted it
                    // with an empty partial, or it was a pure image generation that went empty once
                    // the image was stripped). Discard the earlier user message and keep only the
                    // newest: that restores strict user/assistant alternation and avoids fusing two
                    // independent questions into one prompt for the model to answer together (the
                    // root cause of the "asked something new after stopping and got both answered at
                    // once" report).
                    merged[merged.size - 1] = msg
                } else {
                    // Adjacent assistant messages (rare) are merged instead, so no real answer
                    // content is lost.
                    val joinedText = listOf(last.text.trim(), msg.text.trim())
                        .filter { it.isNotEmpty() }
                        .joinToString("\n\n")
                    val joinedAttachments = last.attachments.orEmpty() + msg.attachments.orEmpty()
                    merged[merged.size - 1] = last.copy(
                        text = joinedText,
                        attachments = joinedAttachments.takeIf { it.isNotEmpty() },
                    )
                }
            } else {
                merged.add(msg)
            }
        }
        return merged
    }

    /**
     * Builds the message-array JSON in OpenRouter / OpenAI Chat Completions format.
     * Supports image_url (base64 data URI) and file content parts.
     */
    fun buildOpenAIMessages(
        messages: List<ChatMessage>,
        providerKind: ProviderKind,
        systemPrompt: String? = null,
    ): String {
        val payloads = mutableListOf<String>()
        if (!systemPrompt.isNullOrBlank()) {
            payloads.add("""{"role":"system","content":${escapeJsonString(systemPrompt.trim())}}""")
        }
        payloads += messages.map { msg ->
            val role = msg.role.name.lowercase()
            val parts = buildOpenAIParts(msg, providerKind)
            if (parts != null) {
                """{"role":"$role","content":[$parts]}"""
            } else {
                """{"role":"$role","content":${escapeJsonString(msg.text)}}"""
            }
        }
        return payloads.joinToString(",")
    }

    /**
     * The single entry point for building Chat Completions style messages: it dispatches to each
     * provider's own format.
     *
     * Both ordinary chat ([OpenAICompatibleService.buildMessagesJson]) and the library retrieval leg
     * have to come through here. The retrieval leg used to call [buildOpenAIMessages] directly,
     * which bypassed the folding path for DeepSeek (it accepts a string content only), so a leg
     * request carrying attachments went out with array parts and was rejected with a 400.
     */
    fun buildChatCompletionsMessages(
        messages: List<ChatMessage>,
        providerKind: ProviderKind,
        systemPrompt: String? = null,
    ): String = when (providerKind) {
        ProviderKind.DeepSeek -> buildDeepSeekMessages(messages, systemPrompt)
        else -> buildOpenAIMessages(messages, providerKind, systemPrompt)
    }

    /**
     * Builds the message-array JSON in Grok (xAI) Chat Completions format.
     * Grok is OpenAI-compatible and supports multi-part content (image_url data URI plus text).
     * Behaviourally identical to buildOpenAIMessages, but bound explicitly to ProviderKind.Grok so
     * that attachment support is resolved against the right provider.
     */
    fun buildGrokMessages(
        messages: List<ChatMessage>,
        systemPrompt: String? = null,
    ): String = buildOpenAIMessages(
        messages = messages,
        providerKind = ProviderKind.Grok,
        systemPrompt = systemPrompt,
    )

    /**
     * Builds the message-array JSON in DeepSeek Chat Completions format.
     * DeepSeek currently accepts a string content only, so attachments have to be folded into
     * plain text.
     */
    fun buildDeepSeekMessages(
        messages: List<ChatMessage>,
        systemPrompt: String? = null,
    ): String {
        val payloads = mutableListOf<String>()
        if (!systemPrompt.isNullOrBlank()) {
            payloads.add("""{"role":"system","content":${escapeJsonString(systemPrompt.trim())}}""")
        }
        payloads += messages.map { msg ->
            val role = msg.role.name.lowercase()
            val content = buildDeepSeekContent(msg)
            """{"role":"$role","content":${escapeJsonString(content)}}"""
        }
        return payloads.joinToString(",")
    }

    /**
     * Builds the input-array JSON for the OpenAI Responses API.
     * Images become input_image, binary files become input_file, and text files are inlined into
     * input_text. Passing activeModel enables the [AttachmentRouter] decision, i.e. whether a PDF or
     * an Office document goes up natively or is extracted on the client first.
     */
    fun buildOpenAIResponsesInput(messages: List<ChatMessage>, activeModel: AIModel? = null): String {
        return messages.joinToString(",") { msg ->
            val role = msg.role.name.lowercase()
            val parts = buildOpenAIResponsesParts(msg, activeModel)
            val textType = if (msg.role == ChatRole.Assistant) "output_text" else "input_text"
            val canonicalParts = parts
                ?: """{"type":"$textType","text":${escapeJsonString(msg.text)}}"""
            """{"role":"$role","content":[$canonicalParts]}"""
        }
    }

    /**
     * Builds the message-array JSON in Anthropic Messages API format.
     * image -> base64 source, document -> base64 source, text file -> inline text.
     * Passing activeModel enables the router; document and image blocks automatically get
     * cache_control: ephemeral.
     */
    fun buildAnthropicMessages(messages: List<ChatMessage>, activeModel: AIModel? = null): String {
        return messages.joinToString(",") { msg ->
            val role = msg.role.name.lowercase()
            val parts = buildAnthropicParts(msg, activeModel)
            if (parts != null) {
                """{"role":"$role","content":[$parts]}"""
            } else {
                """{"role":"$role","content":${escapeJsonString(msg.text)}}"""
            }
        }
    }

    /**
     * Builds the contents JSON for Gemini generateContent.
     * inlineData for images and files, text parts for text.
     * Passing activeModel enables the router; when pdfNativeDefault is true every PDF goes up
     * natively.
     */
    fun buildGeminiContents(messages: List<ChatMessage>, activeModel: AIModel? = null): String {
        return messages.joinToString(",") { msg ->
            val role = if (msg.role == ChatRole.Assistant) "model" else "user"
            val parts = buildGeminiParts(msg, activeModel)
            """{"role":"$role","parts":[$parts]}"""
        }
    }

    /**
     * Buckets file attachments according to the [AttachmentRouter] decision.
     * When model is null, or the decision cannot be made, everything falls into the text path, which
     * means client-side extraction.
     */
    private fun partitionFileAttachments(
        attachments: List<Attachment>,
        provider: ProviderKind,
        model: AIModel?,
    ): Pair<List<Attachment>, List<Attachment>> {
        if (model == null) return Pair(emptyList(), attachments.filter { it.kind == AttachmentKind.File })
        val files = attachments.filter { it.kind == AttachmentKind.File }
        val native = mutableListOf<Attachment>()
        val text = mutableListOf<Attachment>()
        for (att in files) {
            when (AttachmentRouter.decide(att, provider, model)) {
                AttachmentRoute.Native -> native.add(att)
                AttachmentRoute.ClientExtract -> text.add(att)
            }
        }
        return Pair(native, text)
    }

    // ── OpenAI/OpenRouter Format ──

    private fun buildOpenAIParts(msg: ChatMessage, providerKind: ProviderKind): String? {
        val attachments = msg.attachments
        if (attachments.isNullOrEmpty()) return null

        val parts = mutableListOf<String>()

        for (att in attachments) {
            when (att.kind) {
                AttachmentKind.Image -> {
                    val base64 = att.base64Data ?: att.thumbnailBase64 ?: continue
                    val dataUri = if (base64.startsWith("data:")) base64 else "data:${att.mimeType};base64,$base64"
                    // detail=auto is sent explicitly; OpenAI-compatible upstreams consume the field
                    // and everyone else ignores it.
                    parts.add("""{"type":"image_url","image_url":{"url":"$dataUri","detail":"auto"}}""")
                }
                AttachmentKind.Video -> {
                    val base64 = att.base64Data ?: continue
                    val dataUri = if (base64.startsWith("data:")) base64 else "data:${att.mimeType};base64,$base64"
                    parts.add("""{"type":"video_url","video_url":{"url":"$dataUri"}}""")
                }
                AttachmentKind.File -> Unit  // folded into the text part by AttachmentInjector
            }
        }

        // File attachments always go through AttachmentInjector; the wrapper flavour (xml-v1 or
        // markdown-v1) is chosen per provider.
        val wrapper = AttachmentWrapperVersion.resolve(providerKind)
        val payloads = toAttachmentPayloads(attachments)
        val injected = AttachmentInjector.injectAll(msg.text, payloads, wrapper = wrapper)

        if (injected.text.isNotBlank()) {
            parts.add(0, """{"type":"text","text":${escapeJsonString(injected.text)}}""")
        }
        return if (parts.isNotEmpty()) parts.joinToString(",") else null
    }

    private fun buildOpenAIResponsesParts(msg: ChatMessage, activeModel: AIModel? = null): String? {
        val attachments = msg.attachments
        if (attachments.isNullOrEmpty()) return null

        // In the Responses protocol images and files are user input only. Assistant and system
        // history replays text alone, and assistant text must use output_text, so old attachments
        // are never dressed up as a fresh round of user input.
        if (msg.role != ChatRole.User) {
            val textType = if (msg.role == ChatRole.Assistant) "output_text" else "input_text"
            return """{"type":"$textType","text":${escapeJsonString(msg.text)}}"""
        }

        val parts = mutableListOf<String>()
        // The AttachmentRouter decides native versus client extraction, replacing the older
        // hardcoded capabilities.nativePdf check.
        val (nativeAtts, textFileAtts) = partitionFileAttachments(attachments, ProviderKind.OpenAI, activeModel)

        for (att in attachments) {
            when (att.kind) {
                AttachmentKind.Image -> {
                    val base64 = att.base64Data ?: att.thumbnailBase64 ?: continue
                    val dataUri = if (base64.startsWith("data:")) base64 else "data:${att.mimeType};base64,$base64"
                    // detail=auto is sent explicitly: it makes the default visible and leaves room
                    // for a UI switch later.
                    parts.add("""{"type":"input_image","image_url":"$dataUri","detail":"auto"}""")
                }
                AttachmentKind.Video -> {
                    val base64 = att.base64Data ?: continue
                    val dataUri = if (base64.startsWith("data:")) base64 else "data:${att.mimeType};base64,$base64"
                    parts.add("""{"type":"input_video","video_url":"$dataUri"}""")
                }
                AttachmentKind.File -> Unit // handled below through nativeAtts / textFileAtts
            }
        }
        // Native path: PDF plus the eight Office mime types, with the mime taken from the attachment
        // itself.
        for (f in nativeAtts) {
            val base64 = f.originalBase64Data ?: continue
            val dataUri = "data:${f.mimeType};base64,$base64"
            parts.add("""{"type":"input_file","filename":${escapeJsonString(f.fileName)},"file_data":"$dataUri"}""")
        }

        val limits = FileExtractionLimits.resolve(activeModel)
        val payloads = toAttachmentPayloads(textFileAtts)
        val injected = AttachmentInjector.injectAll(msg.text, payloads, limits = limits)

        if (injected.text.isNotBlank()) {
            parts.add(0, """{"type":"input_text","text":${escapeJsonString(injected.text)}}""")
        }

        return if (parts.isNotEmpty()) parts.joinToString(",") else null
    }

    private fun buildDeepSeekContent(msg: ChatMessage): String {
        val attachments = msg.attachments.orEmpty()

        // DeepSeek is not multimodal, so images and videos are replaced with a placeholder line.
        val imagePlaceholders = attachments
            .filter { it.kind == AttachmentKind.Image }
            .map { "[Image omitted: unsupported by DeepSeek]" }
        val videoPlaceholders = attachments
            .filter { it.kind == AttachmentKind.Video }
            .map { "[Video omitted: ${it.fileName}]" }

        val baseText = listOfNotNull(
            msg.text.takeIf { it.isNotBlank() },
            *imagePlaceholders.toTypedArray(),
            *videoPlaceholders.toTypedArray(),
        ).joinToString("\n\n")

        // File attachments always go through AttachmentInjector; DeepSeek uses the markdown wrapper.
        val payloads = toAttachmentPayloads(attachments)
        val injected = AttachmentInjector.injectAll(
            baseText, payloads,
            wrapper = AttachmentWrapperVersion.MarkdownV1,
        )
        return injected.text
    }

    /** Test-visible entry point, so tests do not have to reach the private method by reflection. */
    internal fun buildDeepSeekContentForTest(msg: ChatMessage) = buildDeepSeekContent(msg)

    // ── Anthropic Format ──

    private fun buildAnthropicParts(msg: ChatMessage, activeModel: AIModel? = null): String? {
        val attachments = msg.attachments
        if (attachments.isNullOrEmpty()) return null

        val parts = mutableListOf<String>()
        // The AttachmentRouter decides the route; Anthropic currently takes only PDF natively, so
        // docx and xlsx fall back to client-side extraction.
        val (nativeAtts, textFileAtts) = partitionFileAttachments(attachments, ProviderKind.Anthropic, activeModel)
        // Document and image blocks automatically get cache_control: ephemeral (a 5 minute TTL),
        // which cuts roughly 70 percent off the cost of asking about the same attachment again.
        val cacheControl = ""","cache_control":{"type":"ephemeral"}"""

        for (att in attachments) {
            when (att.kind) {
                AttachmentKind.Image -> {
                    val base64 = att.base64Data ?: att.thumbnailBase64 ?: continue
                    parts.add("""{"type":"image","source":{"type":"base64","media_type":"${att.mimeType}","data":"$base64"}$cacheControl}""")
                }
                AttachmentKind.Video -> Unit  // folded into the text part below
                AttachmentKind.File -> Unit   // handled below through nativeAtts / textFileAtts
            }
        }
        // Native PDF becomes a document block plus cache_control, with the mime taken from the
        // attachment itself.
        for (f in nativeAtts) {
            val base64 = f.originalBase64Data ?: continue
            parts.add("""{"type":"document","source":{"type":"base64","media_type":"${f.mimeType}","data":"$base64"}$cacheControl}""")
        }

        // Video placeholders and the client-extraction path for file attachments both go through
        // AttachmentInjector.
        val videoPlaceholders = attachments.filter { it.kind == AttachmentKind.Video }
            .map { "[Video omitted: ${it.fileName}]" }
        val baseText = listOfNotNull(
            msg.text.takeIf { it.isNotBlank() },
            *videoPlaceholders.toTypedArray(),
        ).joinToString("\n\n")

        val limits = FileExtractionLimits.resolve(activeModel)
        val payloads = toAttachmentPayloads(textFileAtts)
        val injected = AttachmentInjector.injectAll(baseText, payloads, limits = limits)

        if (injected.text.isNotBlank()) {
            parts.add(0, """{"type":"text","text":${escapeJsonString(injected.text)}}""")
        }
        return if (parts.isNotEmpty()) parts.joinToString(",") else null
    }

    // ── Gemini Format ──

    private fun buildGeminiParts(msg: ChatMessage, activeModel: AIModel? = null): String {
        val parts = mutableListOf<String>()
        val attachments = msg.attachments.orEmpty()

        // The AttachmentRouter decides the route; with Gemini's pdfNativeDefault set, every PDF goes
        // up natively.
        val (nativeAtts, textFileAtts) = partitionFileAttachments(attachments, ProviderKind.Gemini, activeModel)

        for (att in attachments) {
            when (att.kind) {
                AttachmentKind.Image -> {
                    val base64 = att.base64Data ?: att.thumbnailBase64 ?: continue
                    parts.add("""{"inlineData":{"mimeType":"${att.mimeType}","data":"$base64"}}""")
                }
                AttachmentKind.Video -> {
                    val base64 = att.base64Data ?: continue
                    parts.add("""{"inlineData":{"mimeType":"${att.mimeType}","data":"$base64"}}""")
                }
                AttachmentKind.File -> Unit // handled below through nativeAtts / textFileAtts
            }
        }
        // Native PDF becomes inlineData, with the mime taken from the attachment itself so future
        // Office support needs no change here.
        for (f in nativeAtts) {
            val base64 = f.originalBase64Data ?: continue
            parts.add("""{"inlineData":{"mimeType":"${f.mimeType}","data":"$base64"}}""")
        }

        val limits = FileExtractionLimits.resolve(activeModel)
        val payloads = toAttachmentPayloads(textFileAtts)
        val injected = AttachmentInjector.injectAll(msg.text, payloads, limits = limits)

        if (injected.text.isNotBlank()) {
            parts.add(0, """{"text":${escapeJsonString(injected.text)}}""")
        }
        return parts.joinToString(",")
    }

    fun temperatureJson(temperature: Float?): String? {
        if (temperature == null) return null
        return """"temperature":${formatFloat(temperature)}"""
    }

    fun maxTokensJson(maxTokens: Int?, key: String = "max_tokens"): String? {
        if (maxTokens == null) return null
        return """"$key":$maxTokens"""
    }

    fun anthropicSystemJson(systemPrompt: String?): String? {
        if (systemPrompt.isNullOrBlank()) return null
        return """"system":${escapeJsonString(systemPrompt.trim())}"""
    }

    fun geminiSystemInstructionJson(systemPrompt: String?): String? {
        if (systemPrompt.isNullOrBlank()) return null
        return """"systemInstruction":{"parts":[{"text":${escapeJsonString(systemPrompt.trim())}}]}"""
    }

    fun normalizeRequestOptions(options: ChatRequestOptions): ChatRequestOptions {
        // An explicit 1.0 is still a user value. It is not equivalent to omitting the
        // field for every provider, so only null represents "use provider default".
        val normalizedTemperature = options.temperature
        val normalizedMaxTokens = options.maxTokens
            ?.takeUnless { it == ChatRequestOptions.DEFAULT_MAX_TOKENS }

        return options.copy(
            temperature = normalizedTemperature,
            maxTokens = normalizedMaxTokens,
            systemPrompt = options.systemPrompt.trim(),
        )
    }

    fun supportsImageAttachments(
        providerKind: ProviderKind?,
        capabilities: List<ModelCapability>,
    ): Boolean {
        val support = providerKind?.attachmentSupport ?: return false
        return support.image && capabilities.contains(ModelCapability.Image)
    }

    fun supportsFileAttachments(
        providerKind: ProviderKind?,
        capabilities: List<ModelCapability>,
    ): Boolean {
        val support = providerKind?.attachmentSupport ?: return false
        // Deliberately does not consult model capabilities.contains(File); only the provider-level
        // textFileInline / nativeFile flags matter. Once the text has been extracted locally any
        // text model can consume the file content, so capability.File is only meaningful on the
        // native upload path.
        return support.nativeFile || support.textFileInline
    }

    fun supportsVideoAttachments(
        providerKind: ProviderKind?,
        capabilities: List<ModelCapability>,
    ): Boolean {
        val support = providerKind?.attachmentSupport ?: return false
        return support.video && capabilities.contains(ModelCapability.Video)
    }

    fun canAttachVideo(
        providerKind: ProviderKind?,
        mimeType: String,
    ): Boolean {
        val support = providerKind?.attachmentSupport ?: return false
        return support.video && mimeType.lowercase().startsWith("video/")
    }

    fun canAttachFile(
        providerKind: ProviderKind?,
        mimeType: String,
        base64Data: String,
    ): Boolean {
        val support = providerKind?.attachmentSupport ?: return false
        if (support.nativeFile) return true
        if (!support.textFileInline) return false
        return isTextMimeType(mimeType) && tryDecodeBase64Text(base64Data) != null
    }

    fun resolveAttachmentMimeType(
        fileName: String,
        detectedMimeType: String?,
    ): String {
        val normalized = detectedMimeType?.trim().orEmpty()
        if (normalized.isNotEmpty() && normalized != "application/octet-stream") {
            return normalized
        }
        val extension = fileName.substringAfterLast('.', "").lowercase()
        return fallbackMimeType(extension)
    }

    // ── Attachment payload helpers ──

    /**
     * Converts the File attachments of a message into the payload list AttachmentInjector consumes.
     * Text content is decoded from base64Data; when extractionErrorCode is set, the error code is
     * used directly instead. Exposed as internal so the individual provider services can reuse it.
     */
    internal fun toAttachmentPayloads(
        attachments: List<Attachment>,
    ): List<AttachmentInjector.AttachmentPayload> {
        return attachments.filter { it.kind == AttachmentKind.File }.map { att ->
            val errorCode = att.extractionErrorCode
                ?.let { raw -> ExtractionErrorCode.entries.firstOrNull { it.raw == raw } }
            val decoded = if (errorCode == null && att.base64Data != null) {
                tryDecodeBase64Text(att.base64Data)
            } else null
            val extracted = if (decoded != null) {
                ExtractedText(
                    content = decoded,
                    totalLines = att.extractedTotalLines ?: decoded.split("\n").size,
                    truncated = att.extractedTruncated ?: false,
                    truncationReason = null,
                    sizeBytes = att.extractedSizeBytes ?: decoded.toByteArray(Charsets.UTF_8).size,
                )
            } else null
            AttachmentInjector.AttachmentPayload(
                fileName = att.fileName,
                mimeType = att.mimeType,
                sizeBytes = att.extractedSizeBytes ?: 0,
                extracted = extracted,
                errorCode = errorCode ?: if (extracted == null && att.base64Data != null) ExtractionErrorCode.ExtractionError else null,
            )
        }
    }

    // ── Utilities ──

    fun isTextMimeType(mimeType: String): Boolean {
        return mimeType.startsWith("text/") ||
            mimeType in setOf(
                "application/json", "application/xml",
                "application/javascript", "application/typescript",
                "application/x-yaml", "application/csv",
            )
    }

    private fun fallbackMimeType(ext: String): String {
        return when (ext) {
            "txt" -> "text/plain"
            "md", "markdown" -> "text/markdown"
            "csv" -> "text/csv"
            "json" -> "application/json"
            "xml" -> "application/xml"
            "html", "htm" -> "text/html"
            "css" -> "text/css"
            "js", "mjs", "cjs" -> "text/javascript"
            "ts", "tsx" -> "application/typescript"
            "py" -> "text/x-python"
            "swift" -> "text/x-swift"
            "yaml", "yml" -> "text/yaml"
            "pdf" -> "application/pdf"
            "doc" -> "application/msword"
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "xls" -> "application/vnd.ms-excel"
            "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "ppt" -> "application/vnd.ms-powerpoint"
            "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            "rtf" -> "application/rtf"
            "mp4" -> "video/mp4"
            "mov" -> "video/quicktime"
            "mpeg", "mpg" -> "video/mpeg"
            "avi" -> "video/x-msvideo"
            "flv" -> "video/x-flv"
            "webm" -> "video/webm"
            "wmv" -> "video/x-ms-wmv"
            "3gp" -> "video/3gpp"
            "sql" -> "application/sql"
            else -> "application/octet-stream"
        }
    }

    private fun tryDecodeBase64Text(base64: String): String? {
        return try {
            val decodedBytes = Base64.getDecoder().decode(base64)
            val decoder = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            decoder.decode(ByteBuffer.wrap(decodedBytes)).toString()
        } catch (_: Exception) {
            null
        }
    }

    private fun formatFloat(value: Float): String = if (value % 1f == 0f) {
        value.toInt().toString()
    } else {
        value.toString()
    }

    /**
     * Extracts base64 inline images from Markdown text.
     * Returns list of (mimeType, base64Data) and cleaned text.
     */
    fun extractInlineImages(text: String): Pair<String, List<Pair<String, String>>> {
        val regex = Regex("""!\[.*?]\((data:image/([^;]+);base64,([A-Za-z0-9+/=]+))\)""")
        val images = mutableListOf<Pair<String, String>>()
        val cleaned = regex.replace(text) { match ->
            val mime = "image/${match.groupValues[2]}"
            val data = match.groupValues[3]
            images.add(mime to data)
            "" // remove from text
        }
        return cleaned.trim() to images
    }
}
