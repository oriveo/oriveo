import type { AIModel, Provider, RelayModelTransport } from '@oriveo/shared';
import { fetchRelayAddKeyCatalogs } from '../../../../lib/core/providers/provider-sync';
import {
  relayAttemptFailureKind,
  type RelayDiscoveryFailureKind,
  type RelayDiscoveryResult,
} from '../../../../lib/core/providers/probe/probe-runner';
import {
  discoverRelayCatalogForAdd,
  probeRelayModelTransport,
  relayEndpointExplicitTransport,
  verifyRelayModelForAdd,
  withRelayModelProbePass,
  type RelayModelProbePing,
} from '../../../../lib/core/providers/relay-model-probe';
import {
  relayGenerationRouteCandidates,
  resolveRelayProbeCandidates,
} from '../../../../lib/core/providers/relay-probe-candidates';
import {
  RELAY_SECURITY_MODE,
  relayAddBaseProvider,
  relayBoundSelection,
  relayStepTwoEnabledSelection,
  relayKeyCatalogFailureKey,
  relayKeyDisplayLabel,
  relayQuickFormRequested,
  relayStepOneAfterCatalog,
  relayStepOneAfterDiscovery,
  relayStepOneAfterProtocols,
  startRelayStepOne,
  withRelayKeyDrafts,
  type RelayKeyCatalogRow,
  type RelayKeyDraft,
  type RelayStepOneDetection,
} from './relay-setup-two-step';

/**
 * Async orchestration of the two-step relay add: step 1 = discovery + per-key catalog + local protocol ranking, zero 1-token requests;
 * step 2 save = send a single 1-token request for the first checked model only. Cancellation and invalidation are handled by the caller's connection coordinator (AbortController + generation).
 */

export interface RelayStepOneRunInput {
  providerID: string;
  endpoint: string;
  keys: readonly RelayKeyDraft[];
  providers: readonly Provider[];
  signal: AbortSignal;
  /** Called once per advanced item; the caller decides by generation whether to display it. */
  onUpdate: (detection: RelayStepOneDetection) => void;
  /** When discovery throws (not a cancellation) it is converted to a unified failure state (with redacted diagnostics). */
  failureFor: (error: unknown) => RelayDiscoveryResult;
  now?: () => number;
}

export async function runRelayStepOne(input: RelayStepOneRunInput): Promise<RelayDiscoveryResult> {
  const now = input.now ?? Date.now;
  const [primary] = input.keys;
  const primaryKey = primary!.apiKey.trim(); // key-choke: not-provider
  const primaryLabel = relayKeyDisplayLabel(input.keys.length >= 2 ? primary!.name : '', primaryKey);
  let detection = startRelayStepOne(now());
  input.onUpdate(detection);

  const explicit = relayEndpointExplicitTransport(input.endpoint, RELAY_SECURITY_MODE);
  const form = relayQuickFormRequested();
  let discovery: RelayDiscoveryResult;
  try {
    discovery = await discoverRelayCatalogForAdd({
      endpoint: input.endpoint,
      apiKey: primaryKey,
      securityMode: RELAY_SECURITY_MODE,
      // The auth of an auto connection follows the protocol; when the address carries its own protocol route, follow the form.
      authMode: explicit && form.authMode !== 'auto' ? form.authMode : undefined,
      headers: form.headers,
      queryParams: form.queryParams,
      signal: input.signal,
    });
  } catch (error) {
    if (input.signal.aborted) throw error;
    discovery = input.failureFor(error);
  }
  input.signal.throwIfAborted();
  detection = relayStepOneAfterDiscovery(detection, discovery, primaryLabel, now());
  input.onUpdate(detection);
  if (detection.checks.catalog.state !== 'running') return discovery;

  const found = discovery.detection;
  if (input.keys.length < 2) {
    const listed = found?.catalogEvidenceSucceeded ? found.catalogModels : [];
    detection = relayStepOneAfterCatalog(detection, {
      catalogModels: listed.map((model) => ({ ...model, isDefault: false })),
      endpointTypes: found?.catalogEndpointTypes ?? {},
      keyRows: detection.keyRows,
    }, now());
  } else {
    // Every other key goes through catalogAPIRoot + /models, assembled by the same merge function as the primary key's refresh.
    const keyed = withRelayKeyDrafts(relayAddBaseProvider({
      id: input.providerID,
      endpoint: input.endpoint,
      apiKey: primaryKey,
      detection: found,
      providers: input.providers,
      now: new Date(now()).toISOString(),
    }), input.keys);
    const primaryStatus = [...discovery.attempts].reverse().find((attempt) => attempt.statusCode !== undefined)?.statusCode ?? null;
    const catalogs = await fetchRelayAddKeyCatalogs(keyed, found?.catalogEvidenceSucceeded
      ? { ok: true, modelIDs: found.modelIDs, endpointTypes: found.catalogEndpointTypes }
      : { ok: false, status: primaryStatus });
    input.signal.throwIfAborted();
    const keyRows: RelayKeyCatalogRow[] = input.keys.map((key, index) => {
      const result = catalogs.perKey.find((item) => item.keyID === key.id);
      const label = relayKeyDisplayLabel(key.name, key.apiKey); // key-choke: not-provider
      if (index === 0) return { ...detection.keyRows[0]!, label };
      if (!result) return { keyID: key.id, label };
      if (!result.ok) return { keyID: key.id, label, failureKey: relayKeyCatalogFailureKey(result.status) };
      return result.modelIDs.length > 0
        ? { keyID: key.id, label, count: result.modelIDs.length }
        : { keyID: key.id, label, failureKey: 'twoStep.modelsEmpty' };
    });
    detection = relayStepOneAfterCatalog(detection, {
      catalogModels: catalogs.catalogModels.map((model) => ({ ...model, isDefault: false })),
      relayKeys: catalogs.relayKeys,
      endpointTypes: catalogs.endpointTypes,
      keyRows,
    }, now());
  }
  input.onUpdate(detection);
  if (detection.checks.protocols.state !== 'running') return discovery;

  // Protocol recognition is computed locally (the candidate function reads only the cache, zero requests): the chip is computed in step 2 from endpointTypes.
  detection = relayStepOneAfterProtocols(detection, now());
  input.onUpdate(detection);
  return discovery;
}

export interface RelayTwoStepSaveInput {
  providerID: string;
  endpoint: string;
  keys: readonly RelayKeyDraft[];
  detection: RelayStepOneDetection | null;
  /** Step 2 catalog (including manual additions). */
  catalogModels: AIModel[];
  /** Selected models, in display order. */
  selected: AIModel[];
  providers: readonly Provider[];
  signal?: AbortSignal;
  ping?: RelayModelProbePing;
  lookupFamily?: (modelID: string) => Promise<string | undefined>;
}

export type RelayTwoStepSaveResult =
  | { ok: true; provider: Provider; firstModelID: string }
  | { ok: false; result: RelayDiscoveryResult };

/**
 * Save: the first checked model = the first in display order; the key it is bound to goes through the existing 1-token (candidate protocols; when the address carries its own protocol route
 * only that one is used and no value is written to the model). A failure is not persisted; success = primary-key connection + remaining keys via RK-2 + merged catalog + all checked models enabled (section 4 binding)
 * + the first model gets the probe result.
 */
export async function saveRelayTwoStep(input: RelayTwoStepSaveInput): Promise<RelayTwoStepSaveResult> {
  const found = input.detection?.discovery?.detection;
  const keyed = withRelayKeyDrafts(relayAddBaseProvider({
    id: input.providerID,
    endpoint: input.endpoint,
    apiKey: input.keys[0]!.apiKey.trim(), // key-choke: not-provider
    detection: found,
    providers: input.providers,
    now: new Date().toISOString(),
  }), input.keys);
  const catalogued: Provider = {
    ...keyed,
    catalogModels: input.catalogModels.map((model) => ({ ...model, isDefault: false })),
    ...(input.detection?.relayKeys && keyed.relayKeys ? { relayKeys: input.detection.relayKeys } : {}),
  };
  // Names differing only in case count as the same; only the first in display order is enabled; the hint reports exactly the count of models.
  const provider: Provider = { ...catalogued, models: relayBoundSelection(catalogued, relayStepTwoEnabledSelection(input.selected)) };
  const first = provider.models[0];
  if (!first) return { ok: false, result: { state: 'failed', attempts: [], failure: 'generation_not_verified', retriedRequestCount: 0 } };

  const explicit = relayEndpointExplicitTransport(input.endpoint, RELAY_SECURITY_MODE);
  const resolved = explicit
    ? [explicit]
    : await resolveRelayProbeCandidates({
        modelID: first.id,
        supportedEndpointTypes: input.detection?.endpointTypes[first.id],
        lookupFamily: input.lookupFamily,
      });
  // When discovered only through the generation route (no catalog), the protocol found is evidence for this connection: put it first among candidates, then by family.
  const probedRoute = !explicit && found?.detectionEvidence === 'generation_probe' ? found.transport : undefined;
  const candidates = probedRoute ? relayGenerationRouteCandidates(probedRoute, resolved) : resolved;
  const verification = await verifyRelayModelForAdd({
    provider,
    modelID: first.id,
    candidates,
    ping: input.ping,
    signal: input.signal,
  });
  if (!verification.ok) return { ok: false, result: verification.result };
  return {
    ok: true,
    provider: explicit ? provider : withRelayModelProbePass(provider, first.id, verification.pass),
    firstModelID: first.id,
  };
}

export interface RelayManualVerificationInput {
  /** The connection about to be saved (output of manualSetupProvider): the probe root is computed from it; a model with no bound key takes the primary key. */
  provider: Provider;
  modelID: string;
  signal?: AbortSignal;
  ping?: RelayModelProbePing;
  lookupFamily?: (modelID: string) => Promise<string | undefined>;
}

export type RelayManualVerification =
  | { ok: true; provider: Provider }
  /** error = the original error thrown by the last candidate (the failure card redacts it into text); errorCode = the real classification (analytics). */
  | { ok: false; error: unknown; errorCode: RelayDiscoveryFailureKind };

/**
 * Manual setup verification: when the default protocol is selected or the address carries its own protocol, send a single 1-token request for this model only, no probing, and the model gets no protocol;
 * in auto mode probe by vendor-family candidates (at most 2) and the protocol that passes lands on the model. Uses only the primary key; /models is not used as verification.
 */
export async function verifyRelayManualSetup(input: RelayManualVerificationInput): Promise<RelayManualVerification> {
  const { provider, modelID } = input;
  const transport = provider.relayRequested?.transport ?? 'auto';
  const explicit = relayEndpointExplicitTransport(provider.baseURLText ?? '', RELAY_SECURITY_MODE);
  const chosen: RelayModelTransport | undefined = transport !== 'auto' && transport !== 'llamacpp_native'
    ? transport
    : transport === 'auto' ? explicit : undefined;
  const candidates = chosen
    ? [chosen]
    : await resolveRelayProbeCandidates({ modelID, lookupFamily: input.lookupFamily });
  input.signal?.throwIfAborted();
  let lastError: unknown;
  let lastStatus: number | undefined;
  const pass = await probeRelayModelTransport({
    provider,
    modelID,
    candidates,
    ping: input.ping,
    signal: input.signal,
    onCandidateFailure: (_transport, error) => {
      lastError = error;
      const status = (error as { status?: unknown } | null)?.status;
      lastStatus = typeof status === 'number' ? status : undefined;
    },
  });
  if (!pass) return { ok: false, error: lastError, errorCode: relayAttemptFailureKind(lastStatus) };
  return { ok: true, provider: chosen ? provider : withRelayModelProbePass(provider, modelID, pass) };
}
