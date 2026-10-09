package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.ProviderServiceError
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Base64

/**
 * How each file attachment in a message is delivered: uploaded as original bytes, injected as text, or skipped because of a limit.
 *
 * Making the verdict a single result lets every request-building path consume the same answer to "which file did not get sent".
 * The request-building code only consumes the result. Pure function; it does not depend on the Android runtime.
 */
object AttachmentDelivery {

    enum class Route { Native, Text, Skipped }

    data class Item(
        val attachment: Attachment,
        val route: Route,
        val skipReason: AttachmentInjector.SkipReason? = null,
    )

    data class Plan(
        val items: List<Item>,
        /** The body text plus every file delivered as text, ready to write into the request body. */
        val text: String,
        /** The cap on the number of files delivered as text that this verdict used. */
        val maxTextFiles: Int = FileExtractionLimits.DEFAULT.maxFiles,
    ) {
        val native: List<Attachment> get() = items.filter { it.route == Route.Native }.map { it.attachment }
        val skipped: List<Item> get() = items.filter { it.route == Route.Skipped }
    }

    /**
     * @param baseText The body text worked out by the caller (the image / video placeholder lines differ between paths).
     * @param transport The transport this request goes through; it declares whether native upload is allowed, the wrapper format and the routing owner.
     */
    fun plan(
        baseText: String,
        attachments: List<Attachment>,
        model: AIModel?,
        transport: AttachmentTransportProfile,
    ): Plan {
        val files = attachments.filter { it.kind == AttachmentKind.File }
        val routes = files.map { file ->
            if (transport.allowsNativeFiles && model != null &&
                AttachmentRouter.decide(file, transport.routingProvider, model) == AttachmentRoute.Native
            ) {
                Route.Native
            } else {
                Route.Text
            }
        }
        val textIndexes = files.indices.filter { routes[it] == Route.Text }
        val limits = FileExtractionLimits.resolve(model)
        val injected = AttachmentInjector.injectAll(
            userText = baseText,
            attachments = toAttachmentPayloads(textIndexes.map { files[it] }),
            limits = limits,
            wrapper = transport.wrapper,
        )
        // Match skipped entries back to the original attachment by position in the text bucket; matching by file name would pick the wrong one among files with the same name.
        val skipReasons = injected.skippedIndexes
            .zip(injected.skipped)
            .associate { (bucketIndex, skipped) -> textIndexes[bucketIndex] to skipped.reason }
        val items = files.mapIndexed { index, file ->
            val reason = skipReasons[index]
            if (reason != null) Item(file, Route.Skipped, reason) else Item(file, routes[index])
        }
        return Plan(items = items, text = injected.text, maxTextFiles = limits.maxFiles)
    }

    /**
     * The index in [messages] of "the one being sent": the last user message, or -1 if there is none.
     * It follows the same rule as the "current turn input" of [OutboundAttachmentBudget].
     */
    fun currentTurnIndex(messages: List<ChatMessage>): Int = messages.indexOfLast { it.role == ChatRole.User }

    /**
     * If any file in the message being sent cannot be delivered, that message is not sent: the user attached it so the model would read it,
     * and dropping it silently would make the model answer without the material. History messages are not blocked: how that turn was sent is already settled,
     * and blocking there would leave the whole conversation unable to send its next message.
     */
    fun requireDeliverable(plan: Plan, isCurrentTurn: Boolean) {
        if (!isCurrentTurn) return
        undeliverable(plan)?.let { throw it }
    }

    /**
     * The error for when this verdict has files that cannot be delivered; null when everything can be delivered.
     * What is thrown at send time and what the composer shows before sending use the same discrimination.
     */
    fun undeliverable(plan: Plan): ProviderServiceError? {
        val skipped = plan.skipped
        if (skipped.isEmpty()) return null
        // If only the count is over, say the count; if some files do not fit the text total, name those files, and when the count is also over, include that limit too.
        val overTotal = skipped.filter { it.skipReason == AttachmentInjector.SkipReason.TotalCapExceeded }
        if (overTotal.isEmpty()) return ProviderServiceError.AttachmentCountOverLimit(plan.maxTextFiles)
        return ProviderServiceError.AttachmentTextOverLimit(
            fileNames = overTotal.map { it.attachment.fileName },
            countLimit = plan.maxTextFiles.takeIf { overTotal.size < skipped.size },
        )
    }

    /**
     * Converts File attachments into payloads the injector can consume.
     * Text content is decoded from base64Data; when extractionErrorCode is set, the error code fills the payload directly.
     */
    fun toAttachmentPayloads(
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

    fun tryDecodeBase64Text(base64: String): String? {
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
}
