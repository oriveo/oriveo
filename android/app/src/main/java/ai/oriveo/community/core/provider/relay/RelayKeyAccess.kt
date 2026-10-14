package ai.oriveo.community.core.provider.relay

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderServiceError
import ai.oriveo.community.core.model.RelayKeyAccessOutcome
import ai.oriveo.community.core.model.RelayKey
import ai.oriveo.community.core.model.RelayKeyAccessSignal
import ai.oriveo.community.core.model.RelayKeyStatus
import ai.oriveo.community.core.model.RelayCredentialPolicy
import ai.oriveo.community.core.provider.ProviderCredentialResolver

/**
 * Relay decision and write-back for whether this key can use this model. Pure functions, no I/O.
 * Source of truth for the rules: shared fixture `relay/key-access.v1.json` (signals / classifyCases / sendCases).
 *
 * The decision runs before the capability-rejection loop: `model_access_denied` writes no capability negative cache, does no protocol-level fallback and does not resend with another key;
 * a bare model / group / not found is not a signal; 5xx is always `none` (done-hub folds into 503, indistinguishable from upstream busy).
 */
object RelayKeyAccess {
    private val DENIED_STATUSES = setOf(400, 403, 404)
    private val DENIED_SIGNALS = listOf(
        "model_not_found", "key_model_access_denied", "team_model_access_denied", "user_model_access_denied",
        "token_model_forbidden",
        "无权访问模型", "无权使用模型", "无权使用分组", "is not available for this group",
        "is not supported for current token", "unknown provider for model", "do not have access to the model",
        "does not have access to model", "not allowed to access model", "not allowed to use model",
    )
    private val INVALID_CODES_403 = listOf("api_key_expired", "expired_key", "token_expired")
    private val LIMITED_CODES_403 = listOf(
        "insufficient_user_quota", "insufficient_balance", "insufficient_quota", "budget_exceeded",
        "api_key_quota_exhausted", "usage_limit_exceeded",
    )

    /** The raw response body is matched by case-insensitive substring; order: 401 / 402 / 429, then 403 with a key code, then no-access phrases, then none. */
    fun classify(status: Int, body: String): RelayKeyAccessOutcome {
        val lower = body.lowercase()
        fun has(signals: List<String>) = signals.any { lower.contains(it.lowercase()) }
        return when {
            status == 401 -> RelayKeyAccessOutcome.KeyInvalid
            status == 402 || status == 429 -> RelayKeyAccessOutcome.KeyLimited
            status == 403 && has(INVALID_CODES_403) -> RelayKeyAccessOutcome.KeyInvalid
            status == 403 && has(LIMITED_CODES_403) -> RelayKeyAccessOutcome.KeyLimited
            status in DENIED_STATUSES && has(DENIED_SIGNALS) -> RelayKeyAccessOutcome.ModelAccessDenied
            else -> RelayKeyAccessOutcome.None
        }
    }

    fun signal(status: Int, body: String): RelayKeyAccessSignal = RelayKeyAccessSignal(status, classify(status, body))

    /** The decision attached to an error (including a wrapped one); none means it is not a relay HTTP error. */
    fun signalOf(error: Throwable?): RelayKeyAccessSignal? {
        var current = error
        while (current != null) {
            (current as? ProviderServiceError)?.relayKeyAccess?.let { return it }
            current = current.cause.takeIf { it !== current }
        }
        return null
    }

    fun isModelAccessDenied(status: Int, body: String): Boolean =
        classify(status, body) == RelayKeyAccessOutcome.ModelAccessDenied

    fun isModelAccessDenied(error: Throwable?): Boolean =
        signalOf(error)?.outcome == RelayKeyAccessOutcome.ModelAccessDenied

    /**
     * Write-back on send failure: `model_access_denied` records `relayDeniedKeyID` = [keyID] on that enabled model (written for a single key too, with id `initial`);
     * `key_invalid` / `key_limited` mark that key invalid / limited (also for a single key; nothing is written if the state did not change); `none` changes nothing.
     */
    fun applyingFailure(provider: Provider, modelID: String, keyID: String, signal: RelayKeyAccessSignal, now: Long): Provider =
        when (signal.outcome) {
            RelayKeyAccessOutcome.ModelAccessDenied -> provider.copy(
                models = provider.models.map { if (it.id == modelID && it.relayDeniedKeyID != keyID) it.copy(relayDeniedKeyID = keyID) else it },
            )
            RelayKeyAccessOutcome.KeyInvalid -> withKeyStatuses(provider, mapOf(keyID to RelayKeyStatus("invalid", signal.status)), now)
            RelayKeyAccessOutcome.KeyLimited -> withKeyStatuses(provider, mapOf(keyID to RelayKeyStatus("limited", signal.status)), now)
            RelayKeyAccessOutcome.None -> provider
        }

    /** Write-back on send success: clear the no-access marker if it equals this key; if that key is not ok, write ok (also for a single key). */
    fun applyingSuccess(provider: Provider, modelID: String, keyID: String, now: Long): Provider {
        val undenied = provider.copy(
            models = provider.models.map { if (it.id == modelID && it.relayDeniedKeyID == keyID) it.copy(relayDeniedKeyID = null) else it },
        )
        return withKeyStatuses(undenied, mapOf(keyID to RelayKeyStatus("ok")), now)
    }

    /**
     * Key state of a generation request (`key-access.v1.json` generationCases): 2xx gives ok; `key_invalid` gives invalid;
     * `key_limited` gives limited; everything else (no access, route-level rejection, CLI gating, capability rejection, 5xx, network with [status] null) gives null and leaves the state alone.
     * ok carries no HTTP status code, the same shape as the ok from catalog fetching (written only when state / httpStatus changed, never rewritten back and forth).
     */
    fun generationStatus(status: Int?, body: String): RelayKeyStatus? = when {
        status == null -> null
        status in 200..299 -> RelayKeyStatus("ok")
        else -> generationStatus(signal(status, body))
    }

    /** A classified non-2xx ([RelayKeyAccessSignal] attached to the error) maps to a key state; null when no key problem can be identified. */
    fun generationStatus(signal: RelayKeyAccessSignal): RelayKeyStatus? = when (signal.outcome) {
        RelayKeyAccessOutcome.KeyInvalid -> RelayKeyStatus("invalid", signal.status)
        RelayKeyAccessOutcome.KeyLimited -> RelayKeyStatus("limited", signal.status)
        RelayKeyAccessOutcome.ModelAccessDenied, RelayKeyAccessOutcome.None -> null
    }

    /** Result of one generation request: [error] null means success (ok); null also when the error carries no decision (network, local validation). */
    fun generationStatusOf(error: Throwable?): RelayKeyStatus? =
        if (error == null) RelayKeyStatus("ok") else signalOf(error)?.let(::generationStatus)

    /** Whether there is anything to write after success (the caller uses it to decide whether to read the store and write back; in the normal single-key case storage is not touched). */
    fun successChanges(provider: Provider, modelID: String, keyID: String): Boolean =
        applyingSuccess(provider, modelID, keyID, now = 0L) != provider

    /**
     * Write states per key; nothing is written when both state and httpStatus are unchanged (checkedAt is not refreshed either). checkedAt in [statuses] is always set to [now].
     * The first time a single key (no key list) has its primary key state written, the list is materialized as one entry `[{id: initial, apiKey: "", status}]`;
     * no list is created if there is no state to write. When the request carried no key (auth mode none, or that key's value is empty) nothing is written or materialized.
     */
    fun withKeyStatuses(provider: Provider, statuses: Map<String, RelayKeyStatus>, now: Long): Provider {
        if (statuses.isEmpty() || !RelayCredentialPolicy.requiresCredential(provider.relayRequested)) return provider
        val carried = statuses.filterKeys { ProviderCredentialResolver.keySecret(provider, it).isNotBlank() }
        if (carried.isEmpty()) return provider
        return writingKeyStatuses(provider, carried, now)
    }

    private fun writingKeyStatuses(provider: Provider, statuses: Map<String, RelayKeyStatus>, now: Long): Provider {
        // An empty list is the same as no list: a single entry is materialized all the same.
        val keys = provider.relayKeys?.takeIf { it.isNotEmpty() }
            ?: statuses[RelayKeyBinding.IMPLICIT_KEY_ID]?.let { listOf(RelayKey(id = RelayKeyBinding.IMPLICIT_KEY_ID)) }
            ?: return provider
        var changed = false
        val next = keys.map { key ->
            val status = statuses[key.id] ?: return@map key
            if (key.status?.state == status.state && key.status.httpStatus == status.httpStatus) return@map key
            changed = true
            key.copy(status = status.copy(checkedAt = now))
        }
        return if (changed) provider.copy(relayKeys = next) else provider
    }
}
