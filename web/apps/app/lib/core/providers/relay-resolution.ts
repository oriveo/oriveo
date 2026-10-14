import type { AIModel, Provider, RelayAuthMode, RelayModelTransport, RelayRequestedConfig, RelayTransport } from '@oriveo/shared';
import { effectiveAPIRoot, effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { getRelayRuntimeConfig } from '../metadata/metadata-client';
import { resolveRelayTransportRule } from './relay-runtime-support';

export interface RelayRuntimeResolution {
  normalizedBaseURL: string;
  transport: NonNullable<Provider['relayResolvedTransport']>;
  authMode: NonNullable<Provider['relayResolvedAuthMode']>;
  headerProfile: NonNullable<Provider['relayResolvedHeaderProfile']>;
  familyHint: NonNullable<Provider['relayResolvedFamilyHint']>;
  capabilityBitmap: NonNullable<Provider['relayCapabilityBitmap']>;
  probeVersion?: number;
  lastProbeAt?: string;
  lastProbeErrorClass?: Provider['relayLastProbeErrorClass'];
  fingerprintKey: string;
}

export function inferRelayHeaderProfile(
  transport: Provider['relayResolvedTransport'],
  authMode: Provider['relayResolvedAuthMode'],
): NonNullable<Provider['relayResolvedHeaderProfile']> {
  const rule = resolveRelayTransportRule(transport, getRelayRuntimeConfig());
  if (rule?.headerProfile && rule.headerProfile !== 'codex_responses') {
    return rule.headerProfile;
  }
  if (transport === 'anthropic_messages') {
    return 'anthropic_v2023_06_01';
  }
  if (
    transport === 'gemini_generate_content' &&
    authMode === 'x_goog_api_key'
  ) {
    return 'gemini_key';
  }
  return 'none';
}

export function resolveRelayRuntimeFields(input: {
  baseURLText?: string | null;
  relayRequested?: RelayRequestedConfig | null;
}): Pick<Provider,
  | 'relayResolvedBaseURLText'
  | 'relayResolvedTransport'
  | 'relayResolvedAuthMode'
  | 'relayResolvedHeaderProfile'
  | 'relayResolvedFamilyHint'
  | 'relayCapabilityBitmap'
> {
  const transport = toResolvedRelayTransport(input.relayRequested?.transport ?? 'auto');
  const authMode = toResolvedRelayAuthMode(input.relayRequested?.authMode ?? 'auto', transport);
  return {
    relayResolvedBaseURLText: normalizeRelayBaseURLText(
      input.relayRequested?.resolvedAPIBaseURL ?? input.baseURLText,
    ),
    relayResolvedTransport: transport,
    relayResolvedAuthMode: authMode,
    relayResolvedHeaderProfile: inferRelayHeaderProfile(transport, authMode),
    relayResolvedFamilyHint: relayFamilyHintForTransport(transport),
    relayCapabilityBitmap: buildRelayCapabilityBitmap(transport),
  };
}

/** The Relay runtime a model actually uses for this request: transport and root address are taken only through the Relay 2.0 resolver functions. */
export interface RelayModelRuntime {
  transport: RelayModelTransport;
  /** Empty when it cannot be resolved (the address fails the security mode); the party sending the request re-validates the original address and reports the error. */
  apiRoot?: string;
  authMode: NonNullable<Provider['relayResolvedAuthMode']>;
  headerProfile: NonNullable<Provider['relayResolvedHeaderProfile']>;
  familyHint: NonNullable<Provider['relayResolvedFamilyHint']>;
}

/**
 * Resolve transport, root address and auth by (provider, model). When the model follows the connection default transport, reuse the auth /
 * header profile persisted by connection probing (existing requests stay byte-for-byte unchanged); when the model sets another transport itself, these are re-derived for that transport.
 */
export function resolveRelayModelRuntime(
  provider: Provider,
  model?: Pick<AIModel, 'relayTransport'> | null,
): RelayModelRuntime {
  const transport = effectiveTransport(provider, model);
  const followsConnection = transport === effectiveTransport(provider, null);
  const derivedAuthMode = toResolvedRelayAuthMode(provider.relayRequested?.authMode ?? 'auto', transport);
  const authMode = followsConnection
    ? provider.relayResolvedAuthMode ?? derivedAuthMode
    : derivedAuthMode;
  const headerProfile = (followsConnection ? provider.relayResolvedHeaderProfile : undefined)
    ?? inferRelayHeaderProfile(transport, authMode);
  const familyHint = (followsConnection ? provider.relayResolvedFamilyHint : undefined)
    ?? relayFamilyHintForTransport(transport);
  const apiRoot = effectiveAPIRoot(provider, model);
  return { transport, ...(apiRoot ? { apiRoot } : {}), authMode, headerProfile, familyHint };
}

/**
 * Connection-level input of the generation-parameter partition fingerprint, byte-for-byte the same as before U5 (endpoint = probed root address ?? connection address,
 * transport = relayResolvedTransport ?? connection default as is, may be auto). Only for existing models without a model-level transport,
 * so that stored generation parameters can still be read after changes; it does not take part in dispatch.
 */
export function legacyRelayFingerprintInputs(provider: Provider): { endpoint: string; transport: string } {
  return {
    endpoint: provider.relayRequested?.resolvedAPIBaseURL ?? provider.baseURLText ?? '',
    transport: provider.relayResolvedTransport ?? provider.relayRequested?.transport ?? '',
  };
}

export function toResolvedRelayTransport(
  transport: RelayTransport,
): NonNullable<Provider['relayResolvedTransport']> {
  if (transport === 'auto') return 'openai_chat_completions';
  return transport;
}

export function toResolvedRelayAuthMode(
  authMode: RelayAuthMode,
  transport: NonNullable<Provider['relayResolvedTransport']> = 'openai_chat_completions',
): NonNullable<Provider['relayResolvedAuthMode']> {
  if (authMode !== 'auto') return authMode;
  const rule = resolveRelayTransportRule(transport, getRelayRuntimeConfig());
  if (rule?.defaultAuthMode) return rule.defaultAuthMode;
  switch (transport) {
    case 'anthropic_messages':
      return 'x_api_key';
    case 'gemini_generate_content':
      return 'x_goog_api_key';
    case 'llamacpp_native':
      return 'none';
    case 'openai_chat_completions':
    case 'openai_responses':
      return 'bearer';
  }
}

export function relayFamilyHintForTransport(
  transport: NonNullable<Provider['relayResolvedTransport']>,
): NonNullable<Provider['relayResolvedFamilyHint']> {
  switch (transport) {
    case 'anthropic_messages':
      return 'anthropic';
    case 'gemini_generate_content':
      return 'gemini';
    case 'llamacpp_native':
      return 'unknown';
    case 'openai_chat_completions':
    case 'openai_responses':
      return 'openai';
  }
}

export function buildRelayCapabilityBitmap(
  transport: NonNullable<Provider['relayResolvedTransport']>,
  options: { catalogEvidenceSucceeded?: boolean } = {},
): NonNullable<Provider['relayCapabilityBitmap']> {
  return {
    modelsList: options.catalogEvidenceSucceeded ?? false,
    responses: transport === 'openai_responses',
    chatCompletions: transport === 'openai_chat_completions',
    messages: transport === 'anthropic_messages',
    geminiGenerateContent: transport === 'gemini_generate_content',
  };
}

function normalizeRelayBaseURLText(value: string | null | undefined): string | undefined {
  const trimmed = value?.trim().replace(/\/+$/, '');
  return trimmed || undefined;
}

export function buildRelayFingerprintKey(input: {
  preflightHit?: string;
  transport: Provider['relayResolvedTransport'];
  authMode: Provider['relayResolvedAuthMode'];
  normalizedBaseURL: string;
}): string {
  return input.preflightHit
    ?? `${input.transport}:${input.authMode}:${input.normalizedBaseURL}`;
}
