package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport

/**
 * When saving an edited connection collides with changes made elsewhere, merge field by field.
 *
 * Baseline = the connection when the edit page was opened; the candidate is built from baseline + draft, so fields where candidate differs from baseline are the ones the user changed.
 * Persisted = live record + the user's changed fields: when both sides changed the same field the user wins, and anything the user did not change takes the live value.
 */
internal object RelayEditMerge {

    fun merge(live: Provider, baseline: Provider, edited: Provider): Provider {
        fun <T> pick(field: (Provider) -> T): T =
            if (field(edited) != field(baseline)) field(edited) else field(live)
        return live.copy(
            customName = pick { it.customName },
            baseUrlText = pick { it.baseUrlText },
            relayKind = pick { it.relayKind },
            models = pick { it.models },
            catalogModels = pick { it.catalogModels },
            cachedAvailableModelCount = pick { it.cachedAvailableModelCount },
            relayRequested = mergeRequested(live.relayRequested, baseline.relayRequested, edited.relayRequested),
        )
    }

    /** Merge only the fields the edit page save writes (the RelayEditSavePolicy.savedRequested group + connection security); everything else takes the live value. */
    private fun mergeRequested(
        live: RelayRequestedConfig?,
        baseline: RelayRequestedConfig?,
        edited: RelayRequestedConfig?,
    ): RelayRequestedConfig? {
        if (edited == baseline) return live
        if (live == null || baseline == null || edited == null) return edited
        fun <T> pick(field: (RelayRequestedConfig) -> T): T =
            if (field(edited) != field(baseline)) field(edited) else field(live)
        return live.copy(
            transport = pick { it.transport },
            authMode = pick { it.authMode },
            securityMode = pick { it.securityMode },
            serviceTier = pick { it.serviceTier },
            stream = pick { it.stream },
            disableResponseStorage = pick { it.disableResponseStorage },
            headers = pick { it.headers },
            queryParams = pick { it.queryParams },
            customUserAgent = pick { it.customUserAgent },
            reasoningEffort = pick { it.reasoningEffort },
            modelID = pick { it.modelID },
            resolvedAPIBaseURL = pick { it.resolvedAPIBaseURL },
            resolvedAPIBaseURLs = pick { it.resolvedAPIBaseURLs },
        )
    }

    private val schemePrefix = Regex("^([a-zA-Z][a-zA-Z0-9+.-]*)://")

    /** Address comparison key: add the scheme (per connection security), strip surrounding whitespace and the trailing slash, lowercase the scheme. */
    fun endpointKey(raw: String?, mode: RelayConnectionSecurityMode): String {
        val trimmed = raw?.trim()?.trimEnd('/').orEmpty()
        if (trimmed.isEmpty()) return ""
        val scheme = schemePrefix.find(trimmed)
        return if (scheme != null) {
            scheme.groupValues[1].lowercase() + trimmed.substring(scheme.groupValues[1].length)
        } else {
            val cleartext = mode == RelayConnectionSecurityMode.LocalHttp ||
                mode == RelayConnectionSecurityMode.PrivateVpn
            "${if (cleartext) "http" else "https"}://$trimmed"
        }
    }

    /**
     * Whether the connection identity (address, default protocol, auth mode, connection security) changed: the same field group as RelayEditPlan.classify.
     * Only if merged vs live record differs at the moment of persisting is the catalog cleared and a post-save refresh required.
     */
    fun connectionIdentityChanged(live: Provider, merged: Provider): Boolean {
        val mode = live.relayRequested?.securityMode ?: RelayConnectionSecurityMode.RemoteHttps
        val before = live.relayRequested ?: RelayRequestedConfig()
        val after = merged.relayRequested ?: RelayRequestedConfig()
        return endpointKey(live.baseUrlText, mode) != endpointKey(merged.baseUrlText, mode) ||
            before.transport != after.transport ||
            before.authMode != after.authMode ||
            before.securityMode != after.securityMode
    }

    /** Verification-related fields: if the live record differs from the values the probe used on these fields, this verification does not count. */
    data class ProbeIdentity(
        val endpoint: String,
        val transport: RelayTransport?,
        val authMode: RelayAuthMode?,
        val securityMode: RelayConnectionSecurityMode?,
        val apiKey: String,
        val headers: List<RelayKeyValue>?,
        val queryParams: List<RelayKeyValue>?,
        val userAgent: String?,
    )

    fun probeIdentity(provider: Provider, apiKey: String): ProbeIdentity {
        val requested = provider.relayRequested
        return ProbeIdentity(
            endpoint = endpointKey(provider.baseUrlText, requested?.securityMode ?: RelayConnectionSecurityMode.RemoteHttps),
            transport = requested?.transport,
            authMode = requested?.authMode,
            securityMode = requested?.securityMode,
            apiKey = apiKey,
            headers = requested?.headers,
            queryParams = requested?.queryParams,
            userAgent = requested?.customUserAgent,
        )
    }
}
