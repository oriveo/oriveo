package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.StreamEvent
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow

/**
 * Fallback for [NativeFileMode.AlwaysWithTextFallback] routes: when a request carrying original file blocks is rejected with
 * 400 / 404 / 413 / 415 / 422 before the upstream produces any output, the files are injected as text and the request is resent once.
 *
 * Whether a relay or subscription backend accepts file blocks varies from site to site and cannot be known beforehand; text injection does not depend on the other end passing them through, so it is the safety net.
 * Only the status code is looked at; the upstream's error text is not parsed. After a successful resend, this process remembers that the connection does not accept file blocks and goes straight to text,
 * saving a round trip on every message; if the resend also fails, the first error is thrown, because that is what this request really ran into.
 */
object NativeFileFallback {

    /** One protocol on one connection. */
    data class Lane(val connectionId: String, val providerKind: ProviderKind, val protocol: String) {
        internal val key: String get() = "$connectionId|$protocol"
    }

    private val rejectedStatuses = setOf(400, 404, 413, 415, 422)
    private val textOnlyLanes: MutableSet<String> = ConcurrentHashMap.newKeySet()

    /** This connection has already been shown not to accept file blocks. */
    fun isTextOnly(lane: Lane): Boolean = lane.key in textOnlyLanes

    /**
     * Whether any file in these messages goes native under [transport] while also having extracted text.
     * If none does there is nothing to fall back to: when every rejected file is a scanned document, resending would only hand the error note to the model.
     */
    fun hasRecoverableNativeFile(
        messages: List<ChatMessage>,
        model: AIModel?,
        transport: AttachmentTransportProfile,
    ): Boolean = messages.any { message ->
        val attachments = message.attachments
        !attachments.isNullOrEmpty() &&
            AttachmentDelivery.plan("", attachments, model, transport).native.any(::hasExtractedText)
    }

    private fun hasExtractedText(attachment: Attachment): Boolean =
        attachment.extractionErrorCode == null && !attachment.base64Data.isNullOrEmpty()

    private fun isRejection(error: Throwable): Boolean = when (error) {
        is ProviderServiceError.Upstream -> error.statusCode in rejectedStatuses
        is ProviderServiceError.RelayUpstream -> error.statusCode in rejectedStatuses
        else -> false
    }

    /**
     * @param recoverable See [hasRecoverableNativeFile]; evaluated only after the first rejection.
     * @param attempt Sends one request; when the argument is true this attempt must not carry file blocks.
     */
    suspend fun <T> run(lane: Lane, recoverable: () -> Boolean, attempt: suspend (textOnly: Boolean) -> T): T {
        if (isTextOnly(lane)) return attempt(true)
        val first = try {
            return attempt(false)
        } catch (error: ProviderServiceError) {
            if (!isRejection(error) || !recoverable()) throw error
            error
        }
        val result = try {
            attempt(true)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            throw first
        }
        remember(lane)
        return result
    }

    /** The streaming version of [run]: once anything has been emitted downstream on the first attempt, there is no fallback. */
    fun stream(
        lane: Lane,
        recoverable: () -> Boolean,
        attempt: (textOnly: Boolean) -> Flow<StreamEvent>,
    ): Flow<StreamEvent> = flow {
        if (isTextOnly(lane)) {
            emitAll(attempt(true))
            return@flow
        }
        var emitted = false
        val first = try {
            attempt(false).collect {
                emitted = true
                emit(it)
            }
            return@flow
        } catch (error: ProviderServiceError) {
            if (emitted || !isRejection(error) || !recoverable()) throw error
            error
        }
        var resentEmitted = false
        try {
            attempt(true).collect {
                resentEmitted = true
                emit(it)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (second: Exception) {
            // A failure after the resend has already streamed content to the screen is a different matter and is reported as it is.
            throw if (resentEmitted) second else first
        }
        remember(lane)
    }

    private fun remember(lane: Lane) {
        textOnlyLanes.add(lane.key)
    }

    internal fun resetForTest() = textOnlyLanes.clear()
}
