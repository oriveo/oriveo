import type {
  RelayKind,
  RelayRequestedConfig,
} from '../types/relay';

function preserveCommon(
  requested: RelayRequestedConfig,
  preserve?: RelayRequestedConfig,
): RelayRequestedConfig {
  return {
    ...requested,
    modelID: preserve?.modelID,
    resolvedAPIBaseURL: preserve?.resolvedAPIBaseURL,
    headers: preserve?.headers,
    queryParams: preserve?.queryParams,
    customUserAgent: preserve?.customUserAgent,
    imageSize: preserve?.imageSize,
    imageQuality: preserve?.imageQuality,
    imageStyle: preserve?.imageStyle,
    imageCount: preserve?.imageCount,
    imageResponseFormat: preserve?.imageResponseFormat,
    webSearchToolName: preserve?.webSearchToolName,
    hasWebSearch: preserve?.hasWebSearch,
    webSearchProfile: preserve?.webSearchProfile,
    transportKind: preserve?.transportKind,
  };
}

export function makeRelayRequested(
  kind: RelayKind,
  preserving?: RelayRequestedConfig,
): RelayRequestedConfig {
  switch (kind) {
    case 'openai_compatible':
      return preserveCommon({
        transport: 'openai_chat_completions',
        authMode: 'bearer',
        reasoningEffort: preserving?.reasoningEffort ?? 'automatic',
        serviceTier: preserving?.serviceTier,
        stream: true,
      }, preserving);
    case 'codex_style':
      return preserveCommon({
        transport: 'openai_responses',
        authMode: 'bearer',
        reasoningEffort: preserving?.reasoningEffort ?? 'automatic',
        serviceTier: preserving?.serviceTier,
        stream: true,
        disableResponseStorage: true,
        codexCompatIdentity: true,
      }, preserving);
    case 'anthropic_compatible':
      return preserveCommon({
        transport: 'anthropic_messages',
        authMode: 'x_api_key',
        stream: true,
      }, preserving);
    case 'gemini_compatible':
      return preserveCommon({
        transport: 'gemini_generate_content',
        authMode: 'x_goog_api_key',
        stream: true,
      }, preserving);
    case 'custom':
      return preserveCommon({
        transport: preserving?.transport ?? 'openai_chat_completions',
        authMode: preserving?.authMode ?? 'bearer',
        reasoningEffort: preserving?.reasoningEffort ?? 'automatic',
        serviceTier: preserving?.serviceTier,
        stream: preserving?.stream ?? true,
        disableResponseStorage: preserving?.disableResponseStorage,
        codexCompatIdentity: preserving?.codexCompatIdentity,
      }, preserving);
  }
}

/**
 * Recovers the relay kind from a stored `RelayRequestedConfig`.
 *
 * The requested transport is the only input: a relay's endpoint is a user-supplied host that can
 * serve any protocol at any path, so the URL is never allowed to override what the configuration
 * already states.
 */
export function inferRelayKind(
  requested: RelayRequestedConfig | null | undefined,
): RelayKind {
  if (!requested) return 'custom';
  switch (requested.transport) {
    case 'openai_chat_completions':
    case 'auto':
      return 'openai_compatible';
    case 'openai_responses':
      return 'codex_style';
    case 'anthropic_messages':
      return 'anthropic_compatible';
    case 'gemini_generate_content':
      return 'gemini_compatible';
    case 'llamacpp_native':
      return 'custom';
  }
}
