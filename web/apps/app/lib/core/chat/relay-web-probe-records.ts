/**
 * Local records of relay web search probes: key = connection x model x protocol,
 * value = {result, source, at, fragmentHash}; on this device only (not in cloud sync, backups or the Server recipe), deleted along with the connection.
 * See `mergeRelayWebProbeRecord` for merge rules; a record whose hash differs from the current fragment counts as untested.
 * Fixture: `test-fixtures/relay/web-probe.v1.json` record.
 */
import type { AIModel, Citation, Provider } from '@oriveo/shared';
import { isRelayWebTransport, type RelayWebFragment } from '@oriveo/shared/relay/web-fragments';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';
import type { RelayWebProbeAutoHistoryEntry } from '@oriveo/core/providers/relay-web-probe-trigger';
import {
  mergeRelayWebProbeRecord,
  relayWebFragmentHash,
  type RelayWebProbeRecord,
} from '@oriveo/core/providers/relay-web-probe';
import { safeLocalStorage } from '../../infra/storage/web-storage';
import type { RelayNegativeCacheModelKey } from './relay-negative-cache';
import { relayWebFragmentForTransport } from './relay-web-fragments';
import { relayFirstSendTransport } from '../providers/relay-first-send-transport';

export const RELAY_WEB_PROBE_RECORDS_STORAGE_KEY = 'oriveo.relay-web-probe-records.v1';
/** Auto probe history: same layer as the records, on this device only; entry {connection, model, protocol, fragment hash, sentAt}. */
export const RELAY_WEB_PROBE_AUTO_HISTORY_STORAGE_KEY = 'oriveo.relay-web-probe-auto-history.v1';

/** Same key shape as the negative cache: connection x model x effective protocol. */
export type RelayWebProbeRecordKey = RelayNegativeCacheModelKey;

interface StoredEntry extends RelayWebProbeRecordKey, RelayWebProbeRecord {}

const RESULTS: ReadonlySet<string> = new Set(['searched', 'rejected', 'silent']);
const SOURCES: ReadonlySet<string> = new Set(['tested', 'observed']);

function isStoredEntry(value: unknown): value is StoredEntry {
  if (typeof value !== 'object' || value === null) return false;
  const entry = value as Record<string, unknown>;
  return typeof entry.connectionId === 'string'
    && typeof entry.modelId === 'string'
    && typeof entry.transport === 'string'
    && typeof entry.result === 'string' && RESULTS.has(entry.result)
    && typeof entry.source === 'string' && SOURCES.has(entry.source)
    && typeof entry.at === 'string'
    && typeof entry.fragmentHash === 'string';
}

// Bad data / unavailable storage is always read as empty: an absent record = untested.
function readEntries(): StoredEntry[] {
  try {
    const raw = safeLocalStorage.getItem(RELAY_WEB_PROBE_RECORDS_STORAGE_KEY);
    if (!raw) return [];
    const entries = (JSON.parse(raw) as { entries?: unknown })?.entries;
    return Array.isArray(entries) ? entries.filter(isStoredEntry) : [];
  } catch {
    return [];
  }
}

function writeEntries(entries: StoredEntry[]): void {
  try {
    if (entries.length === 0) {
      safeLocalStorage.removeItem(RELAY_WEB_PROBE_RECORDS_STORAGE_KEY);
      return;
    }
    safeLocalStorage.setItem(RELAY_WEB_PROBE_RECORDS_STORAGE_KEY, JSON.stringify({ version: 1, entries }));
  } catch {
    // A failed write does not affect the returned probe result; the next probe writes again.
  }
}

function sameKey(entry: RelayWebProbeRecordKey, key: RelayWebProbeRecordKey): boolean {
  return entry.connectionId === key.connectionId
    && entry.modelId === key.modelId
    && entry.transport === key.transport;
}

function toRecord(entry: StoredEntry): RelayWebProbeRecord {
  return { result: entry.result, source: entry.source, at: entry.at, fragmentHash: entry.fragmentHash };
}

/** Read as is (without checking whether the fragment has changed). */
export function readRelayWebProbeRecord(key: RelayWebProbeRecordKey): RelayWebProbeRecord | undefined {
  const entry = readEntries().find((item) => sameKey(item, key));
  return entry ? toRecord(entry) : undefined;
}

/** The record valid for the current fragment; a different hash = untested. */
export function currentRelayWebProbeRecord(
  key: RelayWebProbeRecordKey,
  fragment: RelayWebFragment | undefined,
): RelayWebProbeRecord | undefined {
  if (!fragment) return undefined;
  const record = readRelayWebProbeRecord(key);
  return record && record.fragmentHash === relayWebFragmentHash(fragment) ? record : undefined;
}

/** Write one record by the merge rules and return the merged record. */
export function writeRelayWebProbeRecord(
  key: RelayWebProbeRecordKey,
  incoming: RelayWebProbeRecord,
): RelayWebProbeRecord {
  const entries = readEntries();
  const existing = entries.find((item) => sameKey(item, key));
  const merged = mergeRelayWebProbeRecord(existing ? toRecord(existing) : null, incoming);
  const kept = entries.filter((item) => !sameKey(item, key));
  kept.push({ connectionId: key.connectionId, modelId: key.modelId, transport: key.transport, ...merged });
  writeEntries(kept);
  return merged;
}

/** Clear a whole connection (on connection delete): records and auto history are deleted together. */
export function clearRelayWebProbeRecordsConnection(connectionId: string): void {
  const entries = readEntries();
  const kept = entries.filter((entry) => entry.connectionId !== connectionId);
  if (kept.length !== entries.length) writeEntries(kept);
  const history = readRelayWebProbeAutoHistory();
  const keptHistory = history.filter((entry) => entry.connectionId !== connectionId);
  if (keptHistory.length !== history.length) writeRelayWebProbeAutoHistory(keptHistory);
}

/* -- Auto probe history -- */

function isAutoHistoryEntry(value: unknown): value is RelayWebProbeAutoHistoryEntry {
  if (typeof value !== 'object' || value === null) return false;
  const entry = value as Record<string, unknown>;
  return typeof entry.connectionId === 'string'
    && typeof entry.modelId === 'string'
    && typeof entry.transport === 'string'
    && typeof entry.fragmentHash === 'string'
    && typeof entry.sentAt === 'string';
}

// Bad data / unavailable storage is read as empty: at worst one extra auto probe is sent, and saving is not blocked.
export function readRelayWebProbeAutoHistory(): RelayWebProbeAutoHistoryEntry[] {
  try {
    const raw = safeLocalStorage.getItem(RELAY_WEB_PROBE_AUTO_HISTORY_STORAGE_KEY);
    if (!raw) return [];
    const entries = (JSON.parse(raw) as { entries?: unknown })?.entries;
    return Array.isArray(entries) ? entries.filter(isAutoHistoryEntry) : [];
  } catch {
    return [];
  }
}

export function writeRelayWebProbeAutoHistory(entries: readonly RelayWebProbeAutoHistoryEntry[]): void {
  try {
    if (entries.length === 0) {
      safeLocalStorage.removeItem(RELAY_WEB_PROBE_AUTO_HISTORY_STORAGE_KEY);
      return;
    }
    safeLocalStorage.setItem(RELAY_WEB_PROBE_AUTO_HISTORY_STORAGE_KEY, JSON.stringify({ version: 1, entries }));
  } catch {
    // Failed write: the same fragment may be probed once more next time, which is acceptable.
  }
}

/** Written before an auto probe is sent. */
export function appendRelayWebProbeAutoHistory(entry: RelayWebProbeAutoHistoryEntry): void {
  writeRelayWebProbeAutoHistory([...readRelayWebProbeAutoHistory(), entry]);
}

/* -- Chat-side and presentation reads of records -- */

type RelayWebProvider = Pick<Provider, 'id' | 'relayRequested'>;

/**
 * The fragment chat should attach: when the record for this model x protocol under the current fragment is rejected, do not attach (no TTL; only a retest or a fragment change lifts it);
 * silent / untested / expired hash are attached as usual.
 */
export function relayWebFragmentForChat(
  provider: RelayWebProvider,
  model: Pick<AIModel, 'id'> | null | undefined,
  transport: string | undefined,
): RelayWebFragment | undefined {
  const fragment = relayWebFragmentForTransport(provider, transport);
  if (!fragment || !model || !isRelayWebTransport(transport)) return fragment;
  const record = currentRelayWebProbeRecord({ connectionId: provider.id, modelId: model.id, transport }, fragment);
  return record?.result === 'rejected' ? undefined : fragment;
}

/**
 * Relay facts for the web search row of the model options panel: the fragment of the model's first-send protocol (the same protocol chat actually sends and the probe writes records for) + the record result valid for the current fragment.
 */
export function relayWebModelOptionFacts(
  provider: Provider,
  model: AIModel | null | undefined,
): { localEngine: boolean; hasFragment: boolean; probe?: RelayWebProbeRecord['result'] } {
  const transport = model ? relayFirstSendTransport(provider, model) : effectiveTransport(provider, null);
  const fragment = relayWebFragmentForTransport(provider, transport);
  const record = fragment && model && isRelayWebTransport(transport)
    ? currentRelayWebProbeRecord({ connectionId: provider.id, modelId: model.id, transport }, fragment)
    : undefined;
  return {
    localEngine: Boolean(provider.relayRequested?.engineProfile),
    hasFragment: fragment !== undefined,
    ...(record ? { probe: record.result } : {}),
  };
}

/** Web citation: has a url and is not a library / MCP document citation (docId, mcp and source are all empty). */
function isWebCitation(citation: Citation): boolean {
  return citation.url.trim() !== '' && !citation.docId && !citation.mcp && !citation.source;
}

/**
 * Passive record: relay chat delivered, this turn actually carried a fragment, and production parsing produced citations -> searched / observed (no extra request).
 * Not written when there is no web citation or this turn switched protocol; a failed send never reaches the delivery path. The hash is taken from the fragment actually sent this turn.
 */
export function recordRelayWebSearchObserved(params: {
  provider: Pick<Provider, 'id' | 'kind'>;
  model: Pick<AIModel, 'id'>;
  sentFragment: RelayWebFragment | undefined;
  transport: string | undefined;
  firstSendTransport: string | undefined;
  citations: readonly Citation[] | undefined;
  at: string;
}): void {
  const { provider, model, sentFragment, transport, firstSendTransport, citations, at } = params;
  if (provider.kind !== 'relay' || !sentFragment || !isRelayWebTransport(transport)) return;
  // This turn switched protocol (protocol-level fallback): the evidence does not belong to the first-send protocol, so do not write.
  if (transport !== firstSendTransport) return;
  if (!citations?.some(isWebCitation)) return;
  writeRelayWebProbeRecord(
    { connectionId: provider.id, modelId: model.id, transport },
    { result: 'searched', source: 'observed', at, fragmentHash: relayWebFragmentHash(sentFragment) },
  );
}
