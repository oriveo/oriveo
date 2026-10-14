import type { AIModel, Provider, RelayModelTransport } from '@oriveo/shared/pure-types';
import { normalizeRelayBaseURL } from './relay-endpoints';

/**
 * The single resolver for Relay 2.0 (pure computation: no I/O, no write-back; shared by Web + desktop main, same name on all three platforms).
 * Contract fixture: `resolveCases` of `shared/test-fixtures/relay/portable-config.v1.json`.
 * On production paths the protocol and root address are obtained only through here, no longer reading the provider-level `relayResolvedTransport`.
 */

type RelayResolveProvider = Pick<Provider, 'baseURLText' | 'relayRequested'>;
type RelayResolveModel = Pick<AIModel, 'relayTransport'> | null | undefined;

const DEFAULT_RELAY_TRANSPORT: RelayModelTransport = 'openai_chat_completions';

/** The model's own protocol takes priority, otherwise follow the connection default; `auto` / no config falls to Chat Completions. */
export function effectiveTransport(
  provider: RelayResolveProvider,
  model: RelayResolveModel,
): RelayModelTransport {
  return concreteTransport(model?.relayTransport) ?? connectionDefaultTransport(provider);
}

/**
 * The API root this model actually calls: protocol address table -> legacy single root (representing only the connection default protocol) ->
 * connection address with a version added per protocol (Gemini `v1beta`, `llamacpp_native` none, others `v1`; an existing version segment is used as is).
 * Returns undefined when the connection address fails the endpoint security policy, without throwing; the party sending the request validates again itself.
 */
export function effectiveAPIRoot(
  provider: RelayResolveProvider,
  model: RelayResolveModel,
): string | undefined {
  const transport = effectiveTransport(provider, model);
  const requested = provider.relayRequested;

  const perTransport = exactRoot(requested?.resolvedAPIBaseURLs?.[transport]);
  if (perTransport) return perTransport;

  if (transport === connectionDefaultTransport(provider)) {
    const legacy = exactRoot(requested?.resolvedAPIBaseURL);
    if (legacy) return legacy;
  }

  try {
    return normalizeRelayBaseURL(provider.baseURLText, transport, requested?.securityMode);
  } catch {
    return undefined;
  }
}

/**
 * Connection-level verified root address (same lookup as `effectiveAPIRoot` without a model, but does not fall back to the connection address with a version added):
 * the connection protocol's protocol address table -> legacy single root. Returns undefined when there is no probe result, and the caller picks a root from address candidates.
 */
export function verifiedConnectionAPIRoot(provider: RelayResolveProvider): string | undefined {
  const requested = provider.relayRequested;
  return exactRoot(requested?.resolvedAPIBaseURLs?.[connectionDefaultTransport(provider)])
    ?? exactRoot(requested?.resolvedAPIBaseURL);
}

/** Connection default protocol (`auto` / missing falls to Chat Completions). */
export function connectionTransport(provider: RelayResolveProvider): RelayModelTransport {
  return connectionDefaultTransport(provider);
}

/**
 * A protocol with an explicit source: the model set its own, or the connection default is not `auto`. Returns
 * undefined when the connection default is `auto` / missing: dispatch still lands on Chat via `effectiveTransport`, but the UI presents it as "protocol undecided".
 */
export function decidedTransport(
  provider: RelayResolveProvider,
  model: RelayResolveModel,
): RelayModelTransport | undefined {
  return concreteTransport(model?.relayTransport) ?? concreteTransport(provider.relayRequested?.transport);
}

function connectionDefaultTransport(provider: RelayResolveProvider): RelayModelTransport {
  return concreteTransport(provider.relayRequested?.transport) ?? DEFAULT_RELAY_TRANSPORT;
}

function concreteTransport(value: string | null | undefined): RelayModelTransport | undefined {
  return value && value !== 'auto' ? (value as RelayModelTransport) : undefined;
}

/** An already-resolved root is used as is, only trimming leading/trailing whitespace and a trailing slash; blank counts as none. */
function exactRoot(value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim().replace(/\/+$/, '');
  return trimmed || undefined;
}
