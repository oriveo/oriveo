import type { StoreApi } from 'zustand';
import type { Provider } from '@oriveo/shared';
import { RELAY_WEB_FRAGMENT_TEMPLATES, isRelayWebTransport, type RelayWebFragments, type RelayWebTransport } from '@oriveo/shared/relay/web-fragments';
import { relayWebFragmentHash } from '@oriveo/core/providers/relay-web-probe';
import {
  pruneRelayWebProbeAutoHistory,
  selectRelayWebProbes,
  type RelayWebProbeCandidate,
  type RelayWebProbeTriggerEvent,
} from '@oriveo/core/providers/relay-web-probe-trigger';
import type { AppStore } from './store/app-store';
import { sameNormalizedID } from '../utils/id-utils';
import { withErrorReporting } from '../sentry/report-silent';
import { canProbeRelayModels } from './relay-model-probe-ops';
import {
  dropRelayTestedWebOverride,
  relayWebProbeTransport,
  runRelayWebProbe,
} from './relay-web-probe-ops';
import { effectiveRelayWebFragmentsForProvider, relayWebFragmentForTransport } from './chat/relay-web-fragments';
import {
  appendRelayWebProbeAutoHistory,
  readRelayWebProbeAutoHistory,
  writeRelayWebProbeAutoHistory,
} from './chat/relay-web-probe-records';

/**
 * Automatic triggering of relay web probes: after the Web Search page saves successfully and after a lazy verification actually ran and passed, each counts as one event;
 * selected by pure selection (cap / rolling window / dedup) and run serially in the background through the production probe `runRelayWebProbe`; closing the page does not cancel. RELAY form only.
 * History is written before an automatic probe is sent; manual / re-test does not go through here.
 */

export interface RelayWebAutoProbeDeps {
  /** Clock (history sentAt, record at); defaults to Date.now. */
  now?: () => number;
}

// All automatic events share one serial queue: only one runs at a time, and the selection of a later event sees the history written by the earlier one.
let queue: Promise<void> = Promise.resolve();

function enqueue(job: () => Promise<void>): void {
  queue = queue.then(job).catch((error: unknown) => {
    withErrorReporting('relay.web_probe_auto')(error);
  });
}

function findProvider(store: StoreApi<AppStore>, providerID: string): Provider | undefined {
  return store.getState().providers.find((item) => sameNormalizedID(item.id, providerID));
}

function fragmentHashes(fragments: RelayWebFragments): Partial<Record<string, string>> {
  const out: Partial<Record<string, string>> = {};
  for (const [transport, fragment] of Object.entries(fragments)) {
    if (fragment) out[transport] = relayWebFragmentHash(fragment);
  }
  return out;
}

/** Candidate for a model: the first-choice protocol (resolved the same way as the record key) has a non-empty snippet. */
function candidateFor(provider: Provider, modelID: string): RelayWebProbeCandidate | undefined {
  const model = provider.models.find((item) => item.id === modelID);
  const transport: RelayWebTransport | undefined = model ? relayWebProbeTransport(provider, model) : undefined;
  const fragment = transport ? relayWebFragmentForTransport(provider, transport) : undefined;
  if (!transport || !fragment) return undefined;
  return { modelId: modelID, transport, fragmentHash: relayWebFragmentHash(fragment) };
}

async function runSelected(
  store: StoreApi<AppStore>,
  providerID: string,
  event: RelayWebProbeTriggerEvent,
  candidates: (provider: Provider) => RelayWebProbeCandidate[],
  deps: RelayWebAutoProbeDeps,
): Promise<void> {
  const now = deps.now ?? (() => Date.now());
  const provider = findProvider(store, providerID);
  if (!provider || !canProbeRelayModels(provider)) return;
  let history = readRelayWebProbeAutoHistory();
  if (event.type === 'saveFragment') {
    history = pruneRelayWebProbeAutoHistory(history, {
      connectionId: provider.id,
      now: now(),
      currentHashes: fragmentHashes(effectiveRelayWebFragmentsForProvider(provider)),
    });
    writeRelayWebProbeAutoHistory(history);
  }
  const selection = selectRelayWebProbes({
    form: 'RELAY',
    event,
    connectionId: provider.id,
    candidates: candidates(provider),
    history,
    now: now(),
  });
  for (const selected of selection.probe) {
    // The model was disabled while queued / its protocol or snippet changed: this one is no longer sent (and no history is written).
    const latest = findProvider(store, providerID);
    const current = latest && canProbeRelayModels(latest) ? candidateFor(latest, selected.modelId) : undefined;
    if (!current || current.transport !== selected.transport || current.fragmentHash !== selected.fragmentHash) continue;
    appendRelayWebProbeAutoHistory({
      connectionId: latest!.id,
      modelId: selected.modelId,
      transport: selected.transport,
      fragmentHash: selected.fragmentHash,
      sentAt: new Date(now()).toISOString(),
    });
    try {
      await runRelayWebProbe(store, latest!.id, selected.modelId, { now });
    } catch (error) {
      // One failing does not hold up the rest.
      withErrorReporting('relay.web_probe_auto')(error);
    }
  }
}

/**
 * Web Search page saved successfully = one event. First sync the mirrored override: for a protocol whose snippet hash changed, remove tested web from models whose first-choice protocol it is;
 * then enqueue: candidates = enabled models (in enable order) whose first-choice protocol has a non-empty snippet after saving; the whole save shares the cap.
 */
export function runRelayWebAutoProbesAfterSave(
  store: StoreApi<AppStore>,
  providerID: string,
  previousFragments: RelayWebFragments,
  deps: RelayWebAutoProbeDeps = {},
): void {
  const provider = findProvider(store, providerID);
  if (!provider || !canProbeRelayModels(provider)) return;
  const before = fragmentHashes(previousFragments);
  const after = fragmentHashes(effectiveRelayWebFragmentsForProvider(provider));
  // The comparison is on the effective fragment (stored, or the template when none is stored): saving a fragment equal to the template is not a change, and the tested web from the template probe stays.
  const effectiveHash = (hashes: Partial<Record<string, string>>, transport: string) => hashes[transport]
    ?? (isRelayWebTransport(transport) ? relayWebFragmentHash(RELAY_WEB_FRAGMENT_TEMPLATES[transport]) : undefined);
  const changed = new Set(
    [...new Set([...Object.keys(before), ...Object.keys(after)])]
      .filter((transport) => effectiveHash(before, transport) !== effectiveHash(after, transport)),
  );
  if (changed.size > 0) {
    for (const model of provider.models) {
      const transport = relayWebProbeTransport(provider, model);
      if (transport && changed.has(transport)) dropRelayTestedWebOverride(store, provider.id, model.id);
    }
  }
  enqueue(() => runSelected(
    store,
    providerID,
    { type: 'saveFragment' },
    (latest) => latest.models.flatMap((model) => candidateFor(latest, model.id) ?? []),
    deps,
  ));
}

/** Enabling after a lazy verification actually ran and passed = one event (this one model only); callers whose lazy verification did not run / failed do not call this. */
export function runRelayWebAutoProbeAfterEnable(
  store: StoreApi<AppStore>,
  providerID: string,
  modelID: string,
  deps: RelayWebAutoProbeDeps = {},
): void {
  enqueue(() => runSelected(
    store,
    providerID,
    { type: 'enableModel', lazyVerify: 'passed' },
    (latest) => {
      const candidate = candidateFor(latest, modelID);
      return candidate ? [candidate] : [];
    },
    deps,
  ));
}

/** For tests: wait for the background serial queue to finish (including events enqueued while it runs). */
export async function __relayWebAutoProbesSettledForTest(): Promise<void> {
  let current: Promise<void>;
  do {
    current = queue;
    await current;
  } while (current !== queue);
}
