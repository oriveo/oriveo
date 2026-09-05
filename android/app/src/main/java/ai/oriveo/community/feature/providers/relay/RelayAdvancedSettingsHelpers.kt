package ai.oriveo.community.feature.providers.relay

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.R
import ai.oriveo.community.core.model.RelayAuthMode
import ai.oriveo.community.core.model.RelayKeyValue
import ai.oriveo.community.core.model.RelayKind
import ai.oriveo.community.core.model.RelayReasoningEffort
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.RelayFamilyHeuristics

internal fun relayCodexIdentityEditable(relayKind: RelayKind): Boolean =
    relayKind == RelayKind.CodexStyle

internal fun relayCodexIdentityChecked(relayKind: RelayKind, requested: RelayRequestedConfig): Boolean =
    if (relayCodexIdentityEditable(relayKind)) {
        requested.codexCompatIdentity != false
    } else {
        false
    }

internal fun relayCodexIdentityForSave(relayKind: RelayKind, requested: RelayRequestedConfig): Boolean? =
    if (relayCodexIdentityEditable(relayKind)) {
        requested.codexCompatIdentity != false
    } else {
        null
    }


internal fun relayRequestedMatchesPersisted(
    relayKind: RelayKind,
    persisted: RelayRequestedConfig,
    candidate: RelayRequestedConfig,
): Boolean = persisted.copy(
    codexCompatIdentity = relayCodexIdentityForSave(relayKind, persisted),
) == candidate.copy(
    codexCompatIdentity = relayCodexIdentityForSave(relayKind, candidate),
)

internal fun suggestedRelayKind(
    currentKind: RelayKind,
    modelID: String?,
): RelayKind? {
    val family = RelayFamilyHeuristics.infer(modelID)
    val compatibleKinds = RelayFamilyHeuristics.compatibleRelayKinds(family)
    if (compatibleKinds.isEmpty() || currentKind in compatibleKinds) return null
    return RelayFamilyHeuristics.suggestedRelayKind(family)
}

internal fun List<RelayKeyValue>.cleanRelayAdvancedPairs(): List<RelayKeyValue>? {
    return mapNotNull { pair ->
        val key = pair.key.trim()
        val value = pair.value.trim()
        if (key.isEmpty()) null else RelayKeyValue(key, value)
    }.ifEmpty { null }
}

@Composable
internal fun relayAdvancedTransportLabel(value: RelayTransport): String = stringResource(
    when (value) {
        RelayTransport.Auto -> R.string.relay_transport_auto
        RelayTransport.OpenAIResponses -> R.string.relay_transport_openai_responses
        RelayTransport.OpenAIChatCompletions -> R.string.relay_transport_openai_chat_completions
        RelayTransport.LlamaCppNative -> R.string.relay_transport_llamacpp_native
        RelayTransport.AnthropicMessages -> R.string.relay_transport_anthropic_messages
        RelayTransport.GeminiGenerateContent -> R.string.relay_transport_gemini_generate_content
    },
)

@Composable
internal fun relayAdvancedAuthModeLabel(value: RelayAuthMode): String = stringResource(
    when (value) {
        RelayAuthMode.Auto -> R.string.relay_auth_auto
        RelayAuthMode.None -> R.string.relay_auth_none
        RelayAuthMode.Bearer -> R.string.relay_auth_bearer
        RelayAuthMode.XApiKey -> R.string.relay_auth_x_api_key
        RelayAuthMode.XGoogApiKey -> R.string.relay_auth_x_goog_api_key
        RelayAuthMode.QueryKey -> R.string.relay_auth_query_key
    },
)

@Composable
internal fun relayAdvancedReasoningLabel(value: RelayReasoningEffort): String = stringResource(
    when (value) {
        RelayReasoningEffort.Automatic -> R.string.relay_reasoning_automatic
        RelayReasoningEffort.Low -> R.string.relay_reasoning_low
        RelayReasoningEffort.Medium -> R.string.relay_reasoning_medium
        RelayReasoningEffort.High -> R.string.relay_reasoning_high
        RelayReasoningEffort.XHigh -> R.string.relay_reasoning_xhigh
    },
)
