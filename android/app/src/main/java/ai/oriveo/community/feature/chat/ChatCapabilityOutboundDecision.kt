package ai.oriveo.community.feature.chat

import ai.oriveo.community.core.model.CapabilityPreferenceValues
import ai.oriveo.community.core.model.CapabilityWebPreference
import ai.oriveo.community.core.model.ReasoningMode

/** Composer highlighting must describe the request that can leave the device, not the stored draft. */
data class ChatCapabilityOutboundDecision(
    val webSearchEnabled: Boolean,
    val reasoningMode: ReasoningMode,
    val reasoningIntent: String?,
) {
    val hasWebSelection: Boolean get() = webSearchEnabled
    val hasReasoningSelection: Boolean get() = reasoningIntent != null || reasoningMode != ReasoningMode.Automatic
    val hasActiveCapabilitySelection: Boolean get() = hasWebSelection || hasReasoningSelection

    companion object {
        /**
         * @param webReachesTheWire Whether this web preference will actually be compiled
         *   into the outbound request right now (`CapabilityWebPreferenceLiveness`).
         *   `controls.webAvailable` alone cannot answer that: it treats a connection as
         *   "available" without checking the exact transport, so a preset built for a
         *   different protocol looks satisfied when it effectively is not. This defaults
         *   to true only so older call sites that reason purely in terms of `controls`
         *   stay readable; real call sites must pass it explicitly.
         */
        fun resolve(
            requested: CapabilityPreferenceValues,
            controls: ChatModelCapabilityResolver.ModelControls,
            dormantOwners: Set<String> = emptySet(),
            customOwners: Set<String> = emptySet(),
            webReachesTheWire: Boolean = true,
        ): ChatCapabilityOutboundDecision {
            val webRequested = requested.web != CapabilityWebPreference.Off
            val webPermitted = "web" !in dormantOwners && webReachesTheWire && (
                "web" in customOwners || controls.webAvailable &&
                    (requested.web != CapabilityWebPreference.Force || controls.webForceAvailable)
                )
            val requestedIntent = requested.reasoningIntent
            val reasoningPermitted = "reasoning" !in dormantOwners && (
                "reasoning" in customOwners || requestedIntent != null &&
                    controls.reasoningState == "auto_available" &&
                    requestedIntent in controls.reasoningIntents
                )
            val effectiveIntent = requestedIntent.takeIf { reasoningPermitted }
            return ChatCapabilityOutboundDecision(
                webSearchEnabled = webRequested && webPermitted,
                reasoningMode = effectiveIntent.toReasoningMode(),
                reasoningIntent = effectiveIntent,
            )
        }

        private fun String?.toReasoningMode(): ReasoningMode = ReasoningMode.fromIntent(this)
    }
}
