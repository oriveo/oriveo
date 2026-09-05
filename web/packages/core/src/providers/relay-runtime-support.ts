/**
 * Pure runtime gating for relay: transport rule and envelope resolution.
 *
 * Rules and envelopes are read from the already-merged runtimeConfig
 * (`getRelayRuntimeConfig` merges DEFAULT_RELAY_RUNTIME_CONFIG per transport in the shell,
 * so there is no second fallback here and core stays decoupled from that constant).
 * An unresolved 'auto' transport yields null. Renderer-side attachment and supports* gating
 * stays in the app layer and uses resolveRelayEnvelope from this file. Relay send
 * orchestration uses resolveRelayTransportRule to read
 * authMode/headerProfile/webSearchToolName/imageRoute.
 */
import type { RelayAuthMode, RelayKeyValue, RelayTransport } from '@oriveo/shared/pure-types';
import {
  isSensitiveRelayName,
  type RelayConnectionSecurityMode,
} from '@oriveo/shared/relay/endpoint-policy';
import { isDedicatedImageModel } from '@oriveo/shared/relay/image-models';
import type {
  RelayRuntimeConfig,
  RelayRuntimeTransportKey,
  RelayTransportEnvelope,
  RelayTransportRule,
} from '../ports';
import type { StreamOptions } from './types';

/** A resolved relay authMode is never 'auto': buildDirectAuthHeaders/buildRelayProxyConfig both need one of the four concrete modes. */
export type ResolvedRelayAuthMode = Exclude<RelayAuthMode, 'auto'>;

/* ── Credential state: one derived predicate plus a state machine ──────────────────
 * Kept in core rather than in the feature layer: validation, edit-save and status
 * rendering must all read the same predicate. Otherwise an orange "needs a key" can render
 * next to "connected", and editing a non-credential field gets blocked by a required-key check.
 */

/**
 * Whether this connection needs a credential. This is the only predicate: branches that
 * test `apiKey === ''` directly, or read `apiKeyPreview` to decide existence, are
 * violations and are caught by `scripts/relay-credential-lint.mjs`.
 * `undefined` and `'auto'` both count as needing one, since assuming a credential is
 * required when nothing was declared is the fail-safe direction.
 */
export function relayRequiresCredential(authMode: RelayAuthMode | null | undefined): boolean {
  return (authMode ?? 'auto') !== 'none';
}

/** Whether the connection uses a plaintext (unencrypted) channel; plaintext and any credential material are mutually exclusive. */
export function isCleartextRelayConnection(
  securityMode: RelayConnectionSecurityMode | null | undefined,
): boolean {
  return securityMode === 'local_http' || securityMode === 'private_vpn';
}

/**
 * Shared predicate for whether any credential material is present. Ordinary custom
 * key/value pairs are not credentials and survive a switch to plaintext, but once any
 * sensitive pair matches, the whole header and query configuration is cleared atomically
 * as the confirmation card promises, so no related field is left behind.
 */
export function relayHasCredentialMaterial(input: {
  authMode: RelayAuthMode | null | undefined;
  hasStoredKey: boolean;
  headers?: readonly RelayKeyValue[];
  queryParams?: readonly RelayKeyValue[];
}): boolean {
  return relayRequiresCredential(input.authMode)
    || input.hasStoredKey
    || (input.headers ?? []).some((pair) => isSensitiveRelayName(pair.key))
    || (input.queryParams ?? []).some((pair) => isSensitiveRelayName(pair.key));
}

/**
 * The confirmation step has to see both the saved configuration and the unsaved draft.
 * Checking only one side lets the card promise that no credential will be deleted while
 * the transaction then finds and deletes one on the other side.
 */
export function relayHasCredentialMaterialAcross(
  inputs: readonly Parameters<typeof relayHasCredentialMaterial>[0][],
): boolean {
  return inputs.some(relayHasCredentialMaterial);
}

/** Credential values that were really sent must be masked before a failure card or diagnostics view shows them; ordinary key/value pairs are not credentials and are not caught here. */
export function relaySensitiveCredentialValues(input: {
  apiKey?: string;
  headers?: readonly RelayKeyValue[];
  queryParams?: readonly RelayKeyValue[];
}): string[] {
  return [
    input.apiKey ?? '',
    ...(input.headers ?? []).filter((pair) => isSensitiveRelayName(pair.key)).map((pair) => pair.value),
    ...(input.queryParams ?? []).filter((pair) => isSensitiveRelayName(pair.key)).map((pair) => pair.value),
  ].filter((value) => value.trim().length > 0);
}

/**
 * Whether a save action may treat the API key as a required field (form-level gate).
 *
 * - `create`: required only when `requiresCredential` holds and no credential exists yet.
 *   Otherwise adding an `auth=none` connection would be pushed to a parallel entry point
 *   with fewer capabilities.
 * - `edit`: always `false`. An empty input means leave unchanged, not clear, and editing a
 *   non-credential field must never be gated on a required key; a missing credential is
 *   reported by the S1 `missing` state, and removing one is an explicit action.
 */
export function relayCredentialInputRequired(
  mode: 'create' | 'edit',
  authMode: RelayAuthMode | null | undefined,
  hasStoredKey: boolean,
): boolean {
  if (mode === 'edit') return false;
  return relayRequiresCredential(authMode) && !hasStoredKey;
}

/**
 * Credential state. The separate "not yet verified" state is orthogonal to these four and
 * is carried by `provider.status` rather than modelled here, so that "has a key" and
 * "has been tested" do not collapse into one dimension.
 */
export type RelayCredentialState =
  /** S0: needs no credential; neutral, and the save path performs no key check */
  | 'not_required'
  /** S1: needs one but has none; warning state */
  | 'missing'
  /** S2: needs one and has it; neutral masked display */
  | 'present'
  /** S3: a plaintext connection that still carries credential material; blocking state, only reachable through existing data, a backup restore or sync */
  | 'conflict';

export interface RelayCredentialStateInput {
  /** Effective authMode of the connection: resolved first, else the value the user requested */
  authMode: RelayAuthMode | null | undefined;
  /** The key store really holds a non-empty key; not the same as a non-empty apiKeyPreview */
  hasStoredKey: boolean;
  securityMode?: RelayConnectionSecurityMode | null;
  /** Sensitive header and query parameters are credential material too, and conflict with plaintext just the same */
  hasSensitiveTransportCredentials?: boolean;
}

export function resolveRelayCredentialState(
  input: RelayCredentialStateInput,
): RelayCredentialState {
  const requiresCredential = relayRequiresCredential(input.authMode);
  if (isCleartextRelayConnection(input.securityMode)
    && (requiresCredential || input.hasStoredKey || input.hasSensitiveTransportCredentials === true)) {
    return 'conflict';
  }
  if (!requiresCredential) return 'not_required';
  return input.hasStoredKey ? 'present' : 'missing';
}

function isRuntimeTransport(transport: RelayTransport): transport is RelayRuntimeTransportKey {
  return transport !== 'auto' && transport !== 'llamacpp_native';
}

export function resolveRelayEnvelope(
  transport: RelayTransport | null | undefined,
  runtimeConfig: RelayRuntimeConfig,
): RelayTransportEnvelope | null {
  if (!transport || !isRuntimeTransport(transport)) return null;
  return runtimeConfig.transportEnvelopes[transport] ?? null;
}

export function resolveRelayTransportRule(
  transport: RelayTransport | null | undefined,
  runtimeConfig: RelayRuntimeConfig,
): RelayTransportRule | null {
  if (!transport || !isRuntimeTransport(transport)) return null;
  return runtimeConfig.transportRules[transport] ?? null;
}

export function transportProviderPriority(
  transport: RelayTransport | null | undefined,
  runtimeConfig: RelayRuntimeConfig,
): string | null {
  return resolveRelayTransportRule(transport, runtimeConfig)?.providerPriority ?? null;
}

/**
 * Resolve the authMode for a relay request: an explicit user choice wins, then the
 * transport rule's defaultAuthMode, then a transport heuristic.
 * The result is always non-auto, as buildDirectAuthHeaders/buildRelayProxyConfig require.
 * runtimeConfig is injected by the caller.
 */
export function resolveRelayAuthMode(
  options: StreamOptions | undefined,
  transport: RelayTransport,
  runtimeConfig: RelayRuntimeConfig | null,
): ResolvedRelayAuthMode {
  if (options?.relayAuthMode) return options.relayAuthMode;
  const rule = runtimeConfig ? resolveRelayTransportRule(transport, runtimeConfig) : null;
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
    default:
      return 'bearer';
  }
}

/* ── Image generation routing ──────────────────────
 * Locked case by case by the relay routing fixture tests so it cannot drift.
 */

export type RelayImageRoute = RelayTransportRule['imageRoute'];

/** For every routing decision `auto` behaves exactly like `openai_chat_completions`, matching the envelope rules. */
function routingTransportKey(transport: RelayTransport): RelayRuntimeTransportKey {
  return transport === 'auto' || transport === 'llamacpp_native'
    ? 'openai_chat_completions'
    : transport;
}

/**
 * Map a transport to an image generation route.
 *
 * A backend transport rule wins when present, so routing can be corrected remotely;
 * otherwise the static mapping applies. There is no runtime probe, which would burn keys
 * and multiply error paths.
 */
export function relayImageRoute(
  transport: RelayTransport,
  runtimeConfig: RelayRuntimeConfig | null,
): RelayImageRoute {
  const key = routingTransportKey(transport);
  const rule = runtimeConfig ? resolveRelayTransportRule(key, runtimeConfig) : null;
  if (rule?.imageRoute) return rule.imageRoute;
  switch (key) {
    case 'openai_responses':
      return 'inline_responses_tool';
    case 'gemini_generate_content':
      return 'gemini_modality';
    case 'anthropic_messages':
      return 'unsupported';
    case 'openai_chat_completions':
    default:
      return 'images_endpoint';
  }
}

/**
 * Whether `stream = true` has to be forced.
 *
 * Only the imageGen plus Responses inline tool combination forces it; everything else
 * respects the user setting. Non-streaming `/responses` image output was observed to be
 * truncated on ylsagi and packy.
 */
export function shouldForceRelayStream(
  transport: RelayTransport,
  capabilities: readonly string[],
  runtimeConfig: RelayRuntimeConfig | null,
): boolean {
  if (!capabilities.includes('imageGeneration')) return false;
  const rule = runtimeConfig
    ? resolveRelayTransportRule(routingTransportKey(transport), runtimeConfig)
    : null;
  if (rule) return rule.forceStreamForImageGeneration;
  return relayImageRoute(transport, runtimeConfig) === 'inline_responses_tool';
}

/** Minimal model shape for pickChatDriverModelID, decoupled from Provider/AIModel so core can reuse it and fixtures can feed it directly. */
export interface ChatDriverCandidate {
  id: string;
  capabilities: readonly string[];
  /** Omitted means available */
  isAvailable?: boolean;
  isDefault?: boolean;
}

export type PickChatDriverResult =
  | { ok: true; modelID: string }
  | { ok: false; reason: 'missingChatDriverModel' };

/**
 * Pick the upstream primary model ID for Responses inline image generation.
 *
 * A dedicated image model such as `gpt-image-*` is not a chat model: putting it in
 * body.model makes the upstream either ignore it or let the name pollute the context, so
 * the model draws an image every turn, including for plain technical questions, at a
 * measured cost of an extra 47 seconds.
 *
 * Rule: if the current model is not a dedicated image model, use it. Otherwise prefer
 * defaultModel, then the first model that is available, is not a dedicated image model and
 * has no imageGeneration capability. If none qualifies, return missingChatDriverModel and
 * let the caller map it to a friendly error.
 */
export function pickChatDriverModelID(input: {
  currentModelID: string;
  models: readonly ChatDriverCandidate[];
  defaultModelID?: string | null;
}): PickChatDriverResult {
  if (!isDedicatedImageModel(input.currentModelID)) {
    return { ok: true, modelID: input.currentModelID };
  }
  const acceptable = (model: ChatDriverCandidate): boolean =>
    model.isAvailable !== false
    && !isDedicatedImageModel(model.id)
    && !model.capabilities.includes('imageGeneration');

  const preferred = input.defaultModelID
    ? input.models.find((model) => model.id === input.defaultModelID)
    : input.models.find((model) => model.isDefault);
  if (preferred && acceptable(preferred)) return { ok: true, modelID: preferred.id };

  const fallback = input.models.find(acceptable);
  if (fallback) return { ok: true, modelID: fallback.id };
  return { ok: false, reason: 'missingChatDriverModel' };
}
