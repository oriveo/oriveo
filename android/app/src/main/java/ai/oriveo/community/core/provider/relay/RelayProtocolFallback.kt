package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.isRelayGenerationSuccessResponse

/**
 * Relay protocol-level fallback. See protocolFallbackCases in the shared fixture `relay/negative-cache.v1.json`.
 * Outer protocol fallback, inner native-file fallback: first fall back to text on the original protocol, and only switch protocols if it is still a route-level rejection; on success the new protocol is written to the model as observed,
 * on failure the second error is reported and no negative cache entry is recorded.
 *
 * Route-level rejection (`protocolFallbackRules`) = this protocol path does not accept the request (404 / 405 / 415, a 403 with a registered phrase, a 2xx web page). Protocol fallback while sending and per-model probing
 * ([RelayModelProbe], `probeOutcomeRules.routeRejected`) recognize only this single criterion, [isRouteRejection].
 */
object RelayProtocolFallback {
    private val ROUTE_STATUSES = setOf(404, 405, 415)
    private val ROUTE_PHRASE_STATUSES = setOf(403)

    /** The exact wording sub2api uses when rejecting /v1/messages for a group without messages dispatch enabled; a 403 without it is a key / account problem and does not switch protocols. */
    private val ROUTE_PHRASES = listOf("does not allow /v1/messages dispatch")

    /**
     * The response body (case-insensitive) contains a registered phrase. The raw response body is only available in RelayErrorMapper, which computes this and attaches it to the error object.
     * JSON may escape slashes as `\/` (the PHP json_encode default), so they are restored before comparing.
     */
    fun bodyNamesRouteRejection(body: String): Boolean {
        val lower = body.replace("\\/", "/").lowercase()
        return ROUTE_PHRASES.any { lower.contains(it) }
    }

    /**
     * A 2xx that is a web page (`htmlSuccessIsRouteRejection`): the gateway's SPA fallback page means this path is not an API route.
     * "Is it a web page" uses the same judgement as generation response validation ([isRelayGenerationSuccessResponse]); a missing [contentType] is treated as JSON.
     */
    fun isHtmlSuccessPage(status: Int, body: String, contentType: String?): Boolean =
        status in 200..299 && !isRelayGenerationSuccessResponse(body, contentType)

    private val WEB_PAGE_LINE_PREFIXES = listOf("<!doctype html", "<html", "<head", "<body")

    /**
     * Whether the first non-empty line of the stream body start [head] (possibly not fully received yet) is a web page: it starts with `<!doctype html` / `<html` /
     * `<head` / `<body` (case-insensitive, with a word boundary after the tag name). Blank lines do not count as the first line. null = not enough received to decide, wait for more.
     */
    fun streamHeadIsWebPage(head: String): Boolean? {
        val line = head.trimStart().removePrefix("\uFEFF").trimStart()
        if (line.isEmpty()) return null
        val lower = line.substringBefore('\n').lowercase()
        val complete = line.contains('\n')
        for (prefix in WEB_PAGE_LINE_PREFIXES) {
            if (!lower.startsWith(prefix)) continue
            // Word boundary (same as `<html\b` on iOS / Web): <htmlx / <header do not count; if no character has arrived after the tag name yet, wait.
            val next = lower.getOrNull(prefix.length) ?: return if (complete) true else null
            if (!(next.isLetterOrDigit() || next == '_')) return true
        }
        return if (!complete && WEB_PAGE_LINE_PREFIXES.any { it.startsWith(lower) }) null else false
    }

    fun isRouteRejection(status: Int, body: String, contentType: String? = null): Boolean =
        isRouteRejection(status, bodyNamesRouteRejection(body), isHtmlSuccessPage(status, body, contentType))

    private fun isRouteRejection(status: Int, bodyNamesRoute: Boolean, htmlSuccessPage: Boolean): Boolean =
        htmlSuccessPage || status in ROUTE_STATUSES || (status in ROUTE_PHRASE_STATUSES && bodyNamesRoute)

    /**
     * Whether a failure is a route-level rejection. The status code is the HTTP-layer one: in-stream error frames do not count; when 401 / 403 were mapped to an error type without a status code,
     * the raw status attached by RelayErrorMapper is used. Network errors and other non-HTTP failures never count.
     */
    fun isRouteRejection(error: Throwable?): Boolean {
        val serviceError = error as? ProviderServiceError ?: return false
        val status = when (serviceError) {
            is ProviderServiceError.Upstream -> serviceError.statusCode.takeUnless { serviceError.streamErrorFrame }
            is ProviderServiceError.RelayUpstream -> serviceError.statusCode
            else -> serviceError.relayKeyAccess?.status
        } ?: return false
        return isRouteRejection(status, serviceError.relayBodyNamesRouteRejection, serviceError.relayHtmlSuccessPage)
    }

    /**
     * Only route-level rejections before any output, with a source other than user (a null that follows the connection also switches), and the message has not switched yet;
     * the next protocol = the first candidate that differs from the current protocol; if there is none, do not switch.
     */
    fun nextTransport(
        current: RelayTransport,
        source: RelayTransportSource?,
        candidates: List<RelayTransport>,
        routeRejected: Boolean,
        outputStarted: Boolean,
        alreadySwitched: Boolean,
    ): RelayTransport? {
        if (!mayFallBack(source, routeRejected, outputStarted, alreadySwitched)) return null
        return candidates.firstOrNull { it != current }
    }

    /** The half of the criterion that is independent of candidates; the outbound layer uses it to filter first and only then looks up candidates. */
    fun mayFallBack(source: RelayTransportSource?, routeRejected: Boolean, outputStarted: Boolean, alreadySwitched: Boolean): Boolean =
        routeRejected && !outputStarted && !alreadySwitched && source != RelayTransportSource.User

    /**
     * Write-back after a successful protocol switch: models with the same id in both the enabled list and the catalog are updated; a user source is left alone; if the model's currently effective protocol
     * is no longer the [sentTransport] at the start of sending (it was changed meanwhile), the write-back is discarded.
     */
    fun applyingObserved(provider: Provider, modelID: String, sentTransport: RelayTransport, transport: RelayTransport): Provider {
        fun List<AIModel>.written() = map { model ->
            if (
                model.id == modelID &&
                model.relayTransportSource != RelayTransportSource.User &&
                ai.oriveo.community.core.provider.RelayEndpointResolver.effectiveTransport(provider, model) == sentTransport
            ) {
                model.copy(relayTransport = transport, relayTransportSource = RelayTransportSource.Observed)
            } else {
                model
            }
        }
        return provider.copy(models = provider.models.written(), catalogModels = provider.catalogModels.written())
    }
}
