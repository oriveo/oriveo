package ai.oriveo.community.core.attachments

import ai.oriveo.community.core.capability.InputNegativeCache
import ai.oriveo.community.core.capability.InputRejectionFlow
import ai.oriveo.community.core.capability.truth.relayInputNegativeCacheTarget
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.StreamEvent
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.relay.RelayKeyAccess
import ai.oriveo.community.core.provider.relay.RelayNegativeCache
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

    /**
     * Persistent memory for the relay shape: when given, it replaces the in-process connection x protocol memory. A hit on the `file` negative cache goes straight to text;
     * after a successful resend, `file` is recorded only if the first rejection was a rejected signal (the trigger condition and "resend text only once" are unchanged).
     */
    class RelayMemory(
        val cache: RelayNegativeCache,
        val key: RelayNegativeCache.Key,
        /** Model-level file override; On beats the `file` negative cache, and a rejection still falls back and is still recorded as usual. */
        val fileOverride: Boolean? = null,
        /** Negative cache v2: recording the v1 `file` entry also writes a `file_input` entry (the decision still reads v1). */
        val inputNegativeCache: InputNegativeCache = InputNegativeCache.shared,
    ) {
        internal fun isTextOnly(): Boolean =
            fileOverride != true && cache.isRejected(key, RelayNegativeCache.Kind.File)
        internal fun remember(first: Throwable): Boolean {
            if (!cache.recordIfRejected(key, RelayNegativeCache.Kind.File, first)) return false
            // The relay verdict for the file key never reads connection evidence (always unknown), so the connection / model in the key are enough for provider / model.
            InputRejectionFlow.recordRelay(
                relayInputNegativeCacheTarget(
                    provider = Provider(id = key.connectionId, kind = ProviderKind.Relay),
                    model = AIModel(id = key.modelId, name = key.modelId),
                    transport = key.transport,
                    key = CapabilityEvidenceFacade.FILE_INPUT,
                ),
                inputNegativeCache,
            )
            return true
        }
    }

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
            AttachmentDelivery.plan("", attachments, model, transport).native.any(AttachmentDelivery::hasUsableText)
    }

    /**
     * Whether, when these messages are built under [transport], some files go native and none of them has extracted text (all scanned documents and the like).
     * When a protocol fallback switches to a protocol that does not accept native files, such a request has no text version to send, so it does not switch (agreed across all three platforms).
     */
    fun hasOnlyUnrecoverableNativeFiles(
        messages: List<ChatMessage>,
        model: AIModel?,
        transport: AttachmentTransportProfile,
    ): Boolean {
        val native = messages.flatMap { message ->
            val attachments = message.attachments
            if (attachments.isNullOrEmpty()) emptyList()
            else AttachmentDelivery.plan("", attachments, model, transport).native
        }
        return native.isNotEmpty() && native.none(AttachmentDelivery::hasUsableText)
    }

    private fun isRejection(error: Throwable): Boolean = when {
        // A relay saying "this key cannot use this model" is not a file rejection; resending as text would be rejected just the same.
        RelayKeyAccess.isModelAccessDenied(error) -> false
        error is ProviderServiceError.Upstream -> error.statusCode in rejectedStatuses
        error is ProviderServiceError.RelayUpstream -> error.statusCode in rejectedStatuses
        else -> false
    }

    /**
     * @param recoverable See [hasRecoverableNativeFile]; evaluated only after the first rejection.
     * @param onUnrecovered Called once, before the first error is thrown, when the first attempt carrying file blocks is rejected before any output
     *   and could not fall back (not recoverable, or the text resend also failed). Whether it is a rejection signal and whether there are native file blocks is the caller's call.
     * @param attempt Sends one request; when the argument is true this attempt must not carry file blocks.
     */
    suspend fun <T> run(
        lane: Lane,
        recoverable: () -> Boolean,
        relayMemory: RelayMemory? = null,
        onUnrecovered: ((first: ProviderServiceError) -> Unit)? = null,
        attempt: suspend (textOnly: Boolean) -> T,
    ): T {
        if (isTextOnly(lane, relayMemory)) return attempt(true)
        val first = try {
            return attempt(false)
        } catch (error: ProviderServiceError) {
            if (!isRejection(error)) throw error
            if (!recoverable()) {
                onUnrecovered?.invoke(error)
                throw error
            }
            error
        }
        val result = try {
            attempt(true)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            onUnrecovered?.invoke(first)
            throw first
        }
        remember(lane, relayMemory, first)
        return result
    }

    /** The streaming version of [run]: once anything has been emitted downstream on the first attempt, there is no fallback. */
    fun stream(
        lane: Lane,
        recoverable: () -> Boolean,
        relayMemory: RelayMemory? = null,
        onUnrecovered: ((first: ProviderServiceError) -> Unit)? = null,
        attempt: (textOnly: Boolean) -> Flow<StreamEvent>,
    ): Flow<StreamEvent> = flow {
        if (isTextOnly(lane, relayMemory)) {
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
            if (emitted || !isRejection(error)) throw error
            if (!recoverable()) {
                onUnrecovered?.invoke(error)
                throw error
            }
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
            if (resentEmitted) throw second
            onUnrecovered?.invoke(first)
            throw first
        }
        remember(lane, relayMemory, first)
    }

    private fun isTextOnly(lane: Lane, relayMemory: RelayMemory?): Boolean =
        relayMemory?.isTextOnly() ?: isTextOnly(lane)

    private fun remember(lane: Lane, relayMemory: RelayMemory?, first: Throwable) {
        if (relayMemory != null) {
            relayMemory.remember(first)
            return
        }
        textOnlyLanes.add(lane.key)
    }

    internal fun resetForTest() = textOnlyLanes.clear()
}
