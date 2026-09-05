package ai.oriveo.community.core.provider

import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayConnectionSecurityMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The UI-facing decision surface for `securityMode`.
 *
 * [RelayEndpointPolicy] remains the only security boundary. This object just assembles its
 * classification results into "which option is selectable" and "is there a suggestion worth
 * offering"; it never changes the mode the user already picked.
 */
object RelaySecurityModePolicy {
    private val schemeRegex = Regex("^[a-zA-Z][a-zA-Z0-9+\\-.]*://")

    data class Option(
        val enabled: Boolean,
        /**
         * A stable slug for [RelayEndpointPolicy.Classification.reason]; the UI only maps it to
         * a localized string.
         */
        val reason: String,
        val normalizedEndpoint: String? = null,
    )

    data class Assessment(
        val localHttp: Option,
        val privateVpn: Option,
        /**
         * null means no downgrade is being suggested. A non-null value may only be shown on a
         * confirmation card; it must never be written back into the mode.
         */
        val suggestedMode: RelayConnectionSecurityMode?,
    )

    fun assess(rawEndpoint: String, resolvedIPs: List<String>): Assessment {
        val trimmed = rawEndpoint.trim()
        if (trimmed.isEmpty()) return unavailable("unknown_address")

        // An explicitly HTTPS address must not be presented as "local HTTP is an option here".
        // The underlying policy admits HTTPS first so that encrypted local-network addresses keep
        // working, but the form layer is required to change the mode explicitly instead.
        if (trimmed.startsWith("https://", ignoreCase = true)) {
            return unavailable("encrypted_endpoint")
        }

        val noCredentials = RelayEndpointPolicy.Credentials(authMode = RelayAuthMode.None)
        fun option(mode: RelayConnectionSecurityMode): Option {
            val result = RelayEndpointPolicy.classify(
                raw = trimmed,
                securityMode = mode,
                resolvedIPs = resolvedIPs,
                credentials = noCredentials,
            )
            return Option(result.allowed, result.reason, result.normalized)
        }

        val local = option(RelayConnectionSecurityMode.LocalHttp)
        val vpn = option(RelayConnectionSecurityMode.PrivateVpn)
        val suggested = when {
            vpn.enabled && vpn.reason == "private_vpn" -> RelayConnectionSecurityMode.PrivateVpn
            local.enabled && local.reason in setOf("loopback", "private_lan", "link_local") ->
                RelayConnectionSecurityMode.LocalHttp
            else -> null
        }
        return Assessment(local, vpn, suggested)
    }

    /**
     * DNS is only used to produce a suggestion. If the host does not resolve, stay on
     * remote_https rather than guessing a downgrade.
     */
    suspend fun assessResolving(rawEndpoint: String): Assessment = withContext(Dispatchers.IO) {
        assess(rawEndpoint, RelayEndpointPolicy.resolveHostIPs(rawEndpoint))
    }

    fun normalizedEndpoint(
        rawEndpoint: String,
        mode: RelayConnectionSecurityMode,
        assessment: Assessment,
    ): String? = when (mode) {
        RelayConnectionSecurityMode.RemoteHttps -> RelayEndpointPolicy.normalize(rawEndpoint, mode)
        RelayConnectionSecurityMode.LocalHttp -> assessment.localHttp.normalizedEndpoint
            ?.takeIf { assessment.localHttp.enabled }
        RelayConnectionSecurityMode.PrivateVpn -> assessment.privateVpn.normalizedEndpoint
            ?.takeIf { assessment.privateVpn.enabled }
        RelayConnectionSecurityMode.TofuHttps -> null // TOFU comes only from a confirmed-fingerprint pairing flow.
    }

    fun hasExplicitScheme(rawEndpoint: String): Boolean = schemeRegex.containsMatchIn(rawEndpoint.trim())

    /**
     * Returns the range covering a scheme that was filled in for the user. If the input already
     * carried a scheme, no highlight is faked.
     */
    fun addedSchemeHighlightRange(rawEndpoint: String, normalizedEndpoint: String): IntRange? {
        if (hasExplicitScheme(rawEndpoint)) return null
        val schemeEnd = normalizedEndpoint.indexOf("://").takeIf { it > 0 }?.plus(3) ?: return null
        return 0 until schemeEnd
    }

    private fun unavailable(reason: String) = Assessment(
        localHttp = Option(false, reason),
        privateVpn = Option(false, reason),
        suggestedMode = null,
    )

}
