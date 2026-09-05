import type { Provider, RelayAuthMode, RelayRequestedConfig, RelayTransport } from '@oriveo/shared';
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
