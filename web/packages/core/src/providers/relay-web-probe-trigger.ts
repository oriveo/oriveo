import type { RelayWebTransport } from '@oriveo/shared/relay/web-fragments';

/**
 * Automatic trigger selection for relay web-search probes (fixture web-probe.v1.json triggers / triggerCases).
 * Pure function: the caller supplies the event, candidates (in enablement order), the local automatic history and an injected clock; this only decides which are sent and which are recorded as untested.
 */

export const RELAY_WEB_PROBE_PER_SAVE = 5;
export const RELAY_WEB_PROBE_PER_CONNECTION_PER_WINDOW = 10;
export const RELAY_WEB_PROBE_WINDOW_MS = 86_400_000;

export type RelayWebProbeForm = 'RELAY' | 'BYOK' | 'FREE' | 'MANAGED' | 'SUB';

/** Automatic history entry: written only by automatic probes (before sending); manual / retest probes do not enter it. */
export interface RelayWebProbeAutoHistoryEntry {
  connectionId: string;
  modelId: string;
  transport: string;
  fragmentHash: string;
  sentAt: string;
}

export interface RelayWebProbeCandidate {
  modelId: string;
  transport: RelayWebTransport;
  fragmentHash: string;
}

export type RelayWebProbeTriggerEvent =
  | { type: 'saveFragment' }
  | { type: 'enableModel'; lazyVerify: 'passed' | 'failed' | 'notRun' }
  | { type: 'manualTest' }
  | { type: 'retest' }
  | { type: 'redetect' }
  | { type: 'addConnection' };

export interface RelayWebProbeSelection {
  probe: RelayWebProbeCandidate[];
  untested: RelayWebProbeCandidate[];
  /** Whether the probe sent this time counts toward the rolling cap (only automatic probes count). */
  countsTowardCap: boolean;
}

export interface RelayWebProbeSelectionInput {
  form: RelayWebProbeForm;
  event: RelayWebProbeTriggerEvent;
  connectionId: string;
  /** Models already in enablement order whose first-choice protocol has a fragment. */
  candidates: readonly RelayWebProbeCandidate[];
  history: readonly RelayWebProbeAutoHistoryEntry[];
  now: number;
}

function dedupeKey(item: { connectionId: string; modelId: string; transport: string; fragmentHash: string }): string {
  return JSON.stringify([item.connectionId, item.modelId, item.transport, item.fragmentHash]);
}

function inWindow(entry: RelayWebProbeAutoHistoryEntry, now: number): boolean {
  const sentAt = Date.parse(entry.sentAt);
  return Number.isFinite(sentAt) && now - sentAt < RELAY_WEB_PROBE_WINDOW_MS;
}

/**
 * Selection: non-RELAY never probes; manual / retest probes the candidates directly (no cap, no dedup, not recorded in history);
 * an automatic event only fires on enablement after the fragment is saved and the lazy check passes. First drop candidates whose dedup key is already in the automatic history (they take no slot),
 * then send the first min(perSave, remaining quota in this connection's window) and record the rest as untested.
 */
export function selectRelayWebProbes(input: RelayWebProbeSelectionInput): RelayWebProbeSelection {
  const none: RelayWebProbeSelection = { probe: [], untested: [], countsTowardCap: false };
  if (input.form !== 'RELAY') return none;
  const { event } = input;
  if (event.type === 'manualTest' || event.type === 'retest') {
    return { probe: [...input.candidates], untested: [], countsTowardCap: false };
  }
  const automatic = event.type === 'saveFragment' || (event.type === 'enableModel' && event.lazyVerify === 'passed');
  if (!automatic) return none;

  const own = input.history.filter((entry) => entry.connectionId === input.connectionId);
  const sent = new Set(own.map(dedupeKey));
  const used = own.filter((entry) => inWindow(entry, input.now)).length;
  const slots = Math.max(0, Math.min(RELAY_WEB_PROBE_PER_SAVE, RELAY_WEB_PROBE_PER_CONNECTION_PER_WINDOW - used));
  const fresh = input.candidates.filter((item) => !sent.has(dedupeKey({ connectionId: input.connectionId, ...item })));
  return { probe: fresh.slice(0, slots), untested: fresh.slice(slots), countsTowardCap: true };
}

/** Prune history on every save: only entries of this connection that are out of the window and whose (protocol, hash) is no longer the current fragment (entries of the current fragment stay for dedup). */
export function pruneRelayWebProbeAutoHistory(
  history: readonly RelayWebProbeAutoHistoryEntry[],
  scope: { connectionId: string; now: number; currentHashes: Partial<Record<string, string>> },
): RelayWebProbeAutoHistoryEntry[] {
  return history.filter((entry) => entry.connectionId !== scope.connectionId
    || inWindow(entry, scope.now)
    || scope.currentHashes[entry.transport] === entry.fragmentHash);
}
