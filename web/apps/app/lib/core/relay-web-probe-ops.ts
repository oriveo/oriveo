import type { StoreApi } from 'zustand';
import type { AIModel, Provider, RelayCapabilityOverrides } from '@oriveo/shared';
import { isRelayWebTransport, type RelayWebFragment, type RelayWebTransport } from '@oriveo/shared/relay/web-fragments';
import type { RelayCapabilityTestReason } from '@oriveo/core/providers/relay-capability-test';
import {
  RELAY_WEB_PROBE_DEADLINE_MS,
  RELAY_WEB_PROBE_MAX_OUTPUT_TOKENS,
  judgeRelayWebProbeResponse,
  relayWebFragmentHash,
  relayWebProbeMessages,
  type RelayWebProbeRecord,
  type RelayWebProbeResult,
} from '@oriveo/core/providers/relay-web-probe';
import type { RelayWireRequest } from '@oriveo/core/providers/relay-orchestrator';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import type { StreamOptions } from './providers/types';
import type { AppStore } from './store/app-store';
import { sameNormalizedID } from '../utils/id-utils';
import { buildRelayChatRequest } from './providers/adapters/relay';
import { relayFirstSendTransport } from './providers/relay-first-send-transport';
import { canProbeRelayModels, relayProbeConnectionIdentity } from './relay-model-probe-ops';
import {
  relayCapabilityTestStreamOptions,
  sendRelayTestRequestOnce,
  sendViaChatTransport,
  writeOverrides,
  type RelayCapabilityTestSend,
} from './relay-capability-test-ops';
import { relayWebFragmentForTransport } from './chat/relay-web-fragments';
import { writeRelayWebProbeRecord } from './chat/relay-web-probe-records';

/**
 * Relay web probe executor (fixture web-probe.v1.json): RELAY only.
 * The request = same construction as the capability test (the model's first-choice protocol) + the snippet already stored for that protocol (merged the same way as chat); the only user message is a fixed prompt,
 * streaming, output cap 256, once, total time limit 30 seconds; a protocol with no snippet = not listed, zero requests.
 * The result is decided only by evidence parsed by that protocol's production streaming parser; searched / rejected / silent are written to the local record (same hash by merge rules),
 * searched / rejected then write the override web (tested; user source untouched); on silent where the merged result is not searched, tested web is removed; undetermined changes nothing.
 * For automatic triggering see relay-web-probe-auto.ts.
 */

export type RelayWebProbeOutcome = 'completed' | 'not_listed' | 'unavailable' | 'stopped';
export type RelayWebProbeStopReason = 'cancelled' | 'connection' | 'protocol' | 'fragment' | 'unavailable';

export interface RelayWebProbeRunResult {
  outcome: RelayWebProbeOutcome;
  /** The probed protocol (present only when a request was sent). */
  transport?: RelayWebTransport;
  result?: RelayWebProbeResult;
  reason?: RelayCapabilityTestReason;
  status?: number;
  evidenceUrls: string[];
  /** The merged local record (undetermined / interrupted is not written). */
  record?: RelayWebProbeRecord;
  stopReason?: RelayWebProbeStopReason;
  /** The override web was written to the store. */
  overrideWritten: boolean;
}

function findProvider(store: StoreApi<AppStore>, providerID: string): Provider | undefined {
  return store.getState().providers.find((item) => sameNormalizedID(item.id, providerID));
}

/** The probed protocol: RELAY only, within the per-model probe scope, and the first-choice protocol is one of the four web protocols. */
export function relayWebProbeTransport(provider: Provider, model: AIModel): RelayWebTransport | undefined {
  if (!canProbeRelayModels(provider)) return undefined;
  const transport = relayFirstSendTransport(provider, model);
  return isRelayWebTransport(transport) ? transport : undefined;
}

/** Chat options for the probe request: same construction as the capability test, with that protocol's snippet and the 256 output cap. */
export function relayWebProbeStreamOptions(provider: Provider, model: AIModel, fragment: RelayWebFragment): StreamOptions {
  return {
    ...relayCapabilityTestStreamOptions(provider, model, 'text'),
    relayWebFragment: fragment,
    relayMaxOutputTokens: RELAY_WEB_PROBE_MAX_OUTPUT_TOKENS,
  };
}

/**
 * Override mirror: tested web reflects only the current merged record; when the snippet changed, or the result is silent and the merged result is not searched, tested web is removed; user source untouched.
 * Returns whether anything was written.
 */
export function dropRelayTestedWebOverride(store: StoreApi<AppStore>, providerID: string, modelID: string): boolean {
  const provider = findProvider(store, providerID);
  const model = provider?.models.find((item) => item.id === modelID);
  if (!provider || model?.relayCapabilityOverrides?.web?.source !== 'tested') return false;
  writeOverrides(store, provider, modelID, (current) => {
    if (current?.web?.source !== 'tested') return current ? { ...current } : current;
    const { web: _web, ...rest } = current;
    return rest;
  });
  return true;
}

export async function runRelayWebProbe(
  store: StoreApi<AppStore>,
  providerID: string,
  modelID: string,
  deps: {
    send?: RelayCapabilityTestSend;
    signal?: AbortSignal;
    /** Total time limit; production = 30 seconds, tests inject a short value. */
    deadlineMs?: number;
    /** Clock (record at). */
    now?: () => number;
  } = {},
): Promise<RelayWebProbeRunResult> {
  const send = deps.send ?? sendViaChatTransport;
  const deadlineMs = deps.deadlineMs ?? RELAY_WEB_PROBE_DEADLINE_MS;
  const now = deps.now ?? (() => Date.now());
  const done = (
    outcome: RelayWebProbeOutcome,
    extra: Partial<Omit<RelayWebProbeRunResult, 'outcome'>> = {},
  ): RelayWebProbeRunResult => ({ outcome, evidenceUrls: [], overrideWritten: false, ...extra });

  const provider = findProvider(store, providerID);
  const model = provider?.models.find((item) => item.id === modelID);
  const transport = provider && model ? relayWebProbeTransport(provider, model) : undefined;
  if (!provider || !model || !transport) return done('unavailable');
  const fragment = relayWebFragmentForTransport(provider, transport);
  if (!fragment) return done('not_listed');
  const fragmentHash = relayWebFragmentHash(fragment);
  const identity = relayProbeConnectionIdentity(provider, modelID);

  let request: RelayWireRequest;
  try {
    request = buildRelayChatRequest(
      resolveProviderAPIKey(provider, model.id),
      model.id,
      relayWebProbeMessages(),
      provider.baseURLText,
      relayWebProbeStreamOptions(provider, model, fragment),
    );
  } catch {
    // Address / security policy rejected: no request was sent, undecidable.
    return done('completed', { transport, result: 'undetermined', reason: 'network' });
  }

  const sent = await sendRelayTestRequestOnce(request, send, deps.signal, deadlineMs);
  if (sent === 'cancelled') return done('stopped', { transport, stopReason: 'cancelled' });
  const verdict = await judgeRelayWebProbeResponse(
    transport,
    typeof sent === 'string' ? { failure: sent } : sent,
  );
  const base = {
    transport,
    result: verdict.result,
    reason: verdict.reason,
    evidenceUrls: verdict.evidenceUrls,
    ...(typeof sent === 'string' ? {} : { status: sent.status }),
  };
  // Undecidable: write no record and do not change the override (keep the original value).
  if (verdict.result === 'undetermined') return done('completed', base);

  // Re-check before writing back: cancelled -> not probeable -> connection identity -> protocol -> snippet; stop and write nothing if any changed.
  if (deps.signal?.aborted) return done('stopped', { ...base, stopReason: 'cancelled' });
  const latest = findProvider(store, providerID);
  const latestModel = latest?.models.find((item) => item.id === modelID);
  if (!latest || !latestModel || !relayWebProbeTransport(latest, latestModel)) {
    return done('stopped', { ...base, stopReason: 'unavailable' });
  }
  if (relayProbeConnectionIdentity(latest, modelID) !== identity) return done('stopped', { ...base, stopReason: 'connection' });
  if (relayWebProbeTransport(latest, latestModel) !== transport) return done('stopped', { ...base, stopReason: 'protocol' });
  const latestFragment = relayWebFragmentForTransport(latest, transport);
  if (!latestFragment || relayWebFragmentHash(latestFragment) !== fragmentHash) {
    return done('stopped', { ...base, stopReason: 'fragment' });
  }

  const record = writeRelayWebProbeRecord(
    { connectionId: latest.id, modelId: modelID, transport },
    { result: verdict.result, source: 'tested', at: new Date(now()).toISOString(), fragmentHash },
  );
  if (verdict.result === 'silent') {
    // If the merged record is still searched (silent does not erase searched), keep tested true; otherwise remove tested web.
    if (record.result !== 'searched') dropRelayTestedWebOverride(store, providerID, modelID);
    return done('completed', { ...base, record });
  }
  if (latestModel.relayCapabilityOverrides?.web?.source === 'user') {
    return done('completed', { ...base, record });
  }
  const value = verdict.result === 'searched';
  writeOverrides(store, latest, modelID, (current): RelayCapabilityOverrides => {
    // The user picked manually during write-back: do not overwrite.
    if (current?.web?.source === 'user') return { ...current };
    return { ...current, web: { value, source: 'tested' } };
  });
  return done('completed', { ...base, record, overrideWritten: true });
}
