package ai.oriveo.community.core.provider

import ai.oriveo.community.core.attachments.AttachmentDelivery
import ai.oriveo.community.core.attachments.AttachmentInjector
import ai.oriveo.community.core.attachments.AttachmentTransportProfile
import ai.oriveo.community.core.attachments.ImageMediaType
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatMessageState
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.ProviderKind

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
     *     The rules follow the shared fixture `shared/context-contracts/sanitize.v1.json`:
     *     - A run of N >= 2 consecutive user messages is merged into one that keeps the id and other
     *       fields of the last message. The non-empty texts of the earlier ones are trimmed,
     *       XML-escaped and joined with blank lines inside an `<oriveo-unanswered>` envelope (carrying
     *       [UNANSWERED_NOTE]); the envelope is followed by a blank line and the newest message's
     *       original text. If none of the earlier messages has text there is no envelope; if the
     *       newest one is empty only the envelope remains. Attachments are concatenated in message
     *       order. Earlier user messages often carry instructions ("from now on answer only in
     *       Arabic"); dropping them silently loses that context. Wrapping them in an envelope that
     *       says "unanswered, use as context, answer the latest message" keeps the instruction
     *       without making the model answer both questions at once.
     *     - Adjacent assistant messages (rare): merge them, joining trimmed text with a blank line
     *       and concatenating attachments in order, keeping the first message's fields.
     *
     * Note: an interrupted or failed assistant that does have partial text naturally separates the
     * two user messages around it, so in most cases the adjacent-user merge never fires at all.
     * Only "stopped early, partial is empty" or a failed answer reaches the envelope branch.
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
        // The earlier messages of the current run of consecutive user messages (not merged yet);
        // merged in one go when a non-user message or the end of the list is reached.
        val pendingUsers = mutableListOf<ChatMessage>()
        fun flushUsers() {
            if (pendingUsers.isEmpty()) return
            merged.add(mergeUnansweredUsers(pendingUsers))
            pendingUsers.clear()
        }
        for (msg in filtered) {
            if (msg.role == ChatRole.User) {
                pendingUsers.add(msg)
                continue
            }
            flushUsers()
            val last = merged.lastOrNull()
            if (last != null && last.role == ChatRole.Assistant) {
                // Adjacent assistant messages (rare) are merged, so no real answer content is lost.
                val joinedText = listOf(last.text.trim(), msg.text.trim())
                    .filter { it.isNotEmpty() }
                    .joinToString("\n\n")
                val joinedAttachments = last.attachments.orEmpty() + msg.attachments.orEmpty()
                merged[merged.size - 1] = last.copy(
                    text = joinedText,
                    attachments = joinedAttachments.takeIf { it.isNotEmpty() },
                )
            } else {
                merged.add(msg)
            }
        }
        flushUsers()
        return merged
    }

    /** Note text inside the unanswered-user envelope (`unansweredEnvelope.note` of the cross-platform sanitize.v1 contract, verbatim). */
    const val UNANSWERED_NOTE =
        "The user sent this earlier but no reply was delivered. Treat it as context and answer the latest message."

    private const val UNANSWERED_TAG = "oriveo-unanswered"

    /** Merges a run of consecutive user messages: keeps the last one's id/fields, wraps earlier non-empty texts in the envelope, concatenates attachments in order. */
    private fun mergeUnansweredUsers(run: List<ChatMessage>): ChatMessage {
        val latest = run.last()
        if (run.size == 1) return latest
        val earlier = run.dropLast(1)
        val earlierTexts = earlier.map { it.text.trim() }.filter { it.isNotEmpty() }.map(::escapeXml)
        val text = if (earlierTexts.isEmpty()) {
            latest.text
        } else {
            val envelope = buildString {
                append("<").append(UNANSWERED_TAG).append(">\n")
                append("<note>").append(UNANSWERED_NOTE).append("</note>\n")
                append(earlierTexts.joinToString("\n\n")).append("\n")
                append("</").append(UNANSWERED_TAG).append(">")
            }
            if (latest.text.isEmpty()) envelope else envelope + "\n\n" + latest.text
        }
        val attachments = run.flatMap { it.attachments.orEmpty() }
        return latest.copy(text = text, attachments = attachments.takeIf { it.isNotEmpty() })
    }

    // Only the earlier texts inside the envelope are escaped; the order is fixed at & -> < -> > to avoid double escaping.
    private fun escapeXml(raw: String): String =
        raw.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    /**
     * Builds the message-array JSON in OpenRouter / OpenAI Chat Completions format.
     * Supports image_url (base64 data URI) and file content parts.
     */
    fun buildOpenAIMessages(
        messages: List<ChatMessage>,
        providerKind: ProviderKind,
        systemPrompt: String? = null,
        activeModel: AIModel? = null,
    ): String {
        val payloads = mutableListOf<String>()
        if (!systemPrompt.isNullOrBlank()) {
            payloads.add("""{"role":"system","content":${escapeJsonString(systemPrompt.trim())}}""")
        }
        val currentTurnIndex = AttachmentDelivery.currentTurnIndex(messages)
        payloads += messages.mapIndexed { index, msg ->
            val role = msg.role.name.lowercase()
            val parts = buildOpenAIParts(msg, providerKind, activeModel, isCurrentTurn = index == currentTurnIndex)
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
        activeModel: AIModel? = null,
    ): String = when (AttachmentTransportResolver.chatCompletions(providerKind)) {
        AttachmentTransportProfile.DeepSeekChat -> buildDeepSeekMessages(messages, systemPrompt, activeModel)
        else -> buildOpenAIMessages(messages, providerKind, systemPrompt, activeModel)
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
        activeModel: AIModel? = null,
    ): String {
        val payloads = mutableListOf<String>()
        if (!systemPrompt.isNullOrBlank()) {
            payloads.add("""{"role":"system","content":${escapeJsonString(systemPrompt.trim())}}""")
        }
        val currentTurnIndex = AttachmentDelivery.currentTurnIndex(messages)
        payloads += messages.mapIndexed { index, msg ->
            val role = msg.role.name.lowercase()
            val content = buildDeepSeekContent(msg, activeModel, isCurrentTurn = index == currentTurnIndex)
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
    fun buildOpenAIResponsesInput(
        messages: List<ChatMessage>,
        activeModel: AIModel? = null,
        transport: AttachmentTransportProfile = AttachmentTransportProfile.OpenAIResponses,
    ): String {
        val currentTurnIndex = AttachmentDelivery.currentTurnIndex(messages)
        return messages.withIndex().joinToString(",") { (index, msg) ->
            val role = msg.role.name.lowercase()
            val parts = buildOpenAIResponsesParts(msg, activeModel, isCurrentTurn = index == currentTurnIndex, transport = transport)
            val textType = if (msg.role == ChatRole.Assistant) "output_text" else "input_text"
            val canonicalParts = parts
                ?: """{"type":"$textType","text":${escapeJsonString(msg.text)}}"""
            """{"role":"$role","content":[$canonicalParts]}"""
        }
    }

    /**
     * Builds the message-array JSON in Anthropic Messages API format.
     * image -> base64 source, document -> base64 source, text file -> inline text.
     * Passing activeModel enables the router.
     *
     * Cache breakpoints: Anthropic allows at most 4 cache_control breakpoints per request, so
     * content blocks get none by default (direct Anthropic requests rely on the top-level
     * cache_control only). With [cacheLastUserBlock] = true (the relay Anthropic path) exactly one
     * breakpoint goes on the last content block of the last user message.
     */
    fun buildAnthropicMessages(
        messages: List<ChatMessage>,
        activeModel: AIModel? = null,
        transport: AttachmentTransportProfile = AttachmentTransportProfile.AnthropicMessages,
        cacheLastUserBlock: Boolean = false,
    ): String {
        val currentTurnIndex = AttachmentDelivery.currentTurnIndex(messages)
        val breakpointIndex = if (cacheLastUserBlock) messages.indexOfLast { it.role == ChatRole.User } else -1
        return messages.withIndex().joinToString(",") { (index, msg) ->
            val role = msg.role.name.lowercase()
            val parts = buildAnthropicParts(msg, activeModel, isCurrentTurn = index == currentTurnIndex, transport = transport)
            when {
                index == breakpointIndex && parts.isNotEmpty() -> {
                    val marked = parts.dropLast(1) + withAnthropicCacheControl(parts.last())
                    """{"role":"$role","content":[${marked.joinToString(",")}]}"""
                }
                index == breakpointIndex && msg.text.isNotBlank() ->
                    """{"role":"$role","content":[${withAnthropicCacheControl("""{"type":"text","text":${escapeJsonString(msg.text)}}""")}]}"""
                parts.isNotEmpty() -> """{"role":"$role","content":[${parts.joinToString(",")}]}"""
                else -> """{"role":"$role","content":${escapeJsonString(msg.text)}}"""
            }
        }
    }

    /** Appends `cache_control: ephemeral` to one Anthropic content block (a JSON object string). */
    private fun withAnthropicCacheControl(block: String): String =
        block.removeSuffix("}") + ""","cache_control":{"type":"ephemeral"}}"""

    /**
     * Builds the contents JSON for Gemini generateContent.
     * inlineData for images and files, text parts for text.
     * Passing activeModel enables the router; when pdfNativeDefault is true every PDF goes up
     * natively.
     */
    fun buildGeminiContents(
        messages: List<ChatMessage>,
        activeModel: AIModel? = null,
        transport: AttachmentTransportProfile = AttachmentTransportProfile.GeminiGenerateContent,
    ): String {
        val currentTurnIndex = AttachmentDelivery.currentTurnIndex(messages)
        return messages.withIndex().joinToString(",") { (index, msg) ->
            val role = if (msg.role == ChatRole.Assistant) "model" else "user"
            val parts = buildGeminiParts(msg, activeModel, isCurrentTurn = index == currentTurnIndex, transport = transport)
            """{"role":"$role","parts":[$parts]}"""
        }
    }

    // ── OpenAI/OpenRouter Format ──

    private fun buildOpenAIParts(
        msg: ChatMessage,
        providerKind: ProviderKind,
        activeModel: AIModel? = null,
        isCurrentTurn: Boolean = false,
    ): String? {
        val attachments = msg.attachments
        if (attachments.isNullOrEmpty()) return null

        val parts = mutableListOf<String>()
        val transport = AttachmentTransportResolver.chatCompletions(providerKind)
        // Text-only wire (MiniMax Chat): one placeholder line per image, no image blocks.
        val imagePlaceholder = transport.imagePlaceholderText

        for (att in attachments) {
            when (att.kind) {
                AttachmentKind.Image -> {
                    if (imagePlaceholder != null) continue
                    val base64 = att.base64Data ?: att.thumbnailBase64 ?: continue
                    val dataUri = if (base64.startsWith("data:")) base64 else "data:${ImageMediaType.resolve(base64, att.mimeType)};base64,$base64"
                    // detail=auto is sent explicitly; OpenAI-compatible upstreams consume the field
                    // and everyone else ignores it.
                    parts.add("""{"type":"image_url","image_url":{"url":"$dataUri","detail":"auto"}}""")
                }
                AttachmentKind.Video -> {
                    val base64 = att.base64Data ?: continue
                    val dataUri = if (base64.startsWith("data:")) base64 else "data:${att.mimeType};base64,$base64"
                    parts.add("""{"type":"video_url","video_url":{"url":"$dataUri"}}""")
                }
                AttachmentKind.File -> Unit  // handled through the delivery plan below
            }
        }

        // The transport decides whether an original file may enter the content parts. Only OpenRouter can; every
        // other Chat Completions upstream receives files as text.
        val plan = AttachmentDelivery.plan(
            baseText = withImagePlaceholders(msg.text, attachments, imagePlaceholder),
            attachments = attachments,
            model = activeModel,
            transport = transport,
        )
        AttachmentDelivery.requireDeliverable(plan, isCurrentTurn)
        // A file judged native is emitted as a file block whatever the role: it is no longer in the text, so
        // skipping it here would drop it from both places.
        for (f in plan.native) {
            val base64 = f.originalBase64Data ?: continue
            val dataUri = "data:${f.mimeType};base64,$base64"
            parts.add(
                """{"type":"file","file":{"filename":${escapeJsonString(f.fileName)},"file_data":"$dataUri"}}""",
            )
        }

        if (plan.text.isNotBlank()) {
            parts.add(0, """{"type":"text","text":${escapeJsonString(plan.text)}}""")
        }
        return if (parts.isNotEmpty()) parts.joinToString(",") else null
    }

    private fun buildOpenAIResponsesParts(
        msg: ChatMessage,
        activeModel: AIModel? = null,
        isCurrentTurn: Boolean = false,
        transport: AttachmentTransportProfile = AttachmentTransportProfile.OpenAIResponses,
    ): String? {
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
        val plan = AttachmentDelivery.plan(
            baseText = msg.text,
            attachments = attachments,
            model = activeModel,
            transport = transport,
        )
        AttachmentDelivery.requireDeliverable(plan, isCurrentTurn)

        for (att in attachments) {
            when (att.kind) {
                AttachmentKind.Image -> {
                    val base64 = att.base64Data ?: att.thumbnailBase64 ?: continue
                    val dataUri = if (base64.startsWith("data:")) base64 else "data:${ImageMediaType.resolve(base64, att.mimeType)};base64,$base64"
                    // detail=auto is sent explicitly: it makes the default visible and leaves room
                    // for a UI switch later.
                    parts.add("""{"type":"input_image","image_url":"$dataUri","detail":"auto"}""")
                }
                AttachmentKind.Video -> {
                    val base64 = att.base64Data ?: continue
                    val dataUri = if (base64.startsWith("data:")) base64 else "data:${att.mimeType};base64,$base64"
                    parts.add("""{"type":"input_video","video_url":"$dataUri"}""")
                }
                AttachmentKind.File -> Unit // handled through the delivery plan
            }
        }
        // Native path: PDF plus the eight Office mime types, with the mime taken from the attachment
        // itself.
        for (f in plan.native) {
            val base64 = f.originalBase64Data ?: continue
            val dataUri = "data:${f.mimeType};base64,$base64"
            parts.add("""{"type":"input_file","filename":${escapeJsonString(f.fileName)},"file_data":"$dataUri"}""")
        }

        if (plan.text.isNotBlank()) {
            parts.add(0, """{"type":"input_text","text":${escapeJsonString(plan.text)}}""")
        }

        return if (parts.isNotEmpty()) parts.joinToString(",") else null
    }

    private fun buildDeepSeekContent(msg: ChatMessage, activeModel: AIModel? = null, isCurrentTurn: Boolean = false): String {
        val attachments = msg.attachments.orEmpty()

        // DeepSeek is not multimodal, so images and videos are replaced with a placeholder line.
        val imagePlaceholders = attachments
            .filter { it.kind == AttachmentKind.Image }
            .mapNotNull { AttachmentTransportProfile.DeepSeekChat.imagePlaceholderText }
        val videoPlaceholders = attachments
            .filter { it.kind == AttachmentKind.Video }
            .map { "[Video omitted: ${it.fileName}]" }

        val baseText = listOfNotNull(
            msg.text.takeIf { it.isNotBlank() },
            *imagePlaceholders.toTypedArray(),
            *videoPlaceholders.toTypedArray(),
        ).joinToString("\n\n")

        // File attachments always go through AttachmentInjector; DeepSeek uses the markdown wrapper.
        val plan = AttachmentDelivery.plan(
            baseText = baseText,
            attachments = attachments,
            model = activeModel,
            transport = AttachmentTransportProfile.DeepSeekChat,
        )
        AttachmentDelivery.requireDeliverable(plan, isCurrentTurn)
        return plan.text
    }

    /** Test-visible entry point, so tests do not have to reach the private method by reflection. */
    internal fun buildDeepSeekContentForTest(msg: ChatMessage) = buildDeepSeekContent(msg)

    // ── Anthropic Format ──

    private fun buildAnthropicParts(
        msg: ChatMessage,
        activeModel: AIModel? = null,
        isCurrentTurn: Boolean = false,
        transport: AttachmentTransportProfile = AttachmentTransportProfile.AnthropicMessages,
    ): List<String> {
        val attachments = msg.attachments
        if (attachments.isNullOrEmpty()) return emptyList()

        val parts = mutableListOf<String>()
        // Video placeholders are folded into the text; the delivery plan decides whether each file goes up as a
        // document block or is injected as text.
        val videoPlaceholders = attachments.filter { it.kind == AttachmentKind.Video }
            .map { "[Video omitted: ${it.fileName}]" }
        // Text-only wire (MiniMax's Anthropic-compatible web search endpoint): one placeholder line per image, no image blocks.
        val imagePlaceholder = transport.imagePlaceholderText
        val baseText = listOfNotNull(
            withImagePlaceholders(msg.text, attachments, imagePlaceholder).takeIf { it.isNotBlank() },
            *videoPlaceholders.toTypedArray(),
        ).joinToString("\n\n")
        val plan = AttachmentDelivery.plan(
            baseText = baseText,
            attachments = attachments,
            model = activeModel,
            transport = transport,
        )
        AttachmentDelivery.requireDeliverable(plan, isCurrentTurn)
        for (att in attachments) {
            when (att.kind) {
                AttachmentKind.Image -> {
                    if (imagePlaceholder != null) continue
                    val base64 = att.base64Data ?: att.thumbnailBase64 ?: continue
                    parts.add("""{"type":"image","source":{"type":"base64","media_type":"${ImageMediaType.resolve(base64, att.mimeType)}","data":"$base64"}}""")
                }
                AttachmentKind.Video -> Unit  // folded into the text part below
                AttachmentKind.File -> Unit   // handled through the delivery plan
            }
        }
        // Native PDF becomes a document block, with the mime taken from the attachment itself.
        // Blocks never get their own cache_control (see buildAnthropicMessages).
        for (f in plan.native) {
            val base64 = f.originalBase64Data ?: continue
            parts.add("""{"type":"document","source":{"type":"base64","media_type":"${f.mimeType}","data":"$base64"}}""")
        }

        if (plan.text.isNotBlank()) {
            parts.add(0, """{"type":"text","text":${escapeJsonString(plan.text)}}""")
        }
        return parts
    }

    /** Text-only wires replace each image with one placeholder line appended after the body (same shape as DeepSeek / llama.cpp); wires that can carry images return the content unchanged. */
    fun withImagePlaceholders(text: String, attachments: List<Attachment>, placeholder: String?): String {
        if (placeholder == null) return text
        val lines = attachments.filter { it.kind == AttachmentKind.Image }.map { placeholder }
        if (lines.isEmpty()) return text
        return listOfNotNull(text.takeIf { it.isNotBlank() }, *lines.toTypedArray()).joinToString("\n\n")
    }

    // ── Gemini Format ──

    /**
     * Image and video parts (inlineData) of a Gemini Content. The `input` of both generateContent and Interactions
     * is a Content[], so the two transports share this.
     */
    fun geminiMediaParts(attachments: List<Attachment>): List<String> = attachments.mapNotNull { att ->
        val base64 = when (att.kind) {
            AttachmentKind.Image -> att.base64Data ?: att.thumbnailBase64
            AttachmentKind.Video -> att.base64Data
            AttachmentKind.File -> null // handled through the delivery plan
        } ?: return@mapNotNull null
        val mimeType = if (att.kind == AttachmentKind.Image) ImageMediaType.resolve(base64, att.mimeType) else att.mimeType
        """{"inlineData":{"mimeType":"$mimeType","data":"$base64"}}"""
    }

    private fun buildGeminiParts(
        msg: ChatMessage,
        activeModel: AIModel? = null,
        isCurrentTurn: Boolean = false,
        transport: AttachmentTransportProfile = AttachmentTransportProfile.GeminiGenerateContent,
    ): String {
        val parts = mutableListOf<String>()
        val attachments = msg.attachments.orEmpty()

        // The delivery plan decides the route; with Gemini's pdfNativeDefault set, every PDF goes up natively.
        val plan = AttachmentDelivery.plan(
            baseText = msg.text,
            attachments = attachments,
            model = activeModel,
            transport = transport,
        )
        AttachmentDelivery.requireDeliverable(plan, isCurrentTurn)

        parts += geminiMediaParts(attachments)
        // Native PDF becomes inlineData, with the mime taken from the attachment itself so future
        // Office support needs no change here.
        for (f in plan.native) {
            val base64 = f.originalBase64Data ?: continue
            parts.add("""{"inlineData":{"mimeType":"${f.mimeType}","data":"$base64"}}""")
        }

        if (plan.text.isNotBlank()) {
            parts.add(0, """{"text":${escapeJsonString(plan.text)}}""")
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
        return isTextMimeType(mimeType) && AttachmentDelivery.tryDecodeBase64Text(base64Data) != null
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
    ): List<AttachmentInjector.AttachmentPayload> = AttachmentDelivery.toAttachmentPayloads(attachments)

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
