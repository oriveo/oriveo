package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.model.RelayTransportSource
import ai.oriveo.community.core.provider.RelayEndpointResolver
import kotlinx.coroutines.CancellationException

/** The first protocol of a model that passes the 1-token probe, and the API root resolved for that protocol. */
data class RelayModelProbePass(val transport: RelayTransport, val apiRoot: String)

/**
 * Result of probing one model: [pass] null means no candidate passed; [attempted] lists the protocols actually sent, in order,
 * and [lastError] is the last failure (so callers keep the existing ping failure message).
 */
data class RelayModelProbeOutcome(
    val pass: RelayModelProbePass?,
    val attempted: List<RelayTransport>,
    val lastError: Throwable?,
)

/**
 * Per-model probe (three-way outcome, see `probeOutcomeRules`): send a 1-token request for each candidate (at most 2) in turn.
 * Pass -> stop; route-level rejection ([RelayProtocolFallback.isRouteRejection], the same criterion as protocol fallback when sending) -> try the next one;
 * anything else (400 / 401 / other 403 / 422 / 429 / 5xx / network ...) is "could not be determined" -> stop immediately and do not send the next candidate with the same key.
 * It only probes and does not write back: the caller writes back with [applyingPass] inside its own storage transaction
 * (the add flow writes at registration; lazy verification / re-detection write on their own write-back paths).
 */
object RelayModelProbe {
    /** The API root of this connection when the model protocol is temporarily set to [candidate]; the same resolver function as outbound sending. */
    fun apiRoot(provider: Provider, modelID: String, candidate: RelayTransport): String? =
        RelayEndpointResolver.effectiveAPIRoot(provider, AIModel(id = modelID, name = modelID, relayTransport = candidate))

    /**
     * [ping] sends one 1-token request for (candidate protocol, that protocol's root) with this client's existing ping primitive;
     * a normal return = pass, a thrown error = failure. Cancellation propagates upward as usual.
     */
    suspend fun probe(
        provider: Provider,
        modelID: String,
        candidates: List<RelayTransport>,
        ping: suspend (transport: RelayTransport, apiRoot: String) -> Unit,
    ): RelayModelProbeOutcome {
        val attempted = mutableListOf<RelayTransport>()
        var lastError: Throwable? = null
        for (candidate in candidates.distinct().take(RelayProbeCandidates.MAX_CANDIDATES)) {
            val root = apiRoot(provider, modelID, candidate) ?: continue
            attempted += candidate
            try {
                ping(candidate, root)
                return RelayModelProbeOutcome(RelayModelProbePass(candidate, root), attempted, null)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                lastError = error
                if (!RelayProtocolFallback.isRouteRejection(error)) break
            }
        }
        return RelayModelProbeOutcome(null, attempted, lastError)
    }

    /**
     * Write a pass into the connection: for that model (entries with the same id in the enabled list and the catalog) protocol = the passing protocol, source = reachable;
     * `relayRequested.resolvedAPIBaseURLs` gains only this one entry. The connection default protocol, the single-value root and other keys are untouched.
     */
    fun applyingPass(provider: Provider, modelID: String, pass: RelayModelProbePass): Provider {
        fun List<AIModel>.pinned() = map { model ->
            if (model.id != modelID) {
                model
            } else {
                model.copy(relayTransport = pass.transport, relayTransportSource = RelayTransportSource.Reachable)
            }
        }
        val requested = provider.relayRequested ?: return provider.copy(
            models = provider.models.pinned(),
            catalogModels = provider.catalogModels.pinned(),
        )
        return provider.copy(
            models = provider.models.pinned(),
            catalogModels = provider.catalogModels.pinned(),
            relayRequested = requested.copy(
                resolvedAPIBaseURLs = requested.resolvedAPIBaseURLs.orEmpty() + (pass.transport.value to pass.apiRoot),
            ),
        )
    }
}
