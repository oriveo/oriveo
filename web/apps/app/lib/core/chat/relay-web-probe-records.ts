/**
 * Local records of relay web search probes: key = connection x model x protocol,
 * value = {result, source, at, fragmentHash}; on this device only (not in cloud sync, backups or the Server recipe), deleted along with the connection.
 * See `mergeRelayWebProbeRecord` for merge rules; a record whose hash differs from the current fragment counts as untested.
 * Fixture: `test-fixtures/relay/web-probe.v1.json` record.
 */
import type { AIModel, Citation, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';
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
import { relayEffectiveWebFragment } from './relay-web-fragments';
import type { CapabilityWebPreference } from './capability-preference-settings';
import { relayFirstSendTransport } from '../providers/relay-first-send-transport';
import { providerFormOf } from '../capability/truth/provider-form';

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

/* -- The web switch is a chat switch; chat, presentation, truth and the Advanced page all read one set of facts -- */

type RelayWebProvider = Pick<Provider, 'id' | 'relayRequested'>;

/** Status row id (fixture web-probe.v1.json presentationCases statusId); each client maps it to its own copy. */
export type RelayWebStatusId =
  | 'web_probe_searched'
  | 'web_probe_silent'
  | 'web_probe_rejected'
  | 'web_probe_unverified'
  | 'web_probe_untested'
  | 'web_user_off'
  | 'web_user_on';

/** Relay web search facts: the stored fragment on the first-send protocol, the record valid for the effective fragment, the user override web. */
export type RelayWebFacts = {
  /** Local engine connection (has an engineProfile): no web search. */
  localEngine: boolean;
  /** The first-send protocol has a non-empty stored fragment (including legacy fields mapped at read time); when none, the effective fragment = that protocol's template. */
  hasFragment: boolean;
  /** Result of the local probe record valid for the effective fragment; absent = not tested or the fragment has changed. */
  probe?: RelayWebProbeRecord['result'];
  /** Model override web with source user; the tested source is not here (it is only a mirror of the record). */
  userOverride?: boolean;
};

export type RelayWebPresentation = {
  row: 'toggle' | 'toggleDisabled';
  isOn: boolean;
  statusId: RelayWebStatusId;
  /** Retest exit when the current record is rejected: a rejected stored fragment -> the web settings page; a rejected template -> that model's capability test. */
  retestLink?: 'openConnectionWebSearch' | 'testCapabilities';
  sendsFragment: boolean;
  /** Switch on but no fragment sent (current record rejected) -> web_not_used; otherwise absent = null. */
  replyNotice?: 'web_not_used' | null;
  truth: 'supported' | 'unsupported' | 'unknown';
  /** Advanced page web row: the status only looks at records; source user (override) > tested (current record searched / rejected) > none. */
  advanced: { statusId: RelayWebStatusId; source: 'tested' | 'user' | null };
};

/** Default layer of the chat web preference (resolved as the default layer only, no migration written): the first-send protocol has a stored fragment -> on, otherwise off. */
export function relayWebPreferenceDefault(facts: Pick<RelayWebFacts, 'hasFragment'>): CapabilityWebPreference {
  return facts.hasFragment ? 'automatic' : 'off';
}

/**
 * Relay value of the default layer of the chat web preference (read and send share it): only the RELAY form has it; otherwise undefined (stay off).
 */
export function relayWebPreferenceDefaultFor(
  provider: Provider | null | undefined,
  model: AIModel | null | undefined,
): CapabilityWebPreference | undefined {
  if (!provider || !model || providerFormOf(provider) !== 'relay') return undefined;
  return relayWebPreferenceDefault(relayWebModelOptionFacts(provider, model));
}

/** The provider_default layer of the send-side ladder (`resolveCapabilityPreferences`); undefined for non-relay. */
export function relayWebProviderDefault(
  provider: Provider | null | undefined,
  model: AIModel | null | undefined,
): { web: CapabilityWebPreference } | undefined {
  const web = relayWebPreferenceDefaultFor(provider, model);
  return web ? { web } : undefined;
}

/**
 * The single decision for relay web search (fixture web-probe.v1.json presentationCases).
 * webPreference = the chat web preference resolved for this session x connection x model (anything but off is on; a relay has no timing level); null = never set, use the default layer.
 * Priority: user override off > user override on > current record rejected > the rest.
 */
export function resolveRelayWebPresentation(
  facts: Pick<RelayWebFacts, 'hasFragment' | 'probe' | 'userOverride'>,
  webPreference: CapabilityWebPreference | null,
): RelayWebPresentation {
  const preference = webPreference ?? relayWebPreferenceDefault(facts);
  const recordStatus: RelayWebStatusId = facts.probe === 'searched' ? 'web_probe_searched'
    : facts.probe === 'silent' ? 'web_probe_silent'
      : facts.probe === 'rejected' ? 'web_probe_rejected'
        : facts.hasFragment ? 'web_probe_unverified' : 'web_probe_untested';
  const advanced: RelayWebPresentation['advanced'] = {
    statusId: recordStatus,
    source: facts.userOverride !== undefined ? 'user'
      : facts.probe === 'searched' || facts.probe === 'rejected' ? 'tested' : null,
  };
  if (facts.userOverride === false) {
    return { row: 'toggleDisabled', isOn: false, statusId: 'web_user_off', sendsFragment: false, truth: 'unsupported', advanced };
  }
  const isOn = preference !== 'off';
  // The switch only listens to the user: a rejected current record neither greys it out nor shows it as off; the status copy and retest exit stay, this turn carries no fragment, and with the switch on a reply notice is attached.
  if (facts.userOverride !== true && facts.probe === 'rejected') {
    return {
      row: 'toggle', isOn, statusId: 'web_probe_rejected',
      retestLink: facts.hasFragment ? 'openConnectionWebSearch' : 'testCapabilities',
      sendsFragment: false, replyNotice: isOn ? 'web_not_used' : null, truth: 'unsupported', advanced,
    };
  }
  return {
    row: 'toggle',
    isOn,
    statusId: facts.userOverride === true ? 'web_user_on' : recordStatus,
    sendsFragment: isOn,
    truth: facts.userOverride === true || facts.probe === 'searched' ? 'supported' : 'unknown',
    advanced,
  };
}

/**
 * Fragment chat should attach: only when the chat switch is on (the final web intent on the send path) is the effective fragment of that protocol attached (the stored one, or the template when none is stored);
 * not attached when the user override is off, or when the current record is rejected and the user has not overridden on. transport = the protocol actually dispatched this turn (the first-send protocol when the first send switches protocol).
 */
export function relayWebFragmentForChat(
  provider: RelayWebProvider,
  model: Pick<AIModel, 'id' | 'relayCapabilityOverrides'> | null | undefined,
  transport: string | undefined,
  webOn: boolean,
): RelayWebFragment | undefined {
  if (!webOn || !model || provider.relayRequested?.engineProfile) return undefined;
  const effective = relayEffectiveWebFragment(provider, transport);
  if (!effective || !isRelayWebTransport(transport)) return undefined;
  const record = currentRelayWebProbeRecord({ connectionId: provider.id, modelId: model.id, transport }, effective.fragment);
  const presentation = resolveRelayWebPresentation({
    hasFragment: effective.source === 'saved',
    ...(record ? { probe: record.result } : {}),
    ...relayWebUserOverride(model),
  }, 'automatic');
  return presentation.sendsFragment ? effective.fragment : undefined;
}

function relayWebUserOverride(model: Pick<AIModel, 'relayCapabilityOverrides'>): { userOverride?: boolean } {
  const web = model.relayCapabilityOverrides?.web;
  return web?.source === 'user' && typeof web.value === 'boolean' ? { userOverride: web.value } : {};
}

/**
 * Relay web search facts: the stored fragment of the model's first-send protocol (the same protocol chat first sends on and the probe writes records for) + the record valid for the effective fragment + the user override.
 */
export function relayWebModelOptionFacts(
  provider: Provider,
  model: AIModel | null | undefined,
): RelayWebFacts {
  const transport = model ? relayFirstSendTransport(provider, model) : effectiveTransport(provider, null);
  const localEngine = Boolean(provider.relayRequested?.engineProfile);
  const effective = localEngine ? undefined : relayEffectiveWebFragment(provider, transport);
  const record = effective && model && isRelayWebTransport(transport)
    ? currentRelayWebProbeRecord({ connectionId: provider.id, modelId: model.id, transport }, effective.fragment)
    : undefined;
  return {
    localEngine,
    hasFragment: effective?.source === 'saved',
    ...(record ? { probe: record.result } : {}),
    ...(model ? relayWebUserOverride(model) : {}),
  };
}

/**
 * Whether this turn's outbound really carried web search (the "actually sent" basis for web_search_used and the like):
 * relay = the final options merged the effective fragment (the switch is on and not blocked by a user override off / a rejected current record);
 * other forms = supportsWebSearch after the outbound gate is intersected with the transport envelope.
 */
export function webSearchDispatched(
  provider: Pick<Provider, 'kind'>,
  options: Pick<StreamOptions, 'supportsWebSearch' | 'relayWebFragment'> | undefined,
): boolean {
  if (provider.kind === 'relay') return options?.relayWebFragment !== undefined;
  return Boolean(options?.supportsWebSearch);
}

/** Web citation: has a url and is not a library / MCP document citation (docId, mcp and source are all empty). */
function isWebCitation(citation: Citation): boolean {
  return citation.url.trim() !== '' && !citation.docId && !citation.mcp && !citation.source;
}

/**
 * Passive record: relay chat delivered, this turn actually carried a fragment, and production parsing produced citations -> searched / observed (no extra request).
 * Written for the protocol actually sent (including a protocol fallback that carried the target protocol's fragment); not written when there is no web citation; a failed send never reaches the delivery path.
 * The hash is taken from the fragment actually sent this turn.
 */
export function recordRelayWebSearchObserved(params: {
  provider: Pick<Provider, 'id' | 'kind'>;
  model: Pick<AIModel, 'id'>;
  sentFragment: RelayWebFragment | undefined;
  transport: string | undefined;
  citations: readonly Citation[] | undefined;
  at: string;
}): void {
  const { provider, model, sentFragment, transport, citations, at } = params;
  if (provider.kind !== 'relay' || !sentFragment || !isRelayWebTransport(transport)) return;
  if (!citations?.some(isWebCitation)) return;
  writeRelayWebProbeRecord(
    { connectionId: provider.id, modelId: model.id, transport },
    { result: 'searched', source: 'observed', at, fragmentHash: relayWebFragmentHash(sentFragment) },
  );
}
