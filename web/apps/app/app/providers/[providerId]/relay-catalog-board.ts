import type { AIModel, Provider } from '@oriveo/shared';
import { decidedTransport } from '@oriveo/core/providers/relay-effective';
import { relayFirstSendTransport } from '../../../lib/core/providers/relay-first-send-transport';
import { resolveProviderAttachmentSupport, visionCardFacts } from '../../../lib/core/chat/attachment-policy';
import { resolveModelCapabilityEvidence } from '../../../lib/core/chat/capability-evidence';
import { presentCapabilityControl } from '../../../lib/core/chat/capability-control-presentation';
import { modelOptionLocalEngine } from '../../../lib/core/chat/model-option-capability-shape';
import { visionState } from '../../../lib/core/chat/model-options-panel-model';
import { relayInputOverrideValue } from '../../../lib/core/capability/capability-overrides';
import { readInputNegativeCache } from '../../../lib/core/capability/input-negative-cache';
import { inputNegativeCacheTarget } from '../../../lib/core/capability/truth/input-truth-adapter';
import type { StreamOptions } from '../../../lib/core/providers/types';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../../lib/core/chat/stream-options';
import { setupProtocolForTransport, type SetupProtocol } from '../relay/new/setup-board';
import { bindRelayKey, listingKeysOf, relayKeyIDs, relayKeyList, relayKeyRows, relayModelKeyState, relayShowsKeyUI } from '@oriveo/shared/relay/relay-keys';
import { relayBindingFamily } from '../../../lib/core/provider-model-ops';
import type { RelayLazyProbeState } from '../../../lib/core/relay-model-probe-ops';
import type { RelayCatalogLoadState } from '../../../lib/hooks/useProviderActions';
import {
  relayAvatarSource,
  resolveRelayConnectionAvatar,
  type RelayAvatar,
  type RelayAvatarSource,
} from '../../../components/relay-avatar';
import { getRelayAvatarChoice } from '../../../lib/core/providers/relay-avatar-choices';
import { knownRelayKeyStatusState, relayKeyStatusKey, relayKeyTitle } from './relay-keys-board';
import { relayKeyCatalogFailureKey } from '../relay/new/relay-setup-two-step';
import { relayModelKey } from '../../../lib/core/providers/relay-model-identity';

/**
 * View state of the Relay / local connection "model library" sub-page. The component renders only from this output,
 * and the structure tests assert this too. The three capability states call only this app's existing predicates, with no separate criteria.
 * Copy keys always carry a namespace and are resolved by the root translator.
 */

export const RELAY_CATALOG_TEXT = {
  sectionEnabled: 'pages.relayDetail.catalogSectionEnabled',
  sectionLibrary: 'pages.relayDetail.catalogSectionLibrary',
  legendSupported: 'pages.relayDetail.catalogLegendSupported',
  legendUnknown: 'pages.relayDetail.catalogLegendUnknown',
  legendUnsupported: 'pages.relayDetail.catalogLegendUnsupported',
  sourcesFootnote: 'pages.relayDetail.catalogSourcesFootnote',
  filterAll: 'pages.modelSwitcher.filterAll',
  /** key(id) filter chip "Key: <key display name>". */
  filterKey: 'pages.relayDetail.catalogFilterKey',
  status: {
    missingFromCatalog: 'pages.relayDetail.modelMissingFromCatalog',
    verified: 'pages.relayDetail.catalogStatusVerified',
    reachable: 'pages.relayDetail.catalogStatusReachable',
    setByYou: 'pages.relayDetail.catalogStatusSetByYou',
    verifyOnEnable: 'pages.relayDetail.catalogStatusVerifyOnEnable',
    unknownUntilSent: 'common.modelOptionsVisionUnknown',
    denied: 'pages.relayDetail.catalogStatusDenied',
    verifying: 'pages.relayDetail.catalogStatusVerifying',
    unreachable: 'pages.relayDetail.catalogStatusUnreachable',
  },
  /** Enable hint under a group: when the connection is auto, the whole sentence; when the connection is pinned, only the latter half. */
  enableHint: {
    probe: 'pages.relayDetail.catalogEnableHint',
    noProbe: 'pages.relayDetail.catalogEnableHintNoProbe',
  },
  more: 'common.advancedMore',
  remove: 'common.remove',
  removeLastReason: 'pages.relayDetail.catalogRemoveLastReason',
  addAll: 'pages.providerDetail.addAll',
  addedModels: 'pages.relayDetail.catalogAddedModels',
  /** Row screen-reader value: capability names and status words reuse the existing ones from the Advanced page / model options. */
  capTitle: {
    image: 'common.modelOptionsVisionTitle',
    file: 'common.modelOptionsFilesTitle',
    thinking: 'pages.relaySetup.localTileThinking',
    tool: 'pages.relayDetail.advanced.toolCalls',
    web: 'common.capabilityControlWebSearch',
  },
  capState: {
    supported: 'pages.relayDetail.capabilityTest.supported',
    unknown: 'pages.relayDetail.advanced.unknown',
    unsupported: 'pages.relayDetail.capabilityTest.unsupported',
  },
} as const;

export const RELAY_CATALOG_CAPS = ['image', 'file', 'thinking', 'tool', 'web'] as const;
export type RelayCatalogCap = typeof RELAY_CATALOG_CAPS[number];
export type RelayCatalogCapState = 'supported' | 'unknown' | 'unsupported';
/** Show only models listed by one key; entered from the keys page or `?view=library&key=<id>`. */
export interface RelayCatalogKeyFilter {
  key: string;
}
export type RelayCatalogFilter = 'all' | SetupProtocol | RelayCatalogKeyFilter;

export function isRelayCatalogKeyFilter(filter: RelayCatalogFilter): filter is RelayCatalogKeyFilter {
  return typeof filter === 'object';
}

export function sameRelayCatalogFilter(a: RelayCatalogFilter, b: RelayCatalogFilter): boolean {
  if (isRelayCatalogKeyFilter(a) || isRelayCatalogKeyFilter(b)) {
    return isRelayCatalogKeyFilter(a) && isRelayCatalogKeyFilter(b) && a.key === b.key;
  }
  return a === b;
}
export type RelayCatalogStatus = keyof typeof RELAY_CATALOG_TEXT.status;
/** Where a row click goes: enabled rows go to writable Advanced, catalog rows go to read-only Advanced without sending requests. The view dispatches only by it. */
export type RelayCatalogTapTarget = 'advanced' | 'readOnlyAdvanced';
/** Trailing actions: enabled [newChat, more]; catalog [add] / [unavailable]. */
export type RelayCatalogTrailingItem = 'newChat' | 'more' | 'add' | 'unavailable';

/** "⋯" menu items: only remove; with just 1 enabled it is greyed out with a reason. */
export interface RelayCatalogMenuItem {
  action: 'remove';
  enabled: boolean;
  reasonKey: string | null;
}

export interface RelayCatalogRow {
  model: AIModel;
  /** null for local connections (with engineProfile): the channel is connection-level, no protocol is drawn. */
  protocol: SetupProtocol | null;
  caps: { cap: RelayCatalogCap; state: RelayCatalogCapState }[];
  status: RelayCatalogStatus | null;
  tapTarget: RelayCatalogTapTarget;
  trailing: RelayCatalogTrailingItem[];
  /** "⋯" menu of enabled rows; empty for catalog rows. */
  menu: RelayCatalogMenuItem[];
  /** Row screen-reader value: "capability name status word" in icon order, joined by the view with ", " (capability icons are hidden from screen readers). */
  accessibilityValue: { titleKey: string; stateKey: string }[];
  /** Key chip (name or mask) on enabled rows when ≥2 keys; null otherwise. */
  keyChip: string | null;
}

export interface RelayCatalogSection {
  id: 'enabled' | 'library';
  count: number;
  rows: RelayCatalogRow[];
}

export interface RelayCatalogBoardModel {
  /** Empty = the whole row is hidden (local connection, or fewer than two distinct protocols). */
  chips: RelayCatalogFilter[];
  filter: RelayCatalogFilter;
  /** Display name of the key when the key(id) filter is active (same function as the key row title); otherwise null. */
  filterKeyTitle: string | null;
  enabled: RelayCatalogSection;
  library: RelayCatalogSection;
}

const PROTOCOL_ORDER: readonly SetupProtocol[] = ['Chat', 'Responses', 'Messages', 'Gemini'];

export function relayCatalogBoard(input: {
  provider: Provider;
  enabledModels: readonly AIModel[];
  catalogModels: readonly AIModel[];
  /** The catalog loaded successfully; when it did not load, "catalog missing" is not judged. */
  catalogLoaded: boolean;
  filter: RelayCatalogFilter;
  /** Negative-cache expiry is computed from this time. */
  now: number;
  /** This session's lazy verification state (by model id), memory only; "not connected" is invalidated when the effective key value changes or a send succeeds. */
  probeStates?: ReadonlyMap<string, RelayLazyProbeState>;
}): RelayCatalogBoardModel {
  const { provider, enabledModels, catalogModels, catalogLoaded, now } = input;
  const keyTitles = relayShowsKeyUI(provider)
    ? new Map(relayKeyRows(provider).map((row) => [row.id, relayKeyTitle(row)]))
    : null;
  const isLocal = Boolean(provider.relayRequested?.engineProfile);
  const enabledIDs = new Set(enabledModels.map((model) => model.id));
  const catalogIDs = new Set(catalogModels.map((model) => model.id));
  // The catalog may contain duplicate ids: dedupe by id (keep the first) before subtracting enabled ones, so the count matches the rows.
  const seen = new Set<string>();
  const libraryModels = catalogModels.filter((model) => {
    if (enabledIDs.has(model.id) || seen.has(model.id)) return false;
    seen.add(model.id);
    return true;
  });

  // With just 1 enabled it cannot be removed (judged by the total enabled count, not by how many rows are visible after filtering).
  const removeItem: RelayCatalogMenuItem = enabledModels.length >= 2
    ? { action: 'remove', enabled: true, reasonKey: null }
    : { action: 'remove', enabled: false, reasonKey: RELAY_CATALOG_TEXT.removeLastReason };
  const enabledRows = enabledModels.map((model): RelayCatalogRow => {
    const missing = catalogLoaded && model.isManual !== true && !catalogIDs.has(model.id);
    const keyState = relayModelKeyState(provider, model.id);
    const original: RelayCatalogStatus | null = missing ? 'missingFromCatalog' : isLocal ? null : enabledStatus(model, provider);
    const caps = catalogCaps(provider, model, now);
    return {
      model,
      protocol: isLocal ? null : setupProtocolForTransport(relayFirstSendTransport(provider, model)),
      caps,
      status: lazyStatus(keyState.deniedOnCurrentKey, input.probeStates?.get(model.id)) ?? original,
      tapTarget: 'advanced',
      trailing: ['newChat', 'more'],
      menu: [removeItem],
      accessibilityValue: accessibilityValueOf(caps),
      keyChip: keyTitles?.get(keyState.boundKeyID) ?? null,
    };
  });
  const libraryRows = libraryModels.map((model): RelayCatalogRow => {
    const caps = catalogCaps(provider, model, now);
    return {
      model,
      protocol: isLocal ? null : setupProtocolForTransport(relayFirstSendTransport(provider, model)),
      caps,
      status: isLocal
        ? null
        : followsChosenConnectionTransport(provider, model)
          ? 'setByYou'
          : caps.some((cap) => cap.state !== 'unknown') ? 'verifyOnEnable' : 'unknownUntilSent',
      tapTarget: 'readOnlyAdvanced',
      trailing: [model.isAvailable ? 'add' : 'unavailable'],
      menu: [],
      accessibilityValue: accessibilityValueOf(caps),
      keyChip: null,
    };
  });

  const present = new Set([...enabledRows, ...libraryRows].map((row) => row.protocol));
  const protocols = PROTOCOL_ORDER.filter((protocol) => present.has(protocol));
  const protocolChips: RelayCatalogFilter[] = !isLocal && protocols.length >= 2 ? protocols : [];
  // key(id) filter: takes effect only if that key still exists and its catalog is non-empty, otherwise falls back to All; when active, the chip is placed after All.
  const keyRow = isRelayCatalogKeyFilter(input.filter)
    ? relayKeyRows(provider).find((row) => row.id === (input.filter as RelayCatalogKeyFilter).key && row.catalogCount > 0)
    : undefined;
  const keyFilter: RelayCatalogKeyFilter | null = keyRow ? { key: keyRow.id } : null;
  const chips: RelayCatalogFilter[] = keyFilter
    ? ['all', keyFilter, ...protocolChips]
    : protocolChips.length > 0 ? ['all', ...protocolChips] : [];
  const filter: RelayCatalogFilter = keyFilter
    ?? (!isRelayCatalogKeyFilter(input.filter) && protocolChips.includes(input.filter) ? input.filter : 'all');
  const keyIDs = relayKeyIDs(provider);
  const listedByFilterKey = (row: RelayCatalogRow) => keyFilter !== null
    && listingKeysOf(keyIDs, provider.catalogModels.find((entry) => entry.id === row.model.id)).includes(keyFilter.key);
  const visible = (row: RelayCatalogRow) => filter === 'all'
    || (keyFilter ? listedByFilterKey(row) : row.protocol === filter);

  return {
    chips,
    filter,
    filterKeyTitle: keyRow ? relayKeyTitle(keyRow) : null,
    enabled: { id: 'enabled', count: enabledModels.length, rows: enabledRows.filter(visible) },
    library: { id: 'library', count: libraryModels.length, rows: libraryRows.filter(visible) },
  };
}

function accessibilityValueOf(caps: RelayCatalogRow['caps']): RelayCatalogRow['accessibilityValue'] {
  return caps.map(({ cap, state }) => ({
    titleKey: RELAY_CATALOG_TEXT.capTitle[cap],
    stateKey: RELAY_CATALOG_TEXT.capState[state],
  }));
}

/**
 * Models that the group header "Add all" should enable (same order as the group rows): not enabled, marked available in the catalog, and the key they would land on after enabling
 * is not judged unauthorized (unauthorized marked on another key still counts). Which key it lands on follows the same binding rule as enabling a single one. Empty = no button in the group header.
 */
export function relayCatalogEnableAllModelIDs(provider: Provider, groupModels: readonly AIModel[]): string[] {
  const enabledIDs = new Set(provider.models.map((model) => relayModelKey(model.id)));
  const keys = relayKeyIDs(provider);
  const ids: string[] = [];
  for (const model of groupModels) {
    if (enabledIDs.has(relayModelKey(model.id)) || !model.isAvailable || ids.includes(model.id)) continue;
    if (model.relayDeniedKeyID !== undefined) {
      const landing = bindRelayKey({
        keys,
        catalog: provider.catalogModels,
        enabled: provider.models,
        targetModelID: model.id,
        family: relayBindingFamily,
      }) ?? keys[0];
      if (model.relayDeniedKeyID === landing) continue;
    }
    ids.push(model.id);
  }
  return ids;
}

/** Priority of the three new states: unauthorized > verifying > not connected; if none match, return null (fall back to the existing state). */
function lazyStatus(denied: boolean, probe: RelayLazyProbeState | undefined): RelayCatalogStatus | null {
  if (denied) return 'denied';
  if (probe?.phase === 'inFlight') return 'verifying';
  if (probe?.phase === 'failed') return 'unreachable';
  return null;
}

/* ── Page header / per-key status bar / layout ─────────────────── */

export interface RelayCatalogHeader {
  /** Relay avatar (from the resolver function); null for local connections. */
  avatar: RelayAvatar | null;
  /** Input for the avatar button (change-icon sheet); null for local connections. */
  avatarSource: RelayAvatarSource | null;
  host: string;
  /** Enabled ∪ catalog, deduplicated. */
  modelCount: number;
  /** Provided only for ≥2 keys. */
  keyCount: number | null;
}

function hostOf(baseURLText: string | null | undefined): string {
  const raw = (baseURLText ?? '').trim();
  try {
    return new URL(raw.includes('://') ? raw : `https://${raw}`).host;
  } catch {
    return raw;
  }
}

export function relayCatalogHeader(provider: Provider): RelayCatalogHeader {
  const keyCount = relayKeyList(provider).length;
  const avatarSource = provider.relayRequested?.engineProfile ? null : relayAvatarSource(provider);
  return {
    avatar: avatarSource
      ? resolveRelayConnectionAvatar({ ...avatarSource, choice: getRelayAvatarChoice(provider.id) })
      : null,
    avatarSource,
    host: hostOf(provider.baseURLText),
    modelCount: new Set([...provider.models, ...provider.catalogModels].map((model) => model.id)).size,
    keyCount: keyCount >= 2 ? keyCount : null,
  };
}

export interface RelayCatalogKeyStripItem {
  id: string;
  title: string;
  catalogCount: number;
  /** ok draws ✓; failed draws "<code> <status word>" + Retry; neither is drawn when never checked. */
  state: 'ok' | 'failed' | 'unchecked';
  httpStatus?: number;
  /** null when never checked. */
  statusKey: string | null;
  retry: boolean;
}

/** Per-key status bar at the top of the catalog area with ≥2 keys; status only reads `RelayKey.status`, no extra probing. */
export function relayCatalogKeyStrip(provider: Provider): RelayCatalogKeyStripItem[] {
  if (!relayShowsKeyUI(provider)) return [];
  const entries = relayKeyList(provider);
  return relayKeyRows(provider).map((row, index) => {
    const status = entries[index]?.status;
    // Unrecognized status values are treated as never checked.
    const known = knownRelayKeyStatusState(status?.state);
    const state = !known ? 'unchecked' : known === 'ok' ? 'ok' : 'failed';
    return {
      id: row.id,
      title: relayKeyTitle(row),
      catalogCount: row.catalogCount,
      state,
      ...(state === 'failed' && status?.httpStatus !== undefined ? { httpStatus: status.httpStatus } : {}),
      statusKey: relayKeyStatusKey(row.status),
      retry: state === 'failed',
    };
  });
}

export interface RelayCatalogLayout {
  /** Single-key catalog fetch failure: full-width failure card (with ≥2 keys the failure is expressed by the status bar). */
  failureCard: boolean;
  /** Draw the catalog area only when there are catalog rows (success but empty is not drawn; on failure the old catalog still shows). */
  showLibrary: boolean;
  /** Enable hint under a group: when connection is auto (enabling will probe) the whole sentence; when connection is pinned only the latter half; not shown for local. */
  enableHint: keyof typeof RELAY_CATALOG_TEXT.enableHint | null;
}

export function relayCatalogLayout(input: {
  provider: Provider;
  catalogLoadState: RelayCatalogLoadState;
  libraryCount: number;
}): RelayCatalogLayout {
  const showLibrary = input.catalogLoadState !== 'loading' && input.libraryCount > 0;
  return {
    failureCard: input.catalogLoadState === 'failed' && !relayShowsKeyUI(input.provider),
    showLibrary,
    enableHint: !showLibrary || input.provider.relayRequested?.engineProfile
      ? null
      : decidedTransport(input.provider, null) ? 'noProbe' : 'probe',
  };
}

/**
 * Reason sentence of the failure card: when the primary key has a last status code, reuse the same failure classification as the add flow (address / key / permission / rate limit / network);
 * an old single-key connection has no recorded status code, so reuse the existing "you can add a model ID manually" sentence (manual add is at the page bottom).
 */
export function relayCatalogFailureReasonKey(provider: Provider): string {
  const status = relayKeyList(provider)[0]?.status;
  if (status && status.state !== 'ok' && status.httpStatus !== undefined) {
    return `pages.relaySetup.${relayKeyCatalogFailureKey(status.httpStatus)}`;
  }
  return 'pages.relayDetail.catalogFetchFailedHint';
}

/**
 * Enabled rows are written by protocol source: reachable only means the 1-token probe passed, not "verified".
 * Models without a model-level protocol, old data with auto, or a protocol with a missing source (old value dropped on read-back) are all unknown.
 * When a connection is passed and its protocol was chosen by the user: models with no protocol of their own follow it and are written as "user set".
 */
export function enabledStatus(model: AIModel, provider?: Pick<Provider, 'baseURLText' | 'relayRequested'>): RelayCatalogStatus {
  if (provider && followsChosenConnectionTransport(provider, model)) return 'setByYou';
  if (!model.relayTransport || (model.relayTransport as string) === 'auto') return 'unknownUntilSent';
  switch (model.relayTransportSource) {
    case 'observed': return 'verified';
    case 'reachable': return 'reachable';
    case 'user': return 'setByYou';
    default: return 'unknownUntilSent';
  }
}

/** The connection protocol was chosen by the user (not auto) and the model has no protocol of its own: the protocol is that user choice, no probing. */
function followsChosenConnectionTransport(
  provider: Pick<Provider, 'baseURLText' | 'relayRequested'>,
  model: Pick<AIModel, 'relayTransport'>,
): boolean {
  const own = model.relayTransport as string | undefined;
  return (!own || own === 'auto') && decidedTransport(provider, null) !== undefined;
}

export function catalogCaps(provider: Provider, model: AIModel, now: number): RelayCatalogRow['caps'] {
  // Same dispatch parameters as the input box / capability evidence: the Relay connection identity is determined by it.
  const streamOptions = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);
  const evidence = (key: 'tool_call' | 'web_search'): RelayCatalogCapState =>
    resolveModelCapabilityEvidence({ key, provider, model, streamOptions }).support;
  const states: Record<RelayCatalogCap, RelayCatalogCapState> = {
    image: imageState(provider, model),
    file: fileState(provider, model, streamOptions, now),
    thinking: thinkingState(provider, model),
    tool: evidence('tool_call'),
    web: evidence('web_search'),
  };
  return RELAY_CATALOG_CAPS.map((cap) => ({ cap, state: states[cap] }));
}

/** Vision: the same set of facts as the vision card (entry visible × no positive-evidence predicate). */
function imageState(provider: Provider, model: AIModel): RelayCatalogCapState {
  const state = visionState(visionCardFacts(provider, model, resolveProviderAttachmentSupport(provider, model)));
  return state === 'available' ? 'supported' : state === 'unknown' ? 'unknown' : 'unsupported';
}

/**
 * File: file override first (On → supported, Off → unsupported); otherwise if the Relay `file` negative cache has not expired → unsupported;
 * otherwise if the native file allowlist is non-empty → supported; otherwise unknown (draws the model fact, not per route).
 */
function fileState(provider: Provider, model: AIModel, streamOptions: StreamOptions | undefined, now: number): RelayCatalogCapState {
  const override = relayInputOverrideValue(model, 'file_input');
  if (override?.source === 'user') return override.value ? 'supported' : 'unsupported';
  if (relayInputNegativeCached(provider, model, streamOptions, 'file_input', now)) return 'unsupported';
  if (override) return override.value ? 'supported' : 'unsupported';
  return (model.nativeFileMimes?.length ?? 0) > 0 ? 'supported' : 'unknown';
}

/** Whether the input-capability negative cache v2 hits (same key and verdict revision as the projection and the send side). */
export function relayInputNegativeCached(
  provider: Provider,
  model: AIModel,
  streamOptions: StreamOptions | undefined,
  key: 'vision_input' | 'file_input',
  now: number,
): boolean {
  const target = inputNegativeCacheTarget(provider, model, streamOptions, key);
  return target !== null && readInputNegativeCache(target.key, target.verdictRevision, now) !== null;
}

/**
  * Thinking: for a local connection (with engineProfile), if the engine declares a thinking key follow it; otherwise if there are adjustable thinking levels → supported; otherwise unknown.
  * The recipe's `unavailable` is not treated as unsupported: Relay models without evidence also land on it.
  * The branch "every level at the evidence layer is judged unsupported → unsupported" has no existing function in this app, so it is not done.
 */
function thinkingState(provider: Provider, model: AIModel): RelayCatalogCapState {
  const declared = modelOptionLocalEngine(provider, model)?.declaredThinking;
  if (typeof declared === 'boolean') return declared ? 'supported' : 'unsupported';
  const state = presentCapabilityControl(provider, model, 'reasoning').state;
  return state === 'auto_available' || state === 'managed_only' ? 'supported' : 'unknown';
}
