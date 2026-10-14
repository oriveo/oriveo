/**
 * Relay runtime gating helpers.
 *
 * The pure rule/envelope parsing lives in @oriveo/core/providers/relay-runtime-support (shared by web
 * and the desktop main process, and the relay send* orchestration reuses resolveRelayTransportRule).
 * This file keeps the renderer-only attachment / supports* UI gates, which intersect with the model
 * capabilities, and re-exports the core rule helpers so existing importers need no change.
 */
import type { AIModel, Provider, RelayAuthMode } from '@oriveo/shared';
import { decidedTransport } from '@oriveo/core/providers/relay-effective';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import type { ProviderAttachmentSupport, RelayRuntimeConfig } from '../metadata/metadata-client';
import {
  isCleartextRelayConnection,
  relayHasCredentialMaterial,
  relayRequiresCredential,
  resolveRelayAuthMode,
  resolveRelayCredentialState,
  resolveRelayEnvelope,
  resolveRelayTransportRule,
  transportProviderPriority,
  type RelayCredentialState,
} from '@oriveo/core/providers/relay-runtime-support';

export {
  isCleartextRelayConnection,
  relayHasCredentialMaterial,
  relayRequiresCredential,
  resolveRelayAuthMode,
  resolveRelayCredentialState,
  resolveRelayTransportRule,
  transportProviderPriority,
};
export type { RelayCredentialState };

/** Effective authMode of a connection: the measured resolved value wins because that is what actually goes out, otherwise the requested value the user configured. */
export function relayProviderAuthMode(provider: Provider): RelayAuthMode | undefined {
  return provider.relayResolvedAuthMode ?? provider.relayRequested?.authMode;
}

/** Whether this relay connection needs credentials. This is the only rule; do not bypass it by checking apiKey/apiKeyPreview for emptiness. */
export function relayProviderRequiresCredential(provider: Provider): boolean {
  return relayRequiresCredential(relayProviderAuthMode(provider));
}

export function relayProviderHasCredentialMaterial(provider: Provider): boolean {
  return relayHasCredentialMaterial({
    authMode: relayProviderAuthMode(provider),
    hasStoredKey: (resolveProviderAPIKey(provider) ?? '').trim().length > 0,
    headers: provider.relayRequested?.headers,
    queryParams: provider.relayRequested?.queryParams,
  });
}

/**
 * Credential state S0-S3 of a relay connection.
 * The S3 verdict for sensitive headers and query parameters is not wired in yet: the unified list of
 * sensitive names belongs with the outbound sanitizer, and starting a second list here would only
 * create two implementations that drift, so this deliberately under-reports instead.
 */
export function relayProviderCredentialState(provider: Provider): RelayCredentialState {
  return resolveRelayCredentialState({
    authMode: relayProviderAuthMode(provider),
    hasStoredKey: (resolveProviderAPIKey(provider) ?? '').trim().length > 0,
    securityMode: provider.relayRequested?.securityMode,
    hasSensitiveTransportCredentials: relayHasCredentialMaterial({
      authMode: 'none',
      hasStoredKey: false,
      headers: provider.relayRequested?.headers,
      queryParams: provider.relayRequested?.queryParams,
    }),
  });
}

/**
 * attachmentSupport for a relay, derived from the transport envelope of the model's own protocol alone; the model
 * capabilities are intersected one layer up. The protocol is Relay 2.0 `decidedTransport` (the model's own, or the connection default when not auto);
 * non-relay or an undecided protocol returns null and the composer stays disabled (fail-closed).
 */
export function resolveRelayAttachmentSupport(
  provider: Provider,
  runtimeConfig: RelayRuntimeConfig,
  model?: Pick<AIModel, 'relayTransport'> | null,
): ProviderAttachmentSupport | null {
  if (provider.kind !== 'relay') return null;
  const envelope = resolveRelayEnvelope(decidedTransport(provider, model), runtimeConfig);
  if (!envelope) return null;
  return {
    image: envelope.image,
    nativeFile: envelope.nativeFile,
    textFileInline: envelope.textFileInline,
  };
}

/** Whether the relay's current transport supports the web search tool (decided by the backend envelope; intersected with the model capabilities one layer up). */
export function transportSupportsWebSearch(
  provider: Provider,
  runtimeConfig: RelayRuntimeConfig,
  model?: Pick<AIModel, 'relayTransport'> | null,
): boolean {
  if (provider.kind !== 'relay') return false;
  return resolveRelayEnvelope(decidedTransport(provider, model), runtimeConfig)?.webSearch ?? false;
}

/** Whether the relay's current transport supports the image generation tool (decided by the backend envelope). */
export function transportSupportsImageGeneration(
  provider: Provider,
  runtimeConfig: RelayRuntimeConfig,
  model?: Pick<AIModel, 'relayTransport'> | null,
): boolean {
  if (provider.kind !== 'relay') return false;
  return resolveRelayEnvelope(decidedTransport(provider, model), runtimeConfig)?.imageGeneration ?? false;
}

/** Whether the relay's current transport supports reasoning parameters (decided by the backend envelope). */
export function transportSupportsReasoning(
  provider: Provider,
  runtimeConfig: RelayRuntimeConfig,
  model?: Pick<AIModel, 'relayTransport'> | null,
): boolean {
  if (provider.kind !== 'relay') return false;
  return resolveRelayEnvelope(decidedTransport(provider, model), runtimeConfig)?.reasoning ?? false;
}
