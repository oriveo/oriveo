// External search service: UI rules for the settings page. The UI renders purely from these functions' results and never decides on its own.
// Contract fixture: search-settings.v1.json in the shared search-contracts directory;
// reference implementation: scripts/lib/search-settings.mjs (same names and semantics on every client).

import { presetHostCheck, regionForConnection, type CatalogEntry } from './search-catalog';
import { keyBindingOrigin } from './search-transport';

/** Selectable values and default for "Advanced > Results per request" on the detail page. */
export const RESULT_COUNT_CHOICES: readonly number[] = Object.freeze([3, 5, 8, 10]);
export const RESULT_COUNT_DEFAULT = 5;

/** Official doc opened by "View setup instructions" when SearXNG has JSON format disabled (not a search endpoint). */
export const SEARXNG_SETUP_GUIDE_URL = 'https://docs.searxng.org/admin/settings/settings_search.html';

const CURRENCY_PREFIX: Readonly<Record<string, string>> = Object.freeze({ CNY: '¥', USD: '$' });

/** Price amount (a string in the catalog) with a currency prefix; returns null for an unknown currency (no price shown). */
function priceLabel(currency: unknown, amount: unknown): string | null {
  const p = typeof currency === 'string' ? CURRENCY_PREFIX[currency] : undefined;
  return p && typeof amount === 'string' ? `${p}${amount}` : null;
}

type PriceEntry = Pick<CatalogEntry, 'regions'>;

export interface SearchPriceFree {
  kind: 'monthly_credits' | 'monthly_usd';
  count: number | null;
  amountLabel: string | null;
  cardRequired: boolean;
}

export interface SearchPriceSummary {
  regionId: string | null;
  price: { unit: string; label: string } | null;
  billing: string | null;
  free: SearchPriceFree | null;
  otherRegionCount: number;
}

interface RegionPricing {
  unit?: string;
  amount?: unknown;
  currency?: unknown;
  billing?: string;
  free?: { kind?: string; amount?: unknown; cardRequired?: unknown } | null;
}

/**
 * Price summary of a site (add sheet subtitle, connect page title sub-line, detail page price section).
 * `price` null means no unit price is shown (non-currency pricing such as CREDIT shows only the free quota);
 * `free.amountLabel` is a currency quota (with prefix), `free.count` is an integer quota (the UI adds thousands separators for the current language).
 * When `otherRegionCount` > 0 the add sheet appends "Also available on the international site". If the site is not found the first site is used.
 */
export function searchPriceSummary(entry: PriceEntry | null | undefined, regionId: string | null | undefined): SearchPriceSummary {
  const regions = entry?.regions ?? [];
  const region = regions.find((r) => r.id === regionId) ?? regions[0];
  if (!region) return { regionId: null, price: null, billing: null, free: null, otherRegionCount: 0 };
  const p = (region.pricing ?? {}) as RegionPricing;
  const label = priceLabel(p.currency, p.amount);
  const price = label ? { unit: String(p.unit), label } : null;
  let free: SearchPriceFree | null = null;
  if (p.free?.kind === 'monthly_credits' && Number.isInteger(p.free.amount)) {
    free = { kind: 'monthly_credits', count: p.free.amount as number, amountLabel: null, cardRequired: p.free.cardRequired === true };
  } else if (p.free?.kind === 'monthly_usd') {
    const fl = priceLabel('USD', p.free.amount);
    if (fl) free = { kind: 'monthly_usd', count: null, amountLabel: fl, cardRequired: p.free.cardRequired === true };
  }
  return { regionId: region.id, price, billing: p.billing ?? null, free, otherRegionCount: regions.length - 1 };
}

export interface SearchSheetConnection {
  id: string;
  name: string;
  providerKind: string;
  baseUrl: string | null;
}

export interface SearchSheetService {
  id: string;
  kind: 'preset' | 'custom';
  serviceId?: string;
}

export interface SearchAddSheetRow {
  serviceId: string;
  regionId: string | null;
  connectionRef: string | null;
  connectionName: string | null;
  addedServiceRef: string | null;
}

export type SearchAddSheetSectionId = 'reuse' | 'domestic' | 'overseas';

export interface SearchAddSheet {
  presets: 'available' | 'unavailable';
  sections: Array<{ id: SearchAddSheetSectionId; rows: SearchAddSheetRow[] }>;
  custom: true;
}

/**
 * Grouping of the add sheet.
 * An entry with `reuse` for which a connection exists with the same providerKind and a host that resolves to a site (regionForConnection) -> goes into "Use your existing key directly",
 * taking the first such connection, with the site chosen by the connection; the rest go into domestic / overseas by `group`, with the first site. Each provider appears once; empty groups are omitted.
 * Presets that were already added (same serviceId) are still listed, and `addedServiceRef` points to the saved service.
 * Catalog unavailable: no preset groups, `presets: 'unavailable'`; the "Custom" group is always present.
 */
export function searchAddSheetSections({
  catalogAvailable,
  entries = [],
  connections = [],
  services = [],
}: {
  catalogAvailable: boolean;
  entries?: ReadonlyArray<Pick<CatalogEntry, 'id' | 'group' | 'regions' | 'reuse'>>;
  connections?: readonly SearchSheetConnection[];
  services?: readonly SearchSheetService[];
}): SearchAddSheet {
  if (!catalogAvailable) return { presets: 'unavailable', sections: [], custom: true };
  const buckets: Record<SearchAddSheetSectionId, SearchAddSheetRow[]> = { reuse: [], domestic: [], overseas: [] };
  for (const e of entries) {
    const added = services.find((s) => s.kind === 'preset' && s.serviceId === e.id)?.id ?? null;
    let conn: SearchSheetConnection | null = null;
    let region: string | null = null;
    if (e.reuse) {
      for (const c of connections) {
        if (c.providerKind !== e.reuse.providerKind) continue;
        const r = regionForConnection(e, c.baseUrl);
        if (r) {
          conn = c;
          region = r;
          break;
        }
      }
    }
    const row: SearchAddSheetRow = {
      serviceId: e.id,
      regionId: region ?? e.regions?.[0]?.id ?? null,
      connectionRef: conn?.id ?? null,
      connectionName: conn?.name ?? null,
      addedServiceRef: added,
    };
    if (conn) buckets.reuse.push(row);
    else if (e.group === 'domestic' || e.group === 'overseas') buckets[e.group].push(row);
  }
  const sections = (['reuse', 'domestic', 'overseas'] as const)
    .filter((k) => buckets[k].length > 0)
    .map((id) => ({ id, rows: buckets[id] }));
  return { presets: 'available', sections, custom: true };
}

export type SearchServiceStatus = 'ready' | 'catalog_unavailable' | 'withdrawn' | 'host_changed' | 'connection_missing' | 'needs_key';
export type SearchKeySource = 'connection' | 'own' | 'none';

export interface SearchRowServiceInput {
  kind: 'preset' | 'custom';
  serviceId?: string;
  regionId?: string;
  boundHost?: string;
  keySource: SearchKeySource;
  connectionRef?: string | null;
  hasKey: boolean;
}

export interface SearchServiceRowState {
  status: SearchServiceStatus;
  label: 'preset' | 'custom';
  keySource: SearchKeySource;
  connectionName: string | null;
}

/**
 * State shown on the "My search services" list rows and at the top of the detail page.
 * Evaluation order for presets: catalog unavailable -> catalog_unavailable; withdrawn / not in the catalog -> withdrawn; host changed -> host_changed;
 * reused connection gone -> connection_missing; own key gone -> needs_key; otherwise ready. A custom service is only ever ready (key optional).
 */
export function searchServiceRowState({
  service,
  catalogAvailable,
  entry = null,
  withdrawn = false,
  connections = [],
}: {
  service: SearchRowServiceInput;
  catalogAvailable: boolean;
  entry?: Pick<CatalogEntry, 'tombstone' | 'regions'> | null;
  withdrawn?: boolean;
  connections?: ReadonlyArray<{ id: string; name: string }>;
}): SearchServiceRowState {
  const custom = service.kind === 'custom';
  const conn = service.keySource === 'connection' ? connections.find((c) => c.id === service.connectionRef) ?? null : null;
  const base = { label: custom ? ('custom' as const) : ('preset' as const), keySource: service.keySource, connectionName: conn?.name ?? null };
  if (custom) return { status: 'ready', ...base, keySource: service.hasKey ? 'own' : 'none' };
  if (!catalogAvailable) return { status: 'catalog_unavailable', ...base };
  if (withdrawn || !entry) return { status: 'withdrawn', ...base };
  if (presetHostCheck({ boundHost: service.boundHost ?? '', entry, regionId: service.regionId ?? '', withdrawn }) === 'host_changed') {
    return { status: 'host_changed', ...base };
  }
  if (service.keySource === 'connection' && !conn) return { status: 'connection_missing', ...base };
  if (service.keySource === 'own' && !service.hasKey) return { status: 'needs_key', ...base };
  return { status: 'ready', ...base };
}

/**
 * Default service: use the stored default id if it is still in the list; otherwise (never set, or deleted) the earliest in storage order; empty list = null.
 * The first service added automatically becomes the default; later additions do not change it; deleting the default falls back to the earliest remaining service.
 */
export function resolveDefaultSearchService({
  serviceIds = [],
  storedDefault = null,
}: {
  serviceIds?: readonly string[];
  storedDefault?: string | null;
}): string | null {
  if (storedDefault && serviceIds.includes(storedDefault)) return storedDefault;
  return serviceIds[0] ?? null;
}

export type SearchConsentLineKey = 'customUnverified' | 'sendsQuery' | 'sendsQueryCustom' | 'billing' | 'billingCustom' | 'webForwarded' | 'testOnce' | 'testOnceSave';

export interface SearchConsentLine {
  key: SearchConsentLineKey;
  args: Record<string, string | null>;
}

/**
 * Sentences of the consent page "Confirm before enabling" (contract section 16). `key` is the second half of the copy key `consent.*`.
 * A custom service opens with "cannot be verified"; Web adds a sentence "forwarded through the Oriveo web service"; presets end with "test with this key", custom services end with "saved only after the test passes".
 */
export function searchConsentLines({
  kind,
  platform,
  serviceName = null,
  host = null,
}: {
  kind: 'preset' | 'custom';
  platform: 'ios' | 'android' | 'web';
  serviceName?: string | null;
  host?: string | null;
}): SearchConsentLine[] {
  const custom = kind === 'custom';
  const lines: SearchConsentLine[] = [];
  if (custom) lines.push({ key: 'customUnverified', args: { host } });
  lines.push(custom ? { key: 'sendsQueryCustom', args: {} } : { key: 'sendsQuery', args: { name: serviceName } });
  lines.push(custom ? { key: 'billingCustom', args: {} } : { key: 'billing', args: { name: serviceName } });
  if (platform === 'web') lines.push({ key: 'webForwarded', args: {} });
  lines.push(custom ? { key: 'testOnceSave', args: {} } : { key: 'testOnce', args: {} });
  return lines;
}

export type SearchTestAction = 'update_key' | 'top_up' | 'check_settings' | 'view_setup_guide' | 'reconfirm' | 'retry' | 'none';

// Action after a failed test on the settings page: the switch-service kind has nowhere to go on the settings page, so it falls back to "Retry"; withdrawn has no action.
const TEST_ACTIONS: Readonly<Record<string, SearchTestAction>> = Object.freeze({
  update_key: 'update_key',
  top_up: 'top_up',
  check_settings: 'check_settings',
  view_setup_guide: 'view_setup_guide',
  reconfirm: 'reconfirm',
  retry: 'retry',
  retry_later: 'retry',
  switch_service: 'retry',
});

export type SearchTestOutcome =
  | { ok: true; count: number; latencyMs: number }
  | { ok: false; error: { errorClass?: string | null; card?: { headline?: string; primaryAction?: string } | null } | null };

export type SearchTestPresentation =
  | { state: 'passed'; count: number; latencyTenths: number }
  | { state: 'failed'; errorClass: string | null; headline: string; action: SearchTestAction };

/**
 * How a test search result is displayed (connect page, custom consent page, detail page).
 * Pass: 0 results also counts as a pass; the duration is rounded to 0.1 s as the integer `latencyTenths`, which the UI formats to one decimal in the current language.
 * Failure: `headline` uses the error card headline key, `action` is the settings page action; a withdrawn service has no action (`none`).
 */
export function searchTestPresentation({ outcome }: { outcome: SearchTestOutcome | null | undefined }): SearchTestPresentation {
  if (outcome?.ok === true) {
    return { state: 'passed', count: outcome.count, latencyTenths: Math.round(Math.max(0, outcome.latencyMs) / 100) };
  }
  const error = outcome && outcome.ok === false ? outcome.error : null;
  const card = error?.card ?? {};
  const action: SearchTestAction = error?.errorClass === 'service_withdrawn' ? 'none' : TEST_ACTIONS[card.primaryAction ?? ''] ?? 'retry';
  return { state: 'failed', errorClass: error?.errorClass ?? null, headline: card.headline ?? 'service_error', action };
}

export type CustomFormField =
  | 'name' | 'address' | 'protocol' | 'mapping' | 'method' | 'auth' | 'query' | 'count'
  | 'params' | 'results' | 'title' | 'url' | 'snippet' | 'site' | 'date' | 'key';

// Validation error code -> form field and hint key (`form.*`). Only the first one is shown for a field.
const FIELD_OF: Readonly<Record<string, readonly [CustomFormField, string]>> = Object.freeze({
  name_empty: ['name', 'nameEmpty'],
  name_too_long: ['name', 'nameTooLong'],
  address_invalid: ['address', 'addressInvalid'],
  scheme_not_allowed: ['address', 'addressInvalid'],
  address_has_query: ['address', 'addressInvalid'],
  http_public_not_allowed: ['address', 'httpPublic'],
  http_not_allowed_on_web: ['address', 'httpOnWeb'],
  private_address_on_web: ['address', 'privateOnWeb'],
  port_not_allowed_on_web: ['address', 'portOnWeb'],
  address_unresolved: ['address', 'addressUnresolved'],
  protocol_invalid: ['protocol', 'protocolInvalid'],
  preset_unavailable: ['protocol', 'presetUnavailable'],
  mapping_missing: ['mapping', 'mappingIncomplete'],
  method_invalid: ['method', 'mappingIncomplete'],
  auth_invalid: ['auth', 'mappingIncomplete'],
  header_name_invalid: ['auth', 'headerName'],
  query_field_invalid: ['query', 'pathInvalid'],
  count_field_invalid: ['count', 'pathInvalid'],
  get_has_body: ['method', 'getBody'],
  too_many_static_params: ['params', 'tooManyParams'],
  static_key_invalid: ['params', 'pathInvalid'],
  static_value_invalid: ['params', 'paramValue'],
  template_rejected: ['params', 'template'],
  results_path_invalid: ['results', 'pathInvalid'],
  title_path_invalid: ['title', 'pathInvalid'],
  url_path_invalid: ['url', 'pathInvalid'],
  snippet_path_invalid: ['snippet', 'pathInvalid'],
  site_path_invalid: ['site', 'pathInvalid'],
  date_path_invalid: ['date', 'pathInvalid'],
  path_conflict: ['query', 'pathConflict'],
  key_empty: ['key', 'keyEmpty'],
  key_invalid: ['key', 'keyInvalid'],
});

export interface CustomFormFieldErrors {
  fields: Partial<Record<CustomFormField, string>>;
  warnings: { address?: 'cleartextLan' };
  blocking: boolean;
}

/**
 * Field hints when "Continue" is tapped on the custom form (validation runs only on "Continue" / "Save"; editing a field clears that field's hint).
 * Input: validation error codes (errors of validateCustomSearchService, plus the error of normalizeSearchKey when a key was entered) and warnings.
 */
export function customFormFieldErrors({
  errors = [],
  warnings = [],
}: {
  errors?: readonly string[];
  warnings?: readonly string[];
}): CustomFormFieldErrors {
  const fields: Partial<Record<CustomFormField, string>> = {};
  for (const code of errors) {
    const hit = FIELD_OF[code];
    if (!hit) throw new Error(`unmapped form error ${code}`);
    if (!(hit[0] in fields)) fields[hit[0]] = hit[1];
  }
  const w: CustomFormFieldErrors['warnings'] = {};
  if (warnings.includes('cleartext_lan')) w.address = 'cleartextLan';
  return { fields, warnings: w, blocking: errors.length > 0 };
}

/** Stored results per request: anything not among the selectable values (missing, old data, hand-edited) falls back to the default 5. */
export function searchResultCount(stored: unknown): number {
  return typeof stored === 'number' && RESULT_COUNT_CHOICES.includes(stored) ? stored : RESULT_COUNT_DEFAULT;
}

/**
 * Service display name: a custom service uses its own name; a preset falls back from the displayName of that entry in the adopted catalog -> the name saved at save time -> serviceId.
 */
export function searchServiceDisplayName({
  kind,
  name = null,
  serviceId = null,
  catalogDisplayName = null,
}: {
  kind: 'preset' | 'custom';
  name?: string | null;
  serviceId?: string | null;
  catalogDisplayName?: string | null;
}): string {
  if (kind === 'custom') return name ?? '';
  return catalogDisplayName || name || serviceId || '';
}

export type MigratedDefault = { set: true; id: string } | { set: false };

/**
 * Default id the account partition should store after a guest -> account migration: when the account had no services, carry over the default in effect for the guest (and only if it was actually migrated);
 * when the account already has services, leave the account's default alone.
 */
export function migratedDefaultSearchService({
  accountServiceIds = [],
  guestServiceIds = [],
  guestStoredDefault = null,
  migratedIds = [],
}: {
  accountServiceIds?: readonly string[];
  guestServiceIds?: readonly string[];
  guestStoredDefault?: string | null;
  migratedIds?: readonly string[];
}): MigratedDefault {
  if (accountServiceIds.length > 0) return { set: false };
  const guestDefault = resolveDefaultSearchService({ serviceIds: guestServiceIds, storedDefault: guestStoredDefault });
  if (guestDefault && migratedIds.includes(guestDefault)) return { set: true, id: guestDefault };
  return { set: false };
}

export interface CustomServiceEditSide {
  name?: string | null;
  address?: string | null;
  protocol?: string | null;
  mapping?: unknown;
  presetId?: string | null;
  regionId?: string | null;
}

export interface CustomServiceEditPlan {
  mode: 'save' | 'test_then_save';
  clearsKey: boolean;
  showKeyField: boolean;
  resnapshot: boolean;
  requirePreset: boolean;
}

/**
 * What to do when "Save" is tapped on a saved custom service.
 * Address source changed: clear the key, show the key field (the new key is tested together with the address in one test), test before saving;
 * address path, protocol, manual mapping or the "same as X" reference changed: test before saving, key kept; name changed only: save directly.
 * Same_as reference unchanged: keep the saved snapshot and do not require the preset to be available; reference changed (or switched to same_as): retake the snapshot from the new reference and require the preset to be available.
 */
export function customServiceEditPlan({ before, after }: { before: CustomServiceEditSide; after: CustomServiceEditSide }): CustomServiceEditPlan {
  const originChanged = keyBindingOrigin(before.address) !== keyBindingOrigin(after.address);
  const addressChanged = String(before.address ?? '').trim() !== String(after.address ?? '').trim();
  const protocolChanged = before.protocol !== after.protocol;
  const sameAs = after.protocol === 'same_as';
  const referenceChanged = sameAs && (protocolChanged || before.presetId !== after.presetId || (before.regionId ?? null) !== (after.regionId ?? null));
  const mappingChanged = after.protocol === 'manual' && JSON.stringify(before.mapping ?? null) !== JSON.stringify(after.mapping ?? null);
  const needsTest = addressChanged || protocolChanged || referenceChanged || mappingChanged;
  return {
    mode: needsTest ? 'test_then_save' : 'save',
    clearsKey: originChanged,
    showKeyField: originChanged,
    resnapshot: referenceChanged,
    requirePreset: referenceChanged,
  };
}
