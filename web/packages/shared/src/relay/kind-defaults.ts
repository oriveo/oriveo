import type {
  RelayKind,
  RelayRequestedConfig,
} from '../types/relay';
import { carryLegacyWebSearchFields } from './legacy-web-search';

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
    // Carry the legacy connection-level web search declaration (including the tool name) over as is;
    // only saving from the web search settings page clears the two declaration fields.
    ...carryLegacyWebSearchFields(preserve),
    transportKind: preserve?.transportKind,
    // A local connection (one with engineProfile) keeps its three engine fields when the kind changes;
    // connections without engineProfile behave as before.
    ...(preserve?.engineProfile ? {
      engineProfile: preserve.engineProfile,
      securityMode: preserve.securityMode,
      certificateFingerprint: preserve.certificateFingerprint,
    } : {}),
  };
}

const LOCAL_ENGINE_CHANNELS: Readonly<Record<NonNullable<RelayRequestedConfig['engineProfile']>, readonly RelayRequestedConfig['transport'][]>> = {
  llamacpp: ['openai_chat_completions', 'llamacpp_native'],
  ollama: ['openai_chat_completions'],
  lmstudio: ['openai_chat_completions'],
  vllm: ['openai_chat_completions'],
  openwebui: ['openai_chat_completions'],
};

/** Channel candidates for the local connection edit page; no selector is shown when there is only one. */
export function localEngineChannelCandidates(
  engineProfile: RelayRequestedConfig['engineProfile'],
): { transports: RelayRequestedConfig['transport'][]; showsSelector: boolean } {
  const transports = engineProfile ? [...(LOCAL_ENGINE_CHANNELS[engineProfile] ?? [])] : [];
  return { transports, showsSelector: transports.length > 1 };
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
      return 'openai_compatible';
    // With the connection protocol set to auto, only the fully custom kind can show "Auto" in the protocol picker.
    case 'auto':
      return 'custom';
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

/**
 * Fallback for stored records whose connection default protocol is `auto` (local read only, never
 * written back): an older version had already saved the probed concrete protocol in
 * `relayResolvedTransport`. The resolver only reads `relayRequested.transport`, so this treats the
 * connection default as that protocol in memory, keeping such a connection on the same protocol
 * before and after the change.
 */
export function adoptLegacyResolvedRelayTransport<
  T extends { relayRequested?: RelayRequestedConfig | null; relayResolvedTransport?: string | null },
>(provider: T): T {
  const requested = provider.relayRequested;
  const resolved = provider.relayResolvedTransport;
  if (!requested || requested.transport !== 'auto' || !resolved) return provider;
  return {
    ...provider,
    relayRequested: { ...requested, transport: resolved as RelayRequestedConfig['transport'] },
  };
}
