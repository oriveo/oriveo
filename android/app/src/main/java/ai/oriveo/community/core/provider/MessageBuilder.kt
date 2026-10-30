package ai.oriveo.community.core.provider

import ai.oriveo.community.core.attachments.AttachmentDelivery
import ai.oriveo.community.core.attachments.AttachmentInjector
import ai.oriveo.community.core.attachments.AttachmentTransportProfile
import ai.oriveo.community.core.attachments.ImageMediaType
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.AttachmentSupportInfo
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
     * Files are folded into the body; images / videos the outbound gate lets through are sent as
     * image_url / video_url parts, and a message without media parts still sends a string content.
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
            val (content, carried) = deepSeekContentAndPlaceholders(msg, activeModel, isCurrentTurn = index == currentTurnIndex)
            val media = openAIChatMediaParts(msg.attachments.orEmpty(), sendImages = true)
            if (media.isEmpty()) {
                """{"role":"$role","content":${escapeJsonString(withOutboundPlaceholderLines(content, carried))}}"""
            } else {
                val textPart = content.takeIf { it.isNotBlank() }?.let { """{"type":"text","text":${escapeJsonString(it)}}""" }
                val placeholderPart = outboundPlaceholderText(carried)?.let { """{"type":"text","text":${escapeJsonString(it)}}""" }
                """{"role":"$role","content":[${(listOfNotNull(textPart) + media + listOfNotNull(placeholderPart)).joinToString(",")}]}"""
            }
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
     * Cache breakpoint: only one cache_control per request. With [cacheLastUserBlock] = true (official and relay
     * Anthropic) it goes on the last non-[D] block of the last user message; the MiniMax-compatible route does not enable it.
     * When [dynamicText] is non-empty and the last user text == dynamicText (body empty) or ends with "\n\n" + dynamicText,
     * it is split off as the last standalone text block of that message (after the attachment blocks); if it cannot be
     * found the message is sent as is and the breakpoint goes on the last block.
     */
    fun buildAnthropicMessages(
        messages: List<ChatMessage>,
        activeModel: AIModel? = null,
        transport: AttachmentTransportProfile = AttachmentTransportProfile.AnthropicMessages,
        cacheLastUserBlock: Boolean = false,
        dynamicText: String? = null,
    ): String {
        val currentTurnIndex = AttachmentDelivery.currentTurnIndex(messages)
        val lastUserIndex = messages.indexOfLast { it.role == ChatRole.User }
        val breakpointIndex = if (cacheLastUserBlock) lastUserIndex else -1
        val dynamic = dynamicText?.takeIf { it.isNotEmpty() }
        // With no attachment blocks: the message holding the breakpoint, or the message left after [D] is split off, must become a text block; other messages still send a string content
        fun contentParts(msg: ChatMessage, index: Int, forceText: Boolean): List<String> =
            buildAnthropicParts(msg, activeModel, isCurrentTurn = index == currentTurnIndex, transport = transport)
                .ifEmpty {
                    if (forceText || index == breakpointIndex) {
                        listOfNotNull(msg.text.takeIf { it.isNotBlank() }?.let { """{"type":"text","text":${escapeJsonString(it)}}""" })
                    } else emptyList()
                }
        return messages.withIndex().joinToString(",") { (index, original) ->
            val role = original.role.name.lowercase()
            // If the last user text == [D] (body empty) or ends with "\n\n" + [D], split [D] off;
            // when nothing but [D] would remain to carry the breakpoint, send the message as is
            val split = if (index == lastUserIndex && dynamic != null) {
                dynamicBody(original.text, dynamic)?.let { body ->
                    val stripped = original.copy(text = body)
                    contentParts(stripped, index, forceText = true).takeIf { it.isNotEmpty() }?.let { stripped to it }
                }
            } else null
            val msg = split?.first ?: original
            val parts = split?.second ?: contentParts(original, index, forceText = false)
            val dynamicBlock = if (split != null) """{"type":"text","text":${escapeJsonString(dynamic!!)}}""" else null
            val marked = if (index == breakpointIndex && parts.isNotEmpty()) {
                parts.dropLast(1) + withAnthropicCacheControl(parts.last())
            } else parts
            val blocks = marked + listOfNotNull(dynamicBlock)
            if (blocks.isNotEmpty()) {
                """{"role":"$role","content":[${blocks.joinToString(",")}]}"""
            } else {
                """{"role":"$role","content":${escapeJsonString(msg.text)}}"""
            }
        }
    }

    /** Rule (a): when the text == [D] the body is empty; when it ends with "\n\n" + [D] returns the body without [D]; otherwise null. */
    internal fun dynamicBody(text: String, dynamic: String): String? = when {
        text == dynamic -> ""
        text.endsWith("\n\n$dynamic") -> text.removeSuffix("\n\n$dynamic")
        else -> null
    }

    /** The only policyRef value in the catalog's promptCache that lets official Anthropic place an explicit cache_control breakpoint. */
    const val ANTHROPIC_EXPLICIT_PROMPT_CACHE = "anthropic.explicit"

    /** Whether official Anthropic places a breakpoint: only the catalog verdict `anthropic.explicit` counts; a missing policyRef or unloaded metadata means no breakpoint. */
    fun usesAnthropicExplicitPromptCache(policyRef: String?): Boolean = policyRef == ANTHROPIC_EXPLICIT_PROMPT_CACHE

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
        val attachments = msg.attachments.orEmpty()
        val (ownText, carried) = splitOutboundPlaceholders(msg)
        // When the outbound gate removed all media and only placeholder lines remain, the parts array is still emitted, with the placeholders as a separate text part.
        if (attachments.isEmpty() && carried.isEmpty()) return null

        val transport = AttachmentTransportResolver.chatCompletions(providerKind)
        // Text-only wire (MiniMax Chat): one placeholder line per image, no image blocks.
        // On official wires the outbound gate has already decided which images stay, based on the vision projection.
        val imagePlaceholder = transport.imagePlaceholderText.takeUnless { transport.sendsImages }
        val parts = openAIChatMediaParts(attachments, sendImages = imagePlaceholder == null).toMutableList()

        // The transport decides whether an original file may enter the content parts. Only OpenRouter can; every
        // other Chat Completions upstream receives files as text.
        val plan = AttachmentDelivery.plan(
            baseText = withImagePlaceholders(ownText, attachments, imagePlaceholder),
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
        outboundPlaceholderText(carried)?.let { parts.add("""{"type":"text","text":${escapeJsonString(it)}}""") }
        return if (parts.isNotEmpty()) parts.joinToString(",") else null
    }

    /** Image / video parts of Chat Completions (image_url / video_url data URLs); no images are emitted when [sendImages] is false. */
    private fun openAIChatMediaParts(attachments: List<Attachment>, sendImages: Boolean): List<String> =
        attachments.mapNotNull { att ->
            when (att.kind) {
                AttachmentKind.Image -> {
                    if (!sendImages) return@mapNotNull null
                    val base64 = att.base64Data ?: att.thumbnailBase64 ?: return@mapNotNull null
                    val dataUri = if (base64.startsWith("data:")) base64 else "data:${ImageMediaType.resolve(base64, att.mimeType)};base64,$base64"
                    // detail=auto is sent explicitly; OpenAI-compatible upstreams consume the field
                    // and everyone else ignores it.
                    """{"type":"image_url","image_url":{"url":"$dataUri","detail":"auto"}}"""
                }
                AttachmentKind.Video -> {
                    val base64 = att.base64Data ?: return@mapNotNull null
                    val dataUri = if (base64.startsWith("data:")) base64 else "data:${att.mimeType};base64,$base64"
                    """{"type":"video_url","video_url":{"url":"$dataUri"}}"""
                }
                AttachmentKind.File -> null // handled through the delivery plan
            }
        }

    /**
     * Splits off the placeholder lines the outbound gate appended to the end of the body ([ChatMessage.outboundPlaceholders]): returns "body, placeholder lines".
     * When the body was rewritten as a whole (no longer ends with those lines) nothing is split or added, same as Web `splitOmittedImagePlaceholders`.
     */
    internal fun splitOutboundPlaceholders(msg: ChatMessage): Pair<String, List<String>> {
        val lines = msg.outboundPlaceholders.orEmpty()
        if (lines.isEmpty()) return msg.text to emptyList()
        val block = lines.joinToString(PLACEHOLDER_SEPARATOR)
        return when {
            msg.text == block -> "" to lines
            msg.text.endsWith("$PLACEHOLDER_SEPARATOR$block") -> msg.text.removeSuffix("$PLACEHOLDER_SEPARATOR$block") to lines
            else -> msg.text to emptyList()
        }
    }

    /**
     * For wires that can split into parts: the placeholder lines are merged into one standalone text part appended after all parts of the turn (body, file blocks, images),
     * with multiple lines separated by "\n\n" (same as iOS AttachmentDelivery, desktop delivery and Web `buildChatHistory`). Returns null when there are no placeholder lines.
     */
    internal fun outboundPlaceholderText(lines: List<String>): String? =
        lines.takeIf { it.isNotEmpty() }?.joinToString(PLACEHOLDER_SEPARATOR)

    /** For wires that only take a string content: the placeholder lines go after all of the message's text (body, file blocks), separated from the body and from each other by "\n\n". */
    internal fun withOutboundPlaceholderLines(text: String, lines: List<String>): String =
        appendPlaceholderLines(text, lines)

    /** A blank line between the body and every placeholder (image / video / outbound gate placeholder), the same shape on all platforms; an empty body leaves only the placeholders. */
    internal const val PLACEHOLDER_SEPARATOR = "\n\n"

    internal fun appendPlaceholderLines(text: String, lines: List<String>): String =
        if (lines.isEmpty()) text
        else listOfNotNull(text.takeIf { it.isNotBlank() }, *lines.toTypedArray()).joinToString(PLACEHOLDER_SEPARATOR)

    private fun buildOpenAIResponsesParts(
        msg: ChatMessage,
        activeModel: AIModel? = null,
        isCurrentTurn: Boolean = false,
        transport: AttachmentTransportProfile = AttachmentTransportProfile.OpenAIResponses,
    ): String? {
        val attachments = msg.attachments.orEmpty()
        val (ownText, carried) = splitOutboundPlaceholders(msg)
        if (attachments.isEmpty() && carried.isEmpty()) return null

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
            baseText = ownText,
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
        outboundPlaceholderText(carried)?.let { parts.add("""{"type":"input_text","text":${escapeJsonString(it)}}""") }

        return if (parts.isNotEmpty()) parts.joinToString(",") else null
    }

    private fun buildDeepSeekContent(msg: ChatMessage, activeModel: AIModel? = null, isCurrentTurn: Boolean = false): String {
        val (text, carried) = deepSeekContentAndPlaceholders(msg, activeModel, isCurrentTurn)
        return withOutboundPlaceholderLines(text, carried)
    }

    /** One DeepSeek message's "body + file injection" and the placeholder lines from the outbound gate, handed to the caller separately to assemble depending on whether there are media parts. */
    private fun deepSeekContentAndPlaceholders(
        msg: ChatMessage,
        activeModel: AIModel?,
        isCurrentTurn: Boolean,
    ): Pair<String, List<String>> {
        val attachments = msg.attachments.orEmpty()
        // Images / videos no longer get a hardcoded placeholder: media the outbound gate removed per the projection has been replaced by placeholder lines
        // (carried in outboundPlaceholders), and the media that remain are sent as parts by [buildDeepSeekMessages].
        val (ownText, carried) = splitOutboundPlaceholders(msg)

        // File attachments always go through AttachmentInjector; DeepSeek uses the markdown wrapper.
        val plan = AttachmentDelivery.plan(
            baseText = ownText,
            attachments = attachments,
            model = activeModel,
            transport = AttachmentTransportProfile.DeepSeekChat,
        )
        AttachmentDelivery.requireDeliverable(plan, isCurrentTurn)
        return plan.text to carried
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
        val attachments = msg.attachments.orEmpty()
        val (ownText, carried) = splitOutboundPlaceholders(msg)
        if (attachments.isEmpty() && carried.isEmpty()) return emptyList()

        val parts = mutableListOf<String>()
        // Video placeholders are folded into the text; the delivery plan decides whether each file goes up as a
        // document block or is injected as text.
        val videoPlaceholders = attachments.filter { it.kind == AttachmentKind.Video }
            .map { videoPlaceholder(transport.imagePlaceholderText ?: AttachmentTransportProfile.TEXT_ONLY_IMAGE_PLACEHOLDER) }
        // Text-only wire (MiniMax's Anthropic-compatible web search endpoint): one placeholder line per image, no image blocks.
        // On the MiniMax web search endpoint the outbound gate has already decided which images stay, based on the vision projection.
        val imagePlaceholder = transport.imagePlaceholderText.takeUnless { transport.sendsImages }
        val baseText = appendPlaceholderLines(withImagePlaceholders(ownText, attachments, imagePlaceholder), videoPlaceholders)
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
        outboundPlaceholderText(carried)?.let { parts.add("""{"type":"text","text":${escapeJsonString(it)}}""") }
        return parts
    }

    /** Text-only wires replace each image with one placeholder line appended after the body (same shape as DeepSeek / llama.cpp); wires that can carry images return the content unchanged. */
    fun withImagePlaceholders(text: String, attachments: List<Attachment>, placeholder: String?): String {
        if (placeholder == null) return text
        val lines = attachments.filter { it.kind == AttachmentKind.Image }.map { placeholder }
        if (lines.isEmpty()) return text
        return appendPlaceholderLines(text, lines)
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
        val (ownText, carried) = splitOutboundPlaceholders(msg)

        // The delivery plan decides the route; with Gemini's pdfNativeDefault set, every PDF goes up natively.
        val plan = AttachmentDelivery.plan(
            baseText = ownText,
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
        outboundPlaceholderText(carried)?.let { parts.add("""{"text":${escapeJsonString(it)}}""") }
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

    /** Provider-level attachment envelope (from metadata only, all false when missing); only read by the text-inline decision for official connections. */
    fun providerAttachmentEnvelope(providerKind: ProviderKind): AttachmentSupportInfo = providerKind.attachmentSupport // capability-lint-allow R1: official text inlining reads the provider envelope; the three input keys are not involved

    fun canAttachVideo(
        gate: AttachmentInputGate,
        mimeType: String,
    ): Boolean = gate.video && mimeType.lowercase().startsWith("video/")

    /** Native files follow the file_input projection; text inlining only accepts text files decodable as UTF-8 and is not gated by file_input. */
    fun canAttachFile(
        gate: AttachmentInputGate,
        mimeType: String,
        base64Data: String,
    ): Boolean {
        if (gate.nativeFile) return true
        if (!gate.textFileInline) return false
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
     * The base64 payload may contain line breaks / whitespace (upstreams that wrap at 76 columns).
     * If it is not accepted, completion cannot extract the image and the whole data URI stays in the text
     * written to the database; a single image can push the row past the CursorWindow limit.
     */
    fun extractInlineImages(text: String): Pair<String, List<Pair<String, String>>> {
        val regex = Regex("""!\[.*?]\((data:image/([^;]+);base64,([A-Za-z0-9+/=\s]+))\)""")
        val images = mutableListOf<Pair<String, String>>()
        val cleaned = regex.replace(text) { match ->
            val mime = "image/${match.groupValues[2]}"
            val data = match.groupValues[3].filterNot { it.isWhitespace() }
            images.add(mime to data)
            "" // remove from text
        }
        return cleaned.trim() to images
    }
}
