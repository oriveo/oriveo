package ai.oriveo.community.feature.providers.relay

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.LocalEngineChannels

/**
 * Whether a test result may be written back to the saved connection: is the draft the same connection as the stored one.
 * relayKind, the connection-level reasoning effort and modelID are not part of the connection identity: the first is derived
 * from the default transport on save and the last is cleared on save. If they were not stripped, an existing connection
 * with nothing changed would still be judged "different".
 */
internal fun relayRequestedMatchesPersisted(
    persisted: RelayRequestedConfig,
    candidate: RelayRequestedConfig,
): Boolean = persisted.comparableForEdit() == candidate.comparableForEdit()

private fun RelayRequestedConfig.comparableForEdit(): RelayRequestedConfig = copy(
    reasoningEffort = null,
    // modelID is cleared on save; the verification sample is compared separately.
    modelID = null,
    serviceTier = serviceTier?.trim()?.takeIf { it.isNotEmpty() },
    customUserAgent = customUserAgent?.trim()?.takeIf { it.isNotEmpty() },
    headers = headers?.cleanRelayAdvancedPairs(),
    queryParams = queryParams?.cleanRelayAdvancedPairs(),
)

/** Trim keys and drop empty ones; keep values as they are, since whitespace may be part of a value. */
internal fun List<RelayKeyValue>.cleanRelayAdvancedPairs(): List<RelayKeyValue>? {
    return mapNotNull { pair ->
        val key = pair.key.trim()
        if (key.isEmpty()) null else RelayKeyValue(key, pair.value)
    }.ifEmpty { null }
}

@Composable
internal fun relayAdvancedTransportLabel(value: RelayTransport): String = stringResource(relayTransportLabelRes(value))

/** The "channel" block of the local edit-connection page: candidates come only from channels.byEngine and are selectable only when there is more than one. */
internal data class RelayEditChannelSection(val options: List<RelayTransport>, val editable: Boolean)

/** null means this is not a local-engine connection (or the engine is unknown), so the edit page keeps the transport menu. The connection type is not consulted. */
internal fun relayEditChannelSection(engineProfile: String?): RelayEditChannelSection? {
    val candidates = LocalEngineChannels.candidates(engineProfile?.takeIf(String::isNotBlank)) ?: return null
    return RelayEditChannelSection(options = candidates, editable = candidates.size > 1)
}

internal fun relayTransportLabelRes(value: RelayTransport): Int = when (value) {
    RelayTransport.Auto -> R.string.relay_transport_auto
    RelayTransport.OpenAIResponses -> R.string.relay_transport_openai_responses
    RelayTransport.OpenAIChatCompletions -> R.string.relay_transport_openai_chat_completions
    RelayTransport.LlamaCppNative -> R.string.relay_transport_llamacpp_native
    RelayTransport.AnthropicMessages -> R.string.relay_transport_anthropic_messages
    RelayTransport.GeminiGenerateContent -> R.string.relay_transport_gemini_generate_content
}

/** Menu row value (same as iOS): the automatic option shows "Auto"; the menu candidates still use the full names from [relayTransportLabelRes]. */
internal fun relayTransportMenuValueRes(value: RelayTransport): Int =
    if (value == RelayTransport.Auto) R.string.relay_profile_auto else relayTransportLabelRes(value)

/** Menu row value: the automatic option shows "Auto"; the menu candidates still use the full names from [relayAuthModeLabelRes]. */
internal fun relayAuthModeMenuValueRes(value: RelayAuthMode): Int =
    if (value == RelayAuthMode.Auto) R.string.relay_profile_auto else relayAuthModeLabelRes(value)

@Composable
internal fun relayAdvancedAuthModeLabel(value: RelayAuthMode): String = stringResource(relayAuthModeLabelRes(value))

internal fun relayAuthModeLabelRes(value: RelayAuthMode): Int = when (value) {
    RelayAuthMode.Auto -> R.string.relay_auth_auto
    RelayAuthMode.None -> R.string.relay_auth_none
    RelayAuthMode.Bearer -> R.string.relay_auth_bearer
    RelayAuthMode.XApiKey -> R.string.relay_auth_x_api_key
    RelayAuthMode.XGoogApiKey -> R.string.relay_auth_x_goog_api_key
    RelayAuthMode.QueryKey -> R.string.relay_auth_query_key
}
