// External web search: web-row resolution, the web card and per-conversation choice, and this turn's route. The UI renders purely from these functions' results and never decides on its own.
// Contract fixture: web-route-resolution.v1.json in the shared search-contracts directory;
// reference implementation: scripts/lib/search-route.mjs (same names and semantics on every client).

import { regionForConnection, type CatalogEntry } from './search-catalog';
import type { SearchServiceStatus } from './search-settings';

export type WebRouteForm = 'byok' | 'relay' | 'subscription_codex' | 'subscription_grok' | 'free' | 'managed';
export type NativeWebState = 'available' | 'unavailable' | 'unknown' | 'withdrawn_or_rejected';
export type RelayWebRecord =
  | 'searched'
  | 'supported'
  | 'rejected'
  | 'silent'
  | 'untested'
  | 'template_only'
  | 'user_override_off'
  | 'local_engine'
  | 'protocol_undecided';
export type ToolCallSupport = 'supported' | 'unknown' | 'unsupported';
export type SearchSourceMethod = 'default' | 'native' | 'external';
export type WebRouteRow =
  | 'toggle_native_unchanged'
  | 'toggle_with_source_picker'
  | 'toggle_external'
  | 'toggle_external_presearch_notice'
  | 'one_tap_reuse_connection_key'
  | 'cannot_search'
  | 'relay_unchanged'
  | 'always_on_unchanged'
  | 'free_unchanged'
  | 'managed_unchanged';
export type WebRouteAction = 'add_search_service' | 'open_supported_models' | 'one_tap_enable' | 'pick_source';
export type WebSearchPath = 'none' | 'native' | 'relay_fragment' | 'external_tool' | 'external_presearch';

export interface WebRouteInput {
  form: WebRouteForm;
  nativeWeb?: NativeWebState;
  relayWebRecord?: RelayWebRecord;
  externalServices?: number;
  reusableConnection?: boolean;
  toolCall?: ToolCallSupport;
  webOn?: boolean;
  method?: SearchSourceMethod;
}

export interface WebRoute {
  row: WebRouteRow;
  path: WebSearchPath;
  primaryAction?: WebRouteAction;
  secondaryAction?: WebRouteAction;
  sourceAction?: WebRouteAction;
  fragmentAttached?: boolean;
}

const RELAY_NATIVE: ReadonlySet<string> = new Set(['searched', 'supported']);
const RELAY_UNCHANGED: ReadonlySet<string> = new Set(['user_override_off', 'local_engine', 'protocol_undecided']);

function externalPath(toolCall: ToolCallSupport): WebSearchPath {
  return toolCall === 'unsupported' ? 'external_presearch' : 'external_tool';
}

/**
 * Web row and this turn's web route. See the fixture legend for inputs; a turn takes exactly one route: path has a single value.
 */
export function resolveWebSearchRoute(input: WebRouteInput): WebRoute {
  const { form, webOn = false, toolCall = 'unknown' } = input;
  const services = input.externalServices ?? 0;
  const method = services > 0 ? (input.method ?? 'default') : 'default';
  const on = webOn === true;

  if (form === 'free') return { row: 'free_unchanged', path: 'none' };
  if (form === 'managed') return { row: 'managed_unchanged', path: on && input.nativeWeb === 'available' ? 'native' : 'none' };
  if (form === 'subscription_grok') return { row: 'always_on_unchanged', path: 'native' };

  let nativeKind: WebSearchPath | null = null; // the route used when native web search is available
  let fragmentForbidden = false;
  if (form === 'relay') {
    const record = input.relayWebRecord ?? '';
    // User override web=false, local engine, protocol undecided: behavior unchanged, and no external search is offered either
    if (RELAY_UNCHANGED.has(record)) return { row: 'relay_unchanged', path: 'none' };
    if (RELAY_NATIVE.has(record)) nativeKind = 'relay_fragment';
    else fragmentForbidden = true;
  } else if (form === 'byok' || form === 'subscription_codex') {
    if (input.nativeWeb === 'available') nativeKind = 'native';
  } else {
    throw new Error(`unknown form: ${String(form)}`);
  }

  if (nativeKind) {
    if (services === 0) {
      return { row: form === 'relay' ? 'relay_unchanged' : 'toggle_native_unchanged', path: on ? nativeKind : 'none' };
    }
    const path = !on ? 'none' : method === 'external' ? externalPath(toolCall) : nativeKind;
    return { row: 'toggle_with_source_picker', path, sourceAction: 'pick_source' };
  }

  // Native web search unavailable (including unknown, withdrawn / rejected, relay not confirmed)
  if (services > 0) {
    const out: WebRoute = {
      row: toolCall === 'unsupported' ? 'toggle_external_presearch_notice' : 'toggle_external',
      path: on ? externalPath(toolCall) : 'none',
      sourceAction: 'pick_source',
    };
    if (fragmentForbidden) out.fragmentAttached = false;
    return out;
  }
  if (form === 'relay') return { row: 'relay_unchanged', path: 'none' };
  // With no local service, webOn is ignored: the switch being on most likely means the previously used model could search natively, so it must not be treated as "synced"
  if (input.reusableConnection === true) return { row: 'one_tap_reuse_connection_key', path: 'none', primaryAction: 'one_tap_enable' };
  return { row: 'cannot_search', path: 'none', primaryAction: 'add_search_service', secondaryAction: 'open_supported_models' };
}

// ───────────── Web card and per-conversation choice ─────────────

/**
 * Whether a service may appear on the web card and in the "Search method" page (also decides the externalServices count of resolveWebSearchRoute).
 * Only withdrawn services are excluded. A temporarily unavailable catalog, a missing key, a changed host or a lost connection still count: the card keeps the user's choice and explains the state via notes,
 * without sending the user to "Add", and without clearing the conversation's choice just because the catalog is briefly unavailable.
 */
export function searchServiceSelectable(status: SearchServiceStatus | string): boolean {
  return status !== 'withdrawn';
}

export interface OneTapConnection {
  id: string;
  name?: string | null;
  providerKind: string;
  baseUrl?: string | null;
}

export interface OneTapTarget {
  serviceId: string;
  regionId: string;
  connectionRef: string;
  connectionName: string | null;
}

/**
 * Which provider "one-tap enable" connects to: the first catalog entry (in catalog order) that has reuse and for which a connection exists with the same providerKind and a host that resolves to a site;
 * an entry from the same provider as the current model (same providerKind) wins, otherwise the first one. null when the catalog is unavailable or nothing matches.
 * The output is also the prefill for the connect page: reuse this connection's key, and pick the site from the connection host.
 */
export function oneTapReuseTarget({
  catalogAvailable,
  entries = [],
  connections = [],
  currentProviderKind = null,
}: {
  catalogAvailable: boolean;
  entries?: ReadonlyArray<Pick<CatalogEntry, 'id' | 'reuse'>>;
  connections?: ReadonlyArray<OneTapConnection>;
  currentProviderKind?: string | null;
}): OneTapTarget | null {
  if (!catalogAvailable) return null;
  const candidates: Array<OneTapTarget & { providerKind: string }> = [];
  for (const e of entries) {
    if (!e.reuse) continue;
    for (const c of connections) {
      if (c.providerKind !== e.reuse.providerKind) continue;
      const regionId = regionForConnection(e, c.baseUrl);
      if (regionId) {
        candidates.push({ serviceId: e.id, regionId, connectionRef: c.id, connectionName: c.name ?? null, providerKind: c.providerKind });
        break;
      }
    }
  }
  const pick = candidates.find((t) => t.providerKind === currentProviderKind) ?? candidates[0] ?? null;
  if (!pick) return null;
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  const { providerKind, ...target } = pick;
  return target;
}

export type StoredSearchMethod = 'native' | 'external';

export interface StoredSearchSource {
  /** Remembered per "conversation x model": <modelKey> -> native / external. */
  methods: Record<string, StoredSearchMethod>;
  serviceId: string | null;
  serviceName: string | null;
  notice: { fromName: string } | null;
}

const METHOD_VALUES: ReadonlySet<string> = new Set(['native', 'external']);

function emptySource(): StoredSearchSource {
  return { methods: {}, serviceId: null, serviceName: null, notice: null };
}

function normalizeStored(stored: unknown): StoredSearchSource {
  if (!stored || typeof stored !== 'object') return emptySource();
  const s = stored as Record<string, unknown>;
  const methods: Record<string, StoredSearchMethod> = {};
  if (s.methods && typeof s.methods === 'object') {
    for (const [k, v] of Object.entries(s.methods as Record<string, unknown>)) {
      if (typeof k === 'string' && typeof v === 'string' && METHOD_VALUES.has(v)) methods[k] = v as StoredSearchMethod;
    }
  }
  const notice = s.notice as { fromName?: unknown } | null | undefined;
  return {
    methods,
    serviceId: typeof s.serviceId === 'string' ? s.serviceId : null,
    serviceName: typeof s.serviceName === 'string' ? s.serviceName : null,
    notice: notice && typeof notice.fromName === 'string' ? { fromName: notice.fromName } : null,
  };
}

function sortedMethods(m: Record<string, string>): string {
  return Object.keys(m).sort().map((k) => `${k}=${m[k]}`).join('|');
}

function sameSource(a: StoredSearchSource, b: StoredSearchSource): boolean {
  return sortedMethods(a.methods) === sortedMethods(b.methods) && a.serviceId === b.serviceId
    && a.serviceName === b.serviceName && (a.notice?.fromName ?? null) === (b.notice?.fromName ?? null);
}

function isEmptySource(s: StoredSearchSource): boolean {
  return Object.keys(s.methods).length === 0 && s.serviceId === null && s.serviceName === null && s.notice === null;
}

function withoutExternal(methods: Record<string, StoredSearchMethod>): Record<string, StoredSearchMethod> {
  const out: Record<string, StoredSearchMethod> = {};
  for (const [k, v] of Object.entries(methods)) if (v !== 'external') out[k] = v;
  return out;
}

/** Local storage key for the per-conversation choice: lives in the account's search partition, not in preference sync and not in backups. */
export function searchSourceStorageKey(conversationId: string): string {
  return `conversationSource:${conversationId}`;
}

export interface SelectableSearchService {
  id: string;
  status: SearchServiceStatus | string;
}

export interface ResolvedSearchSource {
  method: SearchSourceMethod;
  serviceId: string | null;
  notice: { fromName: string } | null;
  nextStored: StoredSearchSource | null;
  changed: boolean;
}

/**
 * Which source this conversation uses this turn (read path; called each time the model options open, on every send, and before the chip preview).
 * - methods are remembered per "conversation x model": a model that can search natively records "built-in / external"; for one that cannot, external = external is switched on.
 *   Switching models does not clear them and switching back restores them; an unrecorded model is default (native-capable -> built-in; otherwise -> external off).
 * - If the service chosen for the conversation was deleted or withdrawn -> serviceId is cleared and all external records are dropped (external search turns off rather than silently switching to another billed provider), and a notice is recorded once.
 * - With no selectable service: external records and serviceId are cleared without a notice; native records are kept.
 * - When the default service is not selectable, the first selectable one is used.
 * When changed is false nothing may be written to storage (prevents self-triggering write loops).
 */
export function resolveSearchSource({
  stored = null,
  modelKey,
  selectable = [],
  defaultServiceId = null,
}: {
  stored?: unknown;
  modelKey: string;
  selectable?: ReadonlyArray<Pick<SelectableSearchService, 'id'>>;
  defaultServiceId?: string | null;
}): ResolvedSearchSource {
  const s = normalizeStored(stored);
  const next: StoredSearchSource = { ...s, methods: { ...s.methods } };
  const ids = selectable.map((x) => x.id);
  const fallbackId = defaultServiceId !== null && ids.includes(defaultServiceId) ? defaultServiceId : (ids[0] ?? null);
  let serviceId: string | null = fallbackId;
  if (ids.length === 0) {
    next.methods = withoutExternal(next.methods);
    next.serviceId = null;
    next.serviceName = null;
    next.notice = null;
  } else if (next.serviceId && ids.includes(next.serviceId)) {
    serviceId = next.serviceId;
  } else if (next.serviceId) {
    next.notice = { fromName: next.serviceName ?? '' };
    next.methods = withoutExternal(next.methods);
    next.serviceId = null;
    next.serviceName = null;
  }
  const changed = !sameSource(s, next);
  return {
    method: next.methods[modelKey] ?? 'default',
    serviceId,
    notice: next.notice ? { fromName: next.notice.fromName } : null,
    nextStored: isEmptySource(next) ? null : next,
    changed,
  };
}

export type SearchSourceEvent =
  | { type: 'pick_native' }
  | { type: 'pick_service'; serviceId: string; serviceName?: string | null }
  | { type: 'disarm' }
  | { type: 'acknowledge_notice' };

/**
 * User actions on the web card / "Search method" page (write path). Returns the storage value to write (null = delete the key).
 * - pick_native: choosing "Built-in" on the "Search method" page.
 * - pick_service: explicitly choosing external = switching external on for this model: sent when a service is picked on the "Search method" page, the external switch is turned on, one-tap enable succeeds,
 *   or "Add search service" on the web card succeeds. On a native-capable model, picking a service also turns the conversation's web search on.
 * - disarm: the external switch is turned off manually - only this model's external is turned off; conversation web search is not written.
 * - acknowledge_notice: when the model options panel actually closes.
 * Choosing any source clears the notice.
 */
export function updateSearchSource({
  stored = null,
  modelKey,
  event,
}: {
  stored?: unknown;
  modelKey: string;
  event: SearchSourceEvent;
}): StoredSearchSource | null {
  const s = normalizeStored(stored);
  const next: StoredSearchSource = { ...s, methods: { ...s.methods } };
  if (event.type === 'pick_native') {
    next.methods[modelKey] = 'native';
    next.notice = null;
  } else if (event.type === 'pick_service') {
    next.methods[modelKey] = 'external';
    next.serviceId = event.serviceId;
    next.serviceName = event.serviceName ?? null;
    next.notice = null;
  } else if (event.type === 'disarm') {
    if (next.methods[modelKey] === 'external') delete next.methods[modelKey];
  } else if (event.type === 'acknowledge_notice') {
    next.notice = null;
  } else {
    throw new Error(`unknown event: ${(event as { type: string }).type}`);
  }
  return isEmptySource(next) ? null : next;
}

export type SearchSourcePickerItem =
  | { kind: 'native'; selected: boolean }
  | { kind: 'service'; serviceId: string; isDefault: boolean; status: SearchServiceStatus | string; selected: boolean }
  | { kind: 'add' };

/**
 * Rows of the "Search method" page: when native web search is available, the first row is "Built-in"; then the selectable services (storage order), with the default service marked "Your default search service",
 * the other rows' sub-line uses the state from searchServiceRowState; the last row is "Add search service".
 * Selection: native-capable -> the current service when method = external, otherwise "Built-in"; not native-capable -> the current service when external is on, nothing selected when it is off.
 */
export function searchSourcePickerItems({
  nativeCapable,
  selectable = [],
  defaultServiceId = null,
  method = 'default',
  serviceId = null,
}: {
  nativeCapable: boolean;
  selectable?: ReadonlyArray<SelectableSearchService>;
  defaultServiceId?: string | null;
  method?: SearchSourceMethod;
  serviceId?: string | null;
}): SearchSourcePickerItem[] {
  const items: SearchSourcePickerItem[] = [];
  const external = method === 'external';
  if (nativeCapable) items.push({ kind: 'native', selected: !external });
  for (const s of selectable) {
    items.push({ kind: 'service', serviceId: s.id, isDefault: s.id === defaultServiceId, status: s.status, selected: external && s.id === serviceId });
  }
  items.push({ kind: 'add' });
  return items;
}

export type WebSearchCardKey =
  | 'card.sourceLine'
  | 'card.sourceLineNative'
  | 'card.useService'
  | 'card.offUseService'
  | 'card.changeService'
  | 'card.presearchNotice'
  | 'card.fallbackNotice'
  | 'card.reuseStatus'
  | 'card.reuseDetail'
  | 'card.oneTap'
  | 'card.armHint'
  | 'card.cannotSearch'
  | 'card.addService'
  | 'card.supportedModels'
  /** Abnormal state of the current service (reuses the settings page row-state copy). */
  | 'row.needsKey'
  | 'row.hostChanged'
  | 'row.connectionMissing'
  | 'row.catalogUnavailable';

export interface WebSearchCardText {
  key: WebSearchCardKey;
  args: Record<string, string | null>;
}

export interface WebSearchCardActionText extends WebSearchCardText {
  action: WebRouteAction;
}

export type WebSearchCardPresentation =
  | { existing: true }
  | {
      existing: false;
      toggle: boolean;
      status: WebSearchCardText | null;
      /** Explanations under the status row, all shown in order. */
      notes: WebSearchCardText[];
      link: WebSearchCardActionText | null;
      cta: WebSearchCardActionText | null;
      secondary: WebSearchCardActionText | null;
    };

export type WebSearchCardSource = { kind: 'native' } | { kind: 'service'; name: string; status?: SearchServiceStatus | string | null };

const CARD_ROWS: ReadonlySet<WebRouteRow> = new Set<WebRouteRow>([
  'toggle_with_source_picker',
  'toggle_external',
  'toggle_external_presearch_notice',
  'one_tap_reuse_connection_key',
  'cannot_search',
]);

const STATUS_NOTE: Readonly<Record<string, WebSearchCardKey>> = Object.freeze({
  needs_key: 'row.needsKey',
  host_changed: 'row.hostChanged',
  connection_missing: 'row.connectionMissing',
  catalog_unavailable: 'row.catalogUnavailable',
});

/**
 * How the web card is drawn: takes the output of resolveWebSearchRoute and the name to show on this card, and outputs semantic copy keys (mapped through the l10n registry).
 * `existing: true` = the existing form, rendered as before and left untouched. The switch state of toggle_with_source_picker keeps the native ladder copy (status = null); only a sub-line is added.
 * notes are all shown in order and never displace one another: fallback notice -> current service's abnormal state -> search-before-answering per message -> off explanation -> one-tap enable explanation.
 * When native capability is not explicitly unavailable, the two no-service row states keep the existing copy (status = null).
 */
export function webSearchCardPresentation({
  route,
  nativeWeb = 'unavailable',
  webOn = false,
  source = null,
  oneTapServiceName = null,
  notice = null,
  armHint = false,
}: {
  route: Pick<WebRoute, 'row'>;
  nativeWeb?: NativeWebState;
  webOn?: boolean;
  source?: WebSearchCardSource | null;
  oneTapServiceName?: string | null;
  notice?: { fromName: string } | null;
  armHint?: boolean;
}): WebSearchCardPresentation {
  if (!CARD_ROWS.has(route.row)) return { existing: true };
  const usesService = source?.kind === 'service';
  const name = source?.kind === 'service' ? source.name : null;
  const out = {
    existing: false as const,
    toggle: false,
    status: null as WebSearchCardText | null,
    notes: [] as WebSearchCardText[],
    link: null as WebSearchCardActionText | null,
    cta: null as WebSearchCardActionText | null,
    secondary: null as WebSearchCardActionText | null,
  };
  if (notice) out.notes.push({ key: 'card.fallbackNotice', args: { from: notice.fromName } });
  const statusNote = source?.kind === 'service' && source.status ? STATUS_NOTE[source.status] ?? null : null;
  switch (route.row) {
    case 'toggle_with_source_picker':
      out.toggle = true;
      out.link = usesService
        ? { key: 'card.sourceLine', args: { name }, action: 'pick_source' }
        : { key: 'card.sourceLineNative', args: {}, action: 'pick_source' };
      if (statusNote) out.notes.push({ key: statusNote, args: {} });
      break;
    case 'toggle_external':
    case 'toggle_external_presearch_notice':
      out.toggle = true;
      out.status = webOn ? { key: 'card.useService', args: { name } } : { key: 'card.offUseService', args: { name } };
      out.link = { key: 'card.changeService', args: {}, action: 'pick_source' };
      if (statusNote) out.notes.push({ key: statusNote, args: {} });
      if (route.row === 'toggle_external_presearch_notice') out.notes.push({ key: 'card.presearchNotice', args: {} });
      if (armHint) out.notes.push({ key: 'card.armHint', args: { name } });
      break;
    case 'one_tap_reuse_connection_key':
      if (nativeWeb === 'unavailable') out.status = { key: 'card.reuseStatus', args: { name: oneTapServiceName } };
      else out.notes.push({ key: 'card.reuseDetail', args: { name: oneTapServiceName } });
      out.cta = { key: 'card.oneTap', args: {}, action: 'one_tap_enable' };
      break;
    case 'cannot_search':
      out.status = nativeWeb === 'unavailable' ? { key: 'card.cannotSearch', args: {} } : null;
      out.cta = { key: 'card.addService', args: {}, action: 'add_search_service' };
      out.secondary = { key: 'card.supportedModels', args: {}, action: 'open_supported_models' };
      break;
    default:
      break;
  }
  return out;
}

// ───────────── Single combined entry: panel, send and chip preview all call only this ─────────────

/** Relay web status (web-probe presentation statusId, or local_engine / protocol_undecided). */
export type RelayWebStatus =
  | 'web_probe_searched'
  | 'web_user_on'
  | 'web_probe_rejected'
  | 'web_probe_silent'
  | 'web_probe_unverified'
  | 'web_probe_untested'
  | 'web_user_off'
  | 'local_engine'
  | 'protocol_undecided';

const RELAY_STATUS_TO_RECORD: Readonly<Record<RelayWebStatus, RelayWebRecord>> = Object.freeze({
  web_probe_searched: 'searched',
  web_user_on: 'supported',
  web_probe_rejected: 'rejected',
  web_probe_silent: 'silent',
  web_probe_unverified: 'untested',
  web_probe_untested: 'template_only',
  web_user_off: 'user_override_off',
  local_engine: 'local_engine',
  protocol_undecided: 'protocol_undecided',
});

/** Recipe web control: auto_available / unavailable / none (no recipe or not loaded) / custom_only (needs your own configuration). */
export type RecipeWebState = 'auto_available' | 'unavailable' | 'none' | 'custom_only';

/** This client's facts after normalization on each client (only these go into the combined entry). */
export interface WebSearchFacts {
  form: WebRouteForm;
  recipeWeb?: RecipeWebState;
  nativeRejected?: boolean;
  relayStatus?: RelayWebStatus;
  managedWebAvailable?: boolean;
  toolCall?: ToolCallSupport;
}

/**
 * This client's facts -> nativeWeb for resolveWebSearchRoute (BYOK / subscription Codex).
 * Native withdrawn or tier rejected takes priority; custom_only and none are both unknown, so existing copy is not rewritten.
 */
function nativeWebOf({ recipeWeb, nativeRejected }: Pick<WebSearchFacts, 'recipeWeb' | 'nativeRejected'>): NativeWebState {
  if (nativeRejected === true) return 'withdrawn_or_rejected';
  if (recipeWeb === 'auto_available') return 'available';
  if (recipeWeb === 'unavailable') return 'unavailable';
  return 'unknown';
}

const STATE_TOGGLE_ROWS: ReadonlySet<WebRouteRow> = new Set<WebRouteRow>(['toggle_with_source_picker', 'toggle_external', 'toggle_external_presearch_notice']);
const STATE_EXTERNAL_ROWS: ReadonlySet<WebRouteRow> = new Set<WebRouteRow>(['toggle_external', 'toggle_external_presearch_notice']);

export type WebSearchShapeMode = 'existing' | 'existing_with_actions' | 'search_notice' | 'toggle_with_source';

export interface WebSearchStateService {
  id: string;
  /** Already passed through searchServiceDisplayName. */
  name: string;
  status: SearchServiceStatus | string;
}

export interface WebSearchStateInput {
  facts: WebSearchFacts;
  /** Whether a conversation-level preference can be written for this conversation (a runtime identity exists); one definition shared by panel, send and chip. */
  panelWritable?: boolean;
  /** Conversation web search (CapabilityWebPreference ladder). */
  webOn?: boolean;
  modelKey: string;
  currentProviderKind?: string | null;
  services?: ReadonlyArray<WebSearchStateService>;
  defaultServiceId?: string | null;
  /** Value of conversationSource; for a new conversation = the in-memory value. */
  stored?: unknown;
  oneTapTarget?: OneTapTarget | null;
  oneTapServiceName?: string | null;
}

export interface WebSearchState {
  nativeWeb: NativeWebState | null;
  route: WebRoute;
  source: ResolvedSearchSource;
  shapeMode: WebSearchShapeMode;
  card: WebSearchCardPresentation;
  pickerItems: SearchSourcePickerItem[];
  /** Switch shows on. */
  toggleOn: boolean;
  /** Whether the input box web chip is lit; null = use the pre-change liveness. */
  chipLit: boolean | null;
  /** external: on = pick_service, off = disarm, neither writes conversation web search; conversation_web: writes conversation web search; null: not a new-style switch. */
  toggleControls: 'external' | 'conversation_web' | null;
  /** Conversation web search is on, but external is not yet switched on for this model. */
  armHint: boolean;
  /** This turn uses external: native / relay web fields are stripped from the request; when false, outbound behavior is exactly as before the change. */
  nativeFieldsSuppressed: boolean;
  /** Whether, after one-tap enable succeeds, external can be recorded as on (not recorded when the panel cannot persist). */
  oneTapArms: boolean;
}

/**
 * The single combined entry for the web card and this turn's web route. Each client only normalizes its own facts into facts; everything else is decided by this function.
 * Switch semantics: for an external row (a model that cannot search natively) the switch = whether external is on for this conversation x model, independent of conversation web search;
 * for a native-capable model (the "Search method" row) the switch = conversation web search (the existing ladder).
 */
export function resolveWebSearchState(input: WebSearchStateInput): WebSearchState {
  const { facts, panelWritable = true, webOn = false, modelKey, services = [], defaultServiceId = null, stored = null } = input;
  const selectable = services.filter((s) => searchServiceSelectable(s.status));
  const resolved = resolveSearchSource({ stored, modelKey, selectable: selectable.map((s) => ({ id: s.id, status: s.status })), defaultServiceId });
  // Panel cannot persist: per-conversation choices do not take effect
  const source: ResolvedSearchSource = panelWritable ? resolved : { ...resolved, method: 'default' };
  const nativeWeb: NativeWebState | null = facts.form === 'byok' || facts.form === 'subscription_codex'
    ? nativeWebOf(facts)
    : facts.form === 'managed' ? (facts.managedWebAvailable === true ? 'available' : 'unavailable') : null;
  const routeInput: WebRouteInput = {
    form: facts.form,
    externalServices: selectable.length,
    reusableConnection: input.oneTapTarget != null,
    toolCall: facts.toolCall ?? 'unknown',
    webOn: webOn === true,
    method: source.method,
  };
  if (nativeWeb) routeInput.nativeWeb = nativeWeb;
  if (facts.form === 'relay') {
    const record = facts.relayStatus ? RELAY_STATUS_TO_RECORD[facts.relayStatus] : undefined;
    if (!record) throw new Error(`unknown relayStatus: ${String(facts.relayStatus)}`);
    routeInput.relayWebRecord = record;
  }
  // First determine which kind of row this is, then decide which state the switch reads
  const probe = resolveWebSearchRoute({ ...routeInput, webOn: true });
  const externalRow = STATE_EXTERNAL_ROWS.has(probe.row);
  const effectiveOn = externalRow ? source.method === 'external' : routeInput.webOn === true;
  const route = resolveWebSearchRoute({ ...routeInput, webOn: effectiveOn });
  const armHint = externalRow && routeInput.webOn === true && !effectiveOn;
  const current = selectable.find((s) => s.id === source.serviceId) ?? null;
  const usesService = externalRow || (route.row === 'toggle_with_source_picker' && source.method === 'external');
  const card = webSearchCardPresentation({
    route,
    nativeWeb: nativeWeb ?? 'unavailable',
    webOn: effectiveOn,
    source: usesService ? { kind: 'service', name: current?.name || source.serviceId || '', status: current?.status ?? null } : { kind: 'native' },
    oneTapServiceName: input.oneTapServiceName ?? null,
    notice: source.notice,
    armHint,
  });
  let shapeMode: WebSearchShapeMode;
  if (card.existing) shapeMode = 'existing';
  else if (STATE_TOGGLE_ROWS.has(route.row)) shapeMode = panelWritable ? 'toggle_with_source' : 'existing';
  else shapeMode = card.status === null ? 'existing_with_actions' : 'search_notice';
  const pickerItems = STATE_TOGGLE_ROWS.has(route.row)
    ? searchSourcePickerItems({
      nativeCapable: route.row === 'toggle_with_source_picker',
      selectable: selectable.map((s) => ({ id: s.id, status: s.status })),
      defaultServiceId,
      method: source.method,
      serviceId: source.serviceId,
    })
    : [];
  const toggleOn = STATE_TOGGLE_ROWS.has(route.row) && route.path !== 'none';
  return {
    nativeWeb,
    route,
    source,
    shapeMode,
    card,
    pickerItems,
    toggleOn,
    // Input box web chip: in the new form = toggleOn; in the pre-change form (including a read-only panel) null = judged by the pre-change liveness
    chipLit: shapeMode === 'toggle_with_source' ? toggleOn : null,
    toggleControls: externalRow ? 'external' : route.row === 'toggle_with_source_picker' ? 'conversation_web' : null,
    armHint,
    nativeFieldsSuppressed: route.path === 'external_tool' || route.path === 'external_presearch',
    oneTapArms: panelWritable === true,
  };
}

export type SearchFallbackReason = 'no_tool_continuation' | 'thinking_tools_unsupported' | 'thinking_no_continuation' | 'tools_rejected';

export interface SearchTurnPath {
  path: WebSearchPath;
  fallbackReason: SearchFallbackReason | null;
  noticeOnce: boolean;
  requestHasNativeSearchFields: boolean;
  requestHasWebSearchTool: boolean;
}

/** How this turn is actually sent: whether tool calling switches to pre-search, and which web field appears in the request. */
export function resolveSearchTurnPath(input: {
  path: WebSearchPath;
  hostMaxSteps?: number;
  thinkingOn?: boolean;
  thinkingWithTools?: string;
  continuationStateAvailable?: boolean;
  upstreamRejectedTools?: boolean;
}): SearchTurnPath {
  const path = input.path;
  if (path !== 'external_tool' && path !== 'external_presearch') {
    return {
      path,
      fallbackReason: null,
      noticeOnce: false,
      requestHasNativeSearchFields: path === 'native' || path === 'relay_fragment',
      requestHasWebSearchTool: false,
    };
  }
  let resolved: WebSearchPath = path;
  let fallbackReason: SearchFallbackReason | null = null;
  if (path === 'external_tool') {
    if (input.hostMaxSteps === 0) fallbackReason = 'no_tool_continuation';
    else if (input.thinkingOn === true && input.thinkingWithTools === 'presearch') fallbackReason = 'thinking_tools_unsupported';
    else if (input.thinkingOn === true && input.continuationStateAvailable === false) fallbackReason = 'thinking_no_continuation';
    else if (input.upstreamRejectedTools === true) fallbackReason = 'tools_rejected';
    if (fallbackReason) resolved = 'external_presearch';
  }
  return {
    path: resolved,
    fallbackReason,
    noticeOnce: fallbackReason === 'tools_rejected',
    requestHasNativeSearchFields: false,
    requestHasWebSearchTool: resolved === 'external_tool',
  };
}

export const SEARCH_CALL_LIMITS = Object.freeze({ maxSearchRequestsPerReply: 3, retryableStatuses: Object.freeze([408, 502, 503]) as readonly number[], maxRetriesPerCall: 1 });

/** Outcome of each request: HTTP status number, 'timeout', 'network'. */
export type SearchAttempt = number | string;

export interface PlannedSearchCall {
  leg: number;
  call: number;
  requests: number;
  outcome: string;
}

/**
 * Search calls within one reply: legs = [[call, ...], ...], call.attempts = the outcome of each request.
 * Only 408 / 502 / 503 are retried automatically once, and the retry counts toward the 3-request cap per reply; calls beyond the cap send no request and return cap_reached.
 */
export function planSearchCalls({ legs }: { legs: readonly (readonly { attempts?: readonly SearchAttempt[] }[])[] }): { requestsSent: number; calls: PlannedSearchCall[] } {
  const max = SEARCH_CALL_LIMITS.maxSearchRequestsPerReply;
  let sent = 0;
  const calls: PlannedSearchCall[] = [];
  legs.forEach((leg, legIndex) => {
    leg.forEach((call, callIndex) => {
      const attempts = call.attempts ?? [];
      if (sent >= max) {
        calls.push({ leg: legIndex, call: callIndex, requests: 0, outcome: 'cap_reached' });
        return;
      }
      let requests = 0;
      let last: SearchAttempt | null = null;
      for (let i = 0; i < attempts.length && i <= SEARCH_CALL_LIMITS.maxRetriesPerCall; i += 1) {
        if (sent >= max) break;
        requests += 1;
        sent += 1;
        last = attempts[i];
        const retryable = typeof last === 'number' && SEARCH_CALL_LIMITS.retryableStatuses.includes(last);
        if (!retryable) break;
      }
      calls.push({
        leg: legIndex,
        call: callIndex,
        requests,
        outcome: typeof last === 'number' && last >= 200 && last < 300 ? 'response' : last === null ? 'cap_reached' : String(last),
      });
    });
  });
  return { requestsSent: sent, calls };
}

export type SearchRegenerateAction = 'send' | 'regenerate' | 'edit_resend' | 're_search';

/** Regenerate / edit-and-resend: reuses that message's previous results by default; only when the user taps "Search again" does it search again. */
export function regenerateSearchPolicy({ action, previousResultsPersisted }: { action: SearchRegenerateAction | string; previousResultsPersisted: boolean }): {
  reusePrevious: boolean;
  newSearchesAllowed: boolean;
} {
  if (action === 're_search') return { reusePrevious: false, newSearchesAllowed: true };
  if ((action === 'regenerate' || action === 'edit_resend') && previousResultsPersisted) return { reusePrevious: true, newSearchesAllowed: false };
  return { reusePrevious: false, newSearchesAllowed: true };
}
