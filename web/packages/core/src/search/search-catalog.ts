// External web search: canonical JSON, Ed25519 signature, entry validation and client adoption rules for the search-catalog/v1 catalog.
// Reference implementation: scripts/lib/search-catalog.mjs, ported function by function (browser + Node, no node:* dependency); Ed25519 goes through globalThis.crypto.subtle,
// so verifyCatalogSignature / acceptSearchCatalog return a Promise. Signing (signCatalog) lives only in the maintainer script and is not ported to clients.
// Same names on every client: canonicalCatalogJson / verifyCatalogSignature / acceptSearchCatalog.

import { ERROR_CLASSES, HARD_LIMITS, TRANSPORT_KIND, staticParamAllowed, type StaticParamValue, type TransportSpec } from './search-transport';

export const CATALOG_SCHEMA = 'search-catalog/v1';

/**
 * Canonical JSON (signature input): object keys in ascending UTF-16 code unit order, no whitespace, strings escaped as JSON (same as JSON.stringify);
 * numbers may only be safe integers (prices in the catalog are always strings), anything non-integer throws. Arrays keep their order.
 */
export function canonicalCatalogJson(value: unknown): string {
  if (value === null) return 'null';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') {
    if (!Number.isSafeInteger(value)) throw new Error(`non-integer number in catalog: ${value}`);
    return String(value);
  }
  if (typeof value === 'string') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalCatalogJson).join(',')}]`;
  if (typeof value === 'object') {
    const obj = value as Record<string, unknown>;
    // The default sort compares by UTF-16 code units, which is exactly the key order the contract requires
    const keys = Object.keys(obj).sort();
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalCatalogJson(obj[k])}`).join(',')}}`;
  }
  throw new Error(`unsupported value type ${typeof value}`);
}

function utf8(s: string): Uint8Array<ArrayBuffer> {
  return new TextEncoder().encode(s) as Uint8Array<ArrayBuffer>;
}

function base64Bytes(b64: string): Uint8Array<ArrayBuffer> {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) out[i] = bin.charCodeAt(i);
  return out;
}

function signingPayload(doc: Record<string, unknown>): Uint8Array<ArrayBuffer> {
  const { signature: _signature, ...rest } = doc;
  return utf8(canonicalCatalogJson(rest));
}

export interface CatalogSignature {
  alg: 'ed25519';
  keyId: string;
  value: string;
}

export type SignatureFailure = 'signature_missing' | 'signature_unknown_key' | 'signature_invalid';
export type SignatureVerdict = { ok: true; reason: null } | { ok: false; reason: SignatureFailure };

/** trustedKeys: { keyId: base64 of the raw 32-byte Ed25519 public key } (built into the client). */
export async function verifyCatalogSignature(doc: unknown, trustedKeys: Readonly<Record<string, string>>): Promise<SignatureVerdict> {
  const s = (doc as { signature?: Partial<CatalogSignature> } | null | undefined)?.signature;
  if (!s || s.alg !== 'ed25519' || typeof s.value !== 'string') return { ok: false, reason: 'signature_missing' };
  const key = typeof s.keyId === 'string' && Object.prototype.hasOwnProperty.call(trustedKeys, s.keyId) ? trustedKeys[s.keyId] : undefined;
  if (!key) return { ok: false, reason: 'signature_unknown_key' };
  let ok = false;
  try {
    const raw = base64Bytes(key);
    if (raw.length !== 32) throw new Error('ed25519 public key must be 32 bytes');
    const publicKey = await globalThis.crypto.subtle.importKey('raw', raw, { name: 'Ed25519' }, false, ['verify']);
    ok = await globalThis.crypto.subtle.verify({ name: 'Ed25519' }, publicKey, base64Bytes(s.value), signingPayload(doc as Record<string, unknown>));
  } catch {
    ok = false;
  }
  return ok ? { ok: true, reason: null } : { ok: false, reason: 'signature_invalid' };
}

const ID = /^[a-z][a-z0-9_]{1,31}$/;
const HOSTNAME = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;
const HTTPS = /^https:\/\/[^\s/?#]+/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const REGION_URL_KEYS = ['docs', 'pricing', 'keyHelp'] as const;

export interface CatalogRegion {
  id: string;
  host: string;
  static?: Record<string, StaticParamValue>;
  urls?: { docs?: string; pricing?: string; keyHelp?: string; [key: string]: unknown };
  [key: string]: unknown;
}

/** Catalog entry (shape after validation; unknown fields are kept but not read). */
export interface CatalogEntry {
  id: string;
  tombstone?: { at: string };
  displayName: string;
  group: 'domestic' | 'overseas';
  urls: { homepage: string; docs: string; terms: string; keyHelp: string };
  pricing: { sourceUrl: string; [key: string]: unknown };
  regions: CatalogRegion[];
  reuse?: { providerKind: string; regionByConnectionHost?: Record<string, string> };
  transport: TransportSpec & { kind: string; path: string; count?: TransportSpec['count'] & { max?: number } };
  limits: { timeoutSec: number };
  citationStorage: 'full' | 'urlTitleOnly';
  trust: { entity: string; evidence: string[]; reviewedAt: string };
  [key: string]: unknown;
}

export type EntrySkipReason = 'entry_invalid' | 'host_invalid' | 'static_param_not_allowed' | 'unsupported_transport' | 'transport_invalid' | 'trust_invalid';

// Entries come from the network, so every field is defended: the validation below reads them as "arbitrary JSON"
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Untrusted = any;

function validTransport(t: Untrusted): EntrySkipReason | null {
  if (!t || t.kind !== TRANSPORT_KIND) return 'unsupported_transport';
  if (!['GET', 'POST'].includes(t.method)) return 'transport_invalid';
  if (typeof t.path !== 'string' || !t.path.startsWith('/')) return 'transport_invalid';
  if (!['bearer', 'header'].includes(t.auth?.kind)) return 'transport_invalid';
  if (!t.query?.field || !['body', 'query'].includes(t.query.in)) return 'transport_invalid';
  if (!t.response?.results || !Array.isArray(t.response.url) || !Array.isArray(t.response.title)) return 'transport_invalid';
  for (const [k, v] of Object.entries(t.static?.params ?? {})) if (!staticParamAllowed(k, v)) return 'static_param_not_allowed';
  // Specific error rules: status 400-599, class name in the closed set, match only does string equality; a non-conforming one skips the whole entry so clients do not each invent their own fallback for unknown classes
  if (t.errors !== undefined) {
    if (!Array.isArray(t.errors)) return 'transport_invalid';
    for (const r of t.errors as Untrusted[]) {
      if (!r || typeof r !== 'object' || !Number.isSafeInteger(r.status) || r.status < 400 || r.status > 599) return 'transport_invalid';
      if (typeof r.class !== 'string' || !Object.prototype.hasOwnProperty.call(ERROR_CLASSES, r.class)) return 'transport_invalid';
      if (r.match !== undefined && r.match !== null && (typeof r.match !== 'object' || typeof r.match.path !== 'string' || !r.match.path || typeof r.match.equals !== 'string')) return 'transport_invalid';
    }
  }
  return null;
}

/** Single-entry validation: null = usable, otherwise the reason it is skipped (only this entry is skipped, the whole catalog is not rejected). */
export function validateCatalogEntry(e: Untrusted): EntrySkipReason | null {
  if (!e || typeof e !== 'object' || !ID.test(e.id ?? '')) return 'entry_invalid';
  if (e.tombstone) return typeof e.tombstone.at === 'string' && DATE.test(e.tombstone.at) ? null : 'entry_invalid';
  if (typeof e.displayName !== 'string' || !e.displayName) return 'entry_invalid';
  if (!['domestic', 'overseas'].includes(e.group)) return 'entry_invalid';
  for (const k of ['homepage', 'docs', 'terms', 'keyHelp']) if (!HTTPS.test(e.urls?.[k] ?? '')) return 'entry_invalid';
  if (!HTTPS.test(e.pricing?.sourceUrl ?? '')) return 'entry_invalid';
  if (!Array.isArray(e.regions) || e.regions.length === 0) return 'entry_invalid';
  for (const r of e.regions as Untrusted[]) {
    if (!ID.test(r?.id ?? '') || !HOSTNAME.test(r?.host ?? '')) return 'host_invalid';
    for (const [k, v] of Object.entries(r.static ?? {})) if (!staticParamAllowed(k, v)) return 'static_param_not_allowed';
    // Site-level links are optional; only known keys are validated and unknown keys are ignored (adding keys later must not make old clients skip the whole entry)
    if (r.urls !== undefined) {
      if (!r.urls || typeof r.urls !== 'object' || Array.isArray(r.urls)) return 'entry_invalid';
      for (const k of REGION_URL_KEYS) if (r.urls[k] !== undefined && !HTTPS.test(r.urls[k])) return 'entry_invalid';
    }
  }
  const tErr = validTransport(e.transport);
  if (tErr) return tErr;
  if (!Number.isInteger(e.limits?.timeoutSec) || e.limits.timeoutSec < 1) return 'entry_invalid';
  if (!['full', 'urlTitleOnly'].includes(e.citationStorage)) return 'entry_invalid';
  if (
    typeof e.trust?.entity !== 'string' ||
    !Array.isArray(e.trust.evidence) ||
    e.trust.evidence.length === 0 ||
    !e.trust.evidence.every((u: unknown) => typeof u === 'string' && HTTPS.test(u)) ||
    !DATE.test(e.trust.reviewedAt ?? '')
  )
    return 'trust_invalid';
  if (e.reuse) {
    if (typeof e.reuse.providerKind !== 'string') return 'entry_invalid';
    for (const [host, region] of Object.entries(e.reuse.regionByConnectionHost ?? {})) {
      if (!HOSTNAME.test(host) || !(e.regions as Untrusted[]).some((r) => r.id === region)) return 'entry_invalid';
    }
  }
  return null;
}

export interface ClampedLimits {
  timeoutSec: number;
  maxCount: number;
}

/** Client-side hard limits: however large the catalog is, it is truncated here. */
export function clampedLimits(e: Pick<CatalogEntry, 'limits' | 'transport'>): ClampedLimits {
  return {
    timeoutSec: Math.min(e.limits.timeoutSec, HARD_LIMITS.maxTimeoutSec),
    maxCount: Math.min(e.transport.count?.max ?? HARD_LIMITS.maxCount, HARD_LIMITS.maxCount),
  };
}

export type AdoptedService = { id: string; status: 'active'; limits: ClampedLimits } | { id: string; status: 'withdrawn' };

export interface CatalogState {
  maxSeenRevision: number;
  current: { revision: number; services: AdoptedService[] } | null;
}

export type CatalogSource = 'network' | 'cache' | 'builtin';

export type CatalogRejectReason = 'schema_mismatch' | 'revision_invalid' | SignatureFailure | 'revision_rollback' | 'unchanged';

export type CatalogAcceptance =
  | { accepted: false; reason: CatalogRejectReason; maxSeenRevision: number; current: CatalogState['current'] }
  | {
      accepted: true;
      reason: null;
      source: CatalogSource;
      maxSeenRevision: number;
      current: { revision: number; services: AdoptedService[] };
      skipped: Array<{ id: string | null; reason: EntrySkipReason }>;
    };

/**
 * Adopt a catalog. state: { maxSeenRevision, current: { revision, services } | null }; incoming: the catalog body; source: 'network' | 'cache' | 'builtin'.
 * Rules: signature fails -> not adopted, the previous one is kept; revision below the highest seen on this device -> not adopted (rollback protection, the built-in snapshot included);
 * equal -> unchanged; entries are validated one by one and a non-conforming one is only skipped; tombstone -> withdrawn, and sending the key to that service stops immediately.
 */
export async function acceptSearchCatalog({
  state,
  incoming,
  source,
  trustedKeys,
}: {
  state: CatalogState;
  incoming: unknown;
  source: CatalogSource;
  trustedKeys: Readonly<Record<string, string>>;
}): Promise<CatalogAcceptance> {
  const keep = (reason: CatalogRejectReason): CatalogAcceptance => ({ accepted: false, reason, maxSeenRevision: state.maxSeenRevision, current: state.current });
  const doc = incoming as Untrusted;
  if (doc?.schema !== CATALOG_SCHEMA) return keep('schema_mismatch');
  if (!Number.isSafeInteger(doc.revision) || doc.revision < 1) return keep('revision_invalid');
  const revision = doc.revision as number;
  const sig = await verifyCatalogSignature(doc, trustedKeys);
  if (!sig.ok) return keep(sig.reason);
  if (revision < state.maxSeenRevision) return keep('revision_rollback');
  if (state.current && revision === state.current.revision) return keep('unchanged');
  const services: AdoptedService[] = [];
  const skipped: Array<{ id: string | null; reason: EntrySkipReason }> = [];
  for (const e of (Array.isArray(doc.services) ? doc.services : []) as Untrusted[]) {
    const reason = validateCatalogEntry(e);
    if (reason) {
      skipped.push({ id: typeof e?.id === 'string' ? e.id : null, reason });
      continue;
    }
    services.push(e.tombstone ? { id: e.id, status: 'withdrawn' } : { id: e.id, status: 'active', limits: clampedLimits(e) });
  }
  return {
    accepted: true,
    reason: null,
    source,
    maxSeenRevision: Math.max(state.maxSeenRevision, revision),
    current: { revision, services },
    skipped,
  };
}

/** When reusing a model connection, pick the site by connection host (Kimi .cn / .ai); a host not in the table = not reusable. */
export function regionForConnection(entry: Pick<CatalogEntry, 'reuse'>, connectionBaseUrl: string | null | undefined): string | null {
  const host = String(connectionBaseUrl ?? '')
    .replace(/^https?:\/\//i, '')
    .split(/[/:?#]/)[0]
    .toLowerCase();
  const table = entry.reuse?.regionByConnectionHost;
  const region = table && Object.prototype.hasOwnProperty.call(table, host) ? table[host] : undefined;
  return region ?? null;
}

export type PresetHostVerdict = 'ok' | 'host_changed' | 'service_withdrawn';

/**
 * Host check before sending the key: the host bound to the saved service differs from the current catalog's host for that site -> host_changed (key not sent, re-confirmation required);
 * entry withdrawn -> service_withdrawn (stop sending the key).
 */
export function presetHostCheck({
  boundHost,
  entry,
  regionId,
  withdrawn = false,
}: {
  boundHost: string;
  entry: Pick<CatalogEntry, 'tombstone' | 'regions'> | null | undefined;
  regionId: string;
  withdrawn?: boolean;
}): PresetHostVerdict {
  if (withdrawn || entry?.tombstone) return 'service_withdrawn';
  const region = (entry?.regions ?? []).find((r) => r.id === regionId);
  if (!region) return 'service_withdrawn';
  return region.host === boundHost ? 'ok' : 'host_changed';
}

export interface RegionLinks {
  homepage: string;
  docs: string;
  terms: string;
  keyHelp: string;
  pricing: string;
}

/**
 * Official links a site should display: docs / pricing / keyHelp are taken from the site's `regions[].urls` first, with each missing key falling back to the entry level
 * (`urls.docs` / `pricing.sourceUrl` / `urls.keyHelp`); homepage / terms exist only at entry level. Site not found = all entry level.
 * Call only for entries that passed validation.
 */
export function regionLinks(entry: Pick<CatalogEntry, 'regions' | 'urls' | 'pricing'>, regionId: string): RegionLinks {
  const own: NonNullable<CatalogRegion['urls']> = (entry.regions ?? []).find((r) => r.id === regionId)?.urls ?? {};
  return {
    homepage: entry.urls.homepage,
    docs: own.docs ?? entry.urls.docs,
    terms: entry.urls.terms,
    keyHelp: own.keyHelp ?? entry.urls.keyHelp,
    pricing: own.pricing ?? entry.pricing.sourceUrl,
  };
}

export type CatalogFetchAction = 'adopt' | 'withdraw_presets' | 'keep';

/**
 * What to do with the result of fetching ?view=search: 200 -> adopt (hand to acceptSearchCatalog);
 * 404 -> withdraw_presets (the server explicitly says the catalog is unavailable / withdrawn as a whole: the whole preset block shows "unavailable", cache and built-in snapshot included,
 * a flag is recorded locally and cleared only once a 200 is obtained and adopted successfully; custom services are unaffected);
 * 304, any other status (including the 400 an older server returns for an unknown view), network error -> keep (keep the one in hand).
 */
export function catalogFetchAction({
  status = null,
  transportFailure = null,
}: { status?: number | null; transportFailure?: string | null } = {}): CatalogFetchAction {
  if (transportFailure) return 'keep';
  if (status === 200) return 'adopt';
  if (status === 404) return 'withdraw_presets';
  return 'keep';
}
