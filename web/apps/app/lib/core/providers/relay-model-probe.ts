import type {
  AIModel,
  Provider,
  RelayModelTransport,
  RelayRequestedConfig,
} from '@oriveo/shared';
import { effectiveAPIRoot, effectiveTransport } from '@oriveo/core/providers/relay-effective';
import {
  extractRelayPingFailureDetails,
  pingRelay,
  type RelayPingInput,
} from './ping-relay';
import {
  probeRelayEndpoint,
  relayAttemptFailureKind,
  relayVerificationFailureKind,
  type RelayDiscoveryAttempt,
  type RelayDiscoveryInput,
  type RelayDiscoveryResult,
} from './probe/probe-runner';
import { describeRelayEndpoint, type RelayProbeTransportKind } from './probe/endpoint-normalizer';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import { relayKeySecrets } from '@oriveo/shared/relay/relay-keys';
import { isRelayRouteRejection } from './relay-probe-candidates';

/**
 * Relay per-model probing (C3 sections 3.2-3.3).
 * A model sends 1-token requests over its candidates (at most 2) in turn; one probe has only three outcomes: pass → stop; route-level rejection → next candidate;
 * anything else is "undetermined" → stop immediately and do not send the next candidate with the same key.
 * This file does not write the store: the caller writes the passing result back with `withRelayModelProbePass`.
 */

const MAX_PROBE_CANDIDATES = 2;

export type RelayModelProbeProvider = Pick<Provider, 'baseURLText' | 'relayRequested' | 'apiKey' | 'relayKind'>;

export type RelayModelProbePing = (input: RelayPingInput) => Promise<unknown>;

export interface RelayModelProbePass {
  transport: RelayModelTransport;
  /** API root hit on this pass (effectiveAPIRoot, with the model transport temporarily set to the candidate). */
  apiBaseURL: string;
}

export interface RelayModelProbeInput {
  provider: RelayModelProbeProvider;
  modelID: string;
  candidates: readonly RelayModelTransport[];
  /** Defaults to the production ping primitive `pingRelay`; throwing = this candidate did not pass. */
  ping?: RelayModelProbePing;
  /** Called back for every candidate whose request went out and failed, so the caller can record diagnostics. */
  onCandidateFailure?: (transport: RelayModelTransport, error: unknown, apiBaseURL: string) => void;
  signal?: AbortSignal;
}

export async function probeRelayModelTransport(
  input: RelayModelProbeInput,
): Promise<RelayModelProbePass | null> {
  const requested = input.provider.relayRequested;
  const modelID = input.modelID.trim();
  if (!requested || !modelID) return null;
  const ping = input.ping ?? pingRelay;
  for (const transport of input.candidates.slice(0, MAX_PROBE_CANDIDATES)) {
    throwIfAborted(input.signal);
    const apiBaseURL = effectiveAPIRoot(input.provider, { relayTransport: transport });
    if (!apiBaseURL) continue;
    try {
      await ping({
        baseURL: input.provider.baseURLText ?? '',
        apiRoot: apiBaseURL,
        apiKey: resolveProviderAPIKey(input.provider, modelID),
        modelID,
        relayRequested: requested,
        relayKind: input.provider.relayKind,
        model: { relayTransport: transport },
        connectionKeySecrets: relayKeySecrets(input.provider),
        signal: input.signal,
      });
    } catch (error) {
      throwIfAborted(input.signal);
      input.onCandidateFailure?.(transport, error, apiBaseURL);
      if (!isRelayProbeRouteRejection(error)) return null;
      continue;
    }
    throwIfAborted(input.signal);
    return { transport, apiBaseURL };
  }
  return null;
}

/**
 * Whether a failure thrown by ping counts as a route-level rejection: no HTTP status (network error) does not; the response body is the upstream's own words left on the failure object;
 * a 2xx that is a web page is decided by ping where the response headers and raw text are available, and carried out on the failure object.
 */
function isRelayProbeRouteRejection(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false;
  const value = error as { status?: unknown; detail?: unknown; message?: unknown; relayHTMLPage?: unknown };
  return isRelayRouteRejection({
    status: typeof value.status === 'number' ? value.status : undefined,
    ...(value.relayHTMLPage === true ? { contentType: 'text/html' } : {}),
    body: [value.detail, value.message].filter((part): part is string => typeof part === 'string').join('\n'),
  });
}

/**
 * Write-back rule: that model's relayTransport = candidate, source = reachable;
 * relayRequested.resolvedAPIBaseURLs[candidate] = that root, adding only this entry and leaving other keys, the connection transport and the single-value root alone.
 * All other models stay untouched; if the model is not in the enabled list, return as is.
 */
export function withRelayModelProbePass<T extends Pick<Provider, 'relayRequested' | 'models'>>(
  provider: T,
  modelID: string,
  pass: RelayModelProbePass,
): T {
  if (!provider.relayRequested || !provider.models.some((model) => model.id === modelID)) return provider;
  return {
    ...provider,
    relayRequested: {
      ...provider.relayRequested,
      resolvedAPIBaseURLs: {
        ...provider.relayRequested.resolvedAPIBaseURLs,
        [pass.transport]: pass.apiBaseURL,
      },
    },
    models: provider.models.map((model): AIModel => (
      model.id === modelID
        ? { ...model, relayTransport: pass.transport, relayTransportSource: 'reachable' }
        : model
    )),
  };
}

/**
 * When catalog entries replace enabled models, the model's own transport / source / capability overrides are local facts absent from the catalog and must be carried over from the enabled model
 * (refreshing the catalog does not touch user / observed / tested); keys the enabled model lacks are not filled with undefined.
 * Exception for engine declarations: if the catalog entry carries its own (the connector gave a new declaration this time) use the new one, otherwise keep the old.
 */
export function withRelayModelLocalFields(target: AIModel, source: AIModel): AIModel {
  const next: AIModel = { ...target };
  const engineDeclaration = target.engineDeclaration ?? source.engineDeclaration;
  delete next.relayTransport;
  delete next.relayTransportSource;
  delete next.relayCapabilityOverrides;
  delete next.engineDeclaration;
  if (engineDeclaration) next.engineDeclaration = engineDeclaration;
  if (source.relayTransport) {
    next.relayTransport = source.relayTransport;
    if (source.relayTransportSource) next.relayTransportSource = source.relayTransportSource;
  }
  if (source.relayCapabilityOverrides) next.relayCapabilityOverrides = source.relayCapabilityOverrides;
  // Multi-key: bindings and no-access markers are local facts, carried back by id; for listed ones the current catalog entry wins, and the old is kept only when it carries none.
  delete next.relayKeyID;
  delete next.relayDeniedKeyID;
  if (source.relayKeyID) next.relayKeyID = source.relayKeyID;
  if (source.relayDeniedKeyID) next.relayDeniedKeyID = source.relayDeniedKeyID;
  if (!target.relayListedByKeyIDs && source.relayListedByKeyIDs) next.relayListedByKeyIDs = source.relayListedByKeyIDs;
  return next;
}

/**
 * Catalog list refresh (C3 section 3.5): engine declarations are written only by the local connector and a generic catalog fetch cannot bring them back,
 * so keep the old declarations by model id from the enabled models / catalog before the refresh; only a new entry carrying its own declaration replaces them, and newly appearing models stay unknown.
 */
export function withPreviousEngineDeclarations(
  next: AIModel[],
  previous: { models: readonly AIModel[]; catalogModels: readonly AIModel[] },
): AIModel[] {
  const known = new Map<string, NonNullable<AIModel['engineDeclaration']>>();
  for (const model of [...previous.catalogModels, ...previous.models]) {
    if (model.engineDeclaration) known.set(model.id, model.engineDeclaration);
  }
  if (known.size === 0) return next;
  return next.map((model) => {
    const kept = known.get(model.id);
    return model.engineDeclaration || !kept ? model : { ...model, engineDeclaration: kept };
  });
}

/**
 * Write the discovered API root back to the connection (C3 R5a): only when the discovered transport = the connection's actual default (auto means Chat) write the old single-value root,
 * otherwise write into resolvedAPIBaseURLs[discovered transport]; the connection transport is not changed.
 */
export function withRelayDiscoveredRoot(
  provider: Pick<Provider, 'baseURLText' | 'relayRequested'> & { relayRequested: RelayRequestedConfig },
  transport: RelayModelTransport,
  apiBaseURL: string,
): RelayRequestedConfig {
  const requested = provider.relayRequested;
  if (transport === effectiveTransport(provider, null)) {
    return { ...requested, resolvedAPIBaseURL: apiBaseURL };
  }
  return {
    ...requested,
    resolvedAPIBaseURLs: { ...requested.resolvedAPIBaseURLs, [transport]: apiBaseURL },
  };
}

/** When the address carries a transport route (e.g. …/v1/messages), the user counts as having selected the transport. */
export function relayEndpointExplicitTransport(
  endpoint: string,
  securityMode?: RelayDiscoveryInput['securityMode'],
): RelayProbeTransportKind | undefined {
  try {
    return describeRelayEndpoint(endpoint, securityMode).explicitTransport;
  } catch {
    return undefined;
  }
}

/**
 * Add-relay step 1: catalog discovery only, zero 1-token. No model hint is passed (step 1 has no model slot),
 * and an address carrying a transport route also only pulls the catalog; if the catalog cannot be obtained, generation-route discovery runs as before (sentinel model, transport order and retries unchanged).
 */
export function discoverRelayCatalogForAdd(input: Omit<RelayDiscoveryInput, 'modelHint' | 'deferModelVerification' | 'forcedTransport'>): Promise<RelayDiscoveryResult> {
  return probeRelayEndpoint({ ...input, deferModelVerification: true });
}

export interface RelayAddVerificationInput {
  /** The connection about to be saved (with enabled models and key list): the probe root is computed from it, and the key is the one bound to that model. */
  provider: RelayModelProbeProvider & Partial<Pick<Provider, 'kind' | 'models' | 'relayKeys'>>;
  modelID: string;
  candidates: readonly RelayModelTransport[];
  ping?: RelayModelProbePing;
  signal?: AbortSignal;
}

export type RelayAddVerification =
  | { ok: true; pass: RelayModelProbePass }
  | { ok: false; result: RelayDiscoveryResult };

/**
 * Add-relay step 2 save: only for the first checked model, run the existing 1-token over the candidates.
 * No candidate passing is the same failure state as a verification failure (carrying the attempted requests and the upstream's own words), and the caller does not persist.
 */
export async function verifyRelayModelForAdd(input: RelayAddVerificationInput): Promise<RelayAddVerification> {
  const { provider, modelID } = input;
  const attempts: RelayDiscoveryAttempt[] = [];
  let lastStatus: number | undefined;
  const pass = await probeRelayModelTransport({
    provider,
    modelID,
    candidates: input.candidates,
    ping: input.ping,
    signal: input.signal,
    onCandidateFailure: (_transport, error, apiBaseURL) => {
      const details = extractRelayPingFailureDetails(error, {
        apiKey: resolveProviderAPIKey(provider, modelID),
        relayRequested: provider.relayRequested!,
        connectionKeySecrets: relayKeySecrets(provider),
      });
      lastStatus = details.statusCode;
      attempts.push({
        method: 'POST',
        requestURL: details.requestURL ?? apiBaseURL,
        statusCode: details.statusCode,
        failure: relayAttemptFailureKind(details.statusCode),
        kind: 'generation_verification',
        upstreamMessage: details.upstreamMessage,
        retryCount: 0,
      });
    },
  });
  if (pass) return { ok: true, pass };
  return {
    ok: false,
    result: {
      state: 'failed',
      attempts,
      failure: relayVerificationFailureKind(lastStatus),
      diagnostic: [...attempts].reverse().find((attempt) => attempt.upstreamMessage)?.upstreamMessage,
      retriedRequestCount: 0,
    },
  };
}

function throwIfAborted(signal: AbortSignal | undefined): void {
  signal?.throwIfAborted();
}
