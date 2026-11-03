/**
 * Studio style / effect presets client logic (shared fixture studio_presets.v1.json
 * clientCases): envelope decoding, locale resolution, the bundled text-only offline
 * snapshot, and the refresh plan / response handling. Pure functions, no I/O.
 */
import snapshotJson from './studio-presets-snapshot.v1.json';

export type StudioLocalizedText = Record<string, string>;

export interface StudioSnapshotGroup {
  id: string;
  order: number;
  displayName: StudioLocalizedText;
}

export interface StudioSnapshotStyle {
  id: string;
  group: string;
  order: number;
  featured?: boolean;
  displayName: StudioLocalizedText;
  description?: StudioLocalizedText;
  promptFragment: string;
  sample?: { placeholderColor?: string };
}

export interface StudioSnapshotEffect {
  id: string;
  group: string;
  order: number;
  displayName: StudioLocalizedText;
  promptFragment: string;
  swatch?: string[];
}

export interface StudioPresetsSnapshot {
  contractId: string;
  revision: string;
  locales: string[];
  limits: Record<string, unknown>;
  styleGroups: StudioSnapshotGroup[];
  effectGroups: StudioSnapshotGroup[];
  styles: StudioSnapshotStyle[];
  effects: StudioSnapshotEffect[];
}

type Localized<T> = Omit<T, 'displayName'> & { displayName: string | undefined };

export interface StudioPresetsEnvelope {
  code: 0;
  message: string;
  data: {
    contractId: string;
    revision: string;
    locale: string;
    limits: Record<string, unknown>;
    styleGroups: Array<Localized<StudioSnapshotGroup>>;
    effectGroups: Array<Localized<StudioSnapshotGroup>>;
    styles: Array<
      Omit<Localized<StudioSnapshotStyle>, 'description' | 'sample'> & {
        description: string | undefined;
        sample: { placeholderColor: string | undefined };
      }
    >;
    effects: Array<Localized<StudioSnapshotEffect>>;
  };
}

export interface StudioPresetGroup {
  id: string;
  order: number;
  displayName: string;
}

export interface StudioPresetSample {
  url: string;
  width: number;
  height: number;
  sha256: string;
}

export interface StudioStylePreset {
  id: string;
  group: string;
  order: number;
  featured: boolean;
  displayName: string;
  description: string;
  promptFragment: string;
  placeholderColor: string | null;
  sample: StudioPresetSample | null;
}

export interface StudioEffectPreset {
  id: string;
  group: string;
  order: number;
  displayName: string;
  promptFragment: string;
  swatch: string[];
}

export type StudioPresetDropReason = 'invalid_field' | 'fragment_too_long' | 'unknown_group' | 'duplicate_id';

export interface StudioPresetDrop {
  kind: 'style' | 'effect';
  id: string | null;
  reason: StudioPresetDropReason;
}

export interface StudioPresets {
  error: null;
  revision: string;
  locale: string;
  styleGroups: StudioPresetGroup[];
  effectGroups: StudioPresetGroup[];
  styles: StudioStylePreset[];
  effects: StudioEffectPreset[];
  dropped: StudioPresetDrop[];
}

export type StudioPresetsDecodeError = 'invalid_envelope' | 'unsupported_contract';

export type StudioPresetsDecodeResult = StudioPresets | { error: StudioPresetsDecodeError };

export interface StudioPresetCache {
  locale: string;
  revision: string;
  etag: string | null;
  checkedAtMs: number;
}

export interface StudioPresetRefreshInput {
  cache: StudioPresetCache | null;
  locale: string;
  nowMs: number;
}

export interface StudioPresetRefreshPlan {
  fetch: boolean;
  ifNoneMatch: string | null;
}

/** status 0 = transport failure. */
export interface StudioPresetResponse {
  status: number;
  etag?: string | null;
  body?: unknown;
}

export interface StudioPresetApplyInput extends StudioPresetRefreshInput {
  response: StudioPresetResponse;
}

export type StudioPresetApplyOutcome = 'not_modified' | 'unchanged' | 'replaced' | 'failed' | 'invalid';

export interface StudioPresetApplyResult {
  outcome: StudioPresetApplyOutcome;
  cache: StudioPresetCache | null;
  bodyReplaced: boolean;
}

const BUNDLED_SNAPSHOT: StudioPresetsSnapshot = snapshotJson;

/** The committed text-only snapshot; offline presets = decode(localize(snapshot, tag)). */
export function bundledStudioPresetsSnapshot(): StudioPresetsSnapshot {
  return BUNDLED_SNAPSHOT;
}

const PRESET_CONTRACT_ID = 'studio_presets.v1';
const PRESET_REFRESH_INTERVAL_MS = 6 * 3600 * 1000;
const DEFAULT_FRAGMENT_MAX_CHARS = 160;
const HEX_COLOR = /^#[0-9A-Fa-f]{6}$/;
const SHA256_HEX = /^[0-9a-f]{64}$/;

type JsonObject = Record<string, unknown>;

const codePoints = (s: string): number => [...s].length;
const plainObject = (v: unknown): JsonObject | null =>
  v !== null && typeof v === 'object' && !Array.isArray(v) ? (v as JsonObject) : null;
const nonEmptyString = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);
// Integers are JSON numbers inside the IEEE-754 safe range (every end can hold them exactly).
const isInteger = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v);
const positiveInt = (v: unknown): number | null => (isInteger(v) && v > 0 ? v : null);
const ASCII_SPACE_EDGES = /^[\t\n\v\f\r ]+|[\t\n\v\f\r ]+$/g;

// Same order as the Server: exact (case-insensitive, `_` = `-`) -> zh by script, then region -> language subtag -> en.
export function resolveStudioPresetLocale(locales: readonly string[], tag: unknown): string {
  // Only ASCII whitespace is trimmed (each language's trim() strips a different Unicode set).
  const t = typeof tag === 'string' ? tag.replace(ASCII_SPACE_EDGES, '').replace(/_/g, '-') : '';
  if (t === '') return 'en';
  const lower = t.toLowerCase();
  const exact = locales.find((l) => l.toLowerCase() === lower);
  if (exact) return exact;
  const parts = lower.split('-');
  if (parts[0] === 'zh') {
    const rest = parts.slice(1);
    if (rest.includes('hant')) return 'zh-Hant';
    if (rest.includes('hans')) return 'zh-Hans';
    return rest.some((p) => p === 'tw' || p === 'hk' || p === 'mo') ? 'zh-Hant' : 'zh-Hans';
  }
  return locales.find((l) => l.toLowerCase().split('-')[0] === parts[0]) ?? 'en';
}

// Offline snapshot -> the same envelope the Server would send for `tag`, minus sample images (placeholder only).
export function localizeStudioPresets(snapshot: StudioPresetsSnapshot, tag: unknown): StudioPresetsEnvelope {
  const locale = resolveStudioPresetLocale(snapshot.locales, tag);
  const pick = (m: StudioLocalizedText | undefined): string | undefined => {
    const value = m?.[locale];
    return typeof value === 'string' ? value : m?.en;
  };
  const named = <T extends { displayName: StudioLocalizedText }>(g: T): Omit<T, 'displayName'> & { displayName: string | undefined } => ({
    ...g,
    displayName: pick(g.displayName),
  });
  return {
    code: 0,
    message: 'ok',
    data: {
      contractId: snapshot.contractId,
      revision: snapshot.revision,
      locale,
      limits: snapshot.limits,
      styleGroups: snapshot.styleGroups.map(named),
      effectGroups: snapshot.effectGroups.map(named),
      styles: snapshot.styles.map((s) => ({
        ...named(s),
        description: pick(s.description),
        sample: { placeholderColor: s.sample?.placeholderColor },
      })),
      effects: snapshot.effects.map(named),
    },
  };
}

function decodeGroups(list: unknown): StudioPresetGroup[] {
  const seen = new Set<string>();
  const out: StudioPresetGroup[] = [];
  for (const raw of Array.isArray(list) ? list : []) {
    const g = plainObject(raw);
    if (!g) continue;
    const id = nonEmptyString(g.id);
    const displayName = nonEmptyString(g.displayName);
    if (!id || !isInteger(g.order) || !displayName) continue;
    if (seen.has(id)) continue;
    seen.add(id);
    out.push({ id, order: g.order, displayName });
  }
  return out
    .map((g, i) => [g, i] as const)
    .sort((a, b) => a[0].order - b[0].order || a[1] - b[1])
    .map(([g]) => g);
}

function decodeSample(raw: unknown): StudioPresetSample | null {
  const s = plainObject(raw);
  if (!s) return null;
  const url = nonEmptyString(s.url);
  const width = positiveInt(s.width);
  const height = positiveInt(s.height);
  if (!url || !width || !height) return null;
  if (typeof s.sha256 !== 'string' || !SHA256_HEX.test(s.sha256)) return null;
  return { url, width, height, sha256: s.sha256 };
}

function decodeEntries<K extends 'style' | 'effect'>(
  kind: K,
  list: unknown[],
  groups: StudioPresetGroup[],
  maxFragment: number,
): { entries: Array<K extends 'style' ? StudioStylePreset : StudioEffectPreset>; dropped: StudioPresetDrop[] } {
  type Entry = K extends 'style' ? StudioStylePreset : StudioEffectPreset;
  const groupOrder = new Map(groups.map((g) => [g.id, g.order]));
  const seen = new Set<string>();
  const kept: Array<[Entry, number]> = [];
  const dropped: StudioPresetDrop[] = [];
  list.forEach((raw, index) => {
    const e = plainObject(raw);
    const id = e ? nonEmptyString(e.id) : null;
    const displayName = e ? nonEmptyString(e.displayName) : null;
    const promptFragment = e ? nonEmptyString(e.promptFragment) : null;
    let reason: StudioPresetDropReason | null = null;
    if (
      !e || !id || !isInteger(e.order) || !displayName || !promptFragment
      || (kind === 'style' && e.description !== undefined && typeof e.description !== 'string')
    ) reason = 'invalid_field';
    else if (codePoints(promptFragment) > maxFragment) reason = 'fragment_too_long';
    else if (typeof e.group !== 'string' || !groupOrder.has(e.group)) reason = 'unknown_group';
    else if (seen.has(id)) reason = 'duplicate_id';
    if (reason || !e || !id || !displayName || !promptFragment || !isInteger(e.order) || typeof e.group !== 'string') {
      dropped.push({ kind, id, reason: reason ?? 'invalid_field' });
      return;
    }
    seen.add(id);
    const group = e.group;
    const order = e.order;
    let entry: StudioStylePreset | StudioEffectPreset;
    if (kind === 'style') {
      const sample = plainObject(e.sample);
      const color = sample?.placeholderColor;
      entry = {
        id, group, order, featured: e.featured === true, displayName,
        description: typeof e.description === 'string' ? e.description : '', promptFragment,
        placeholderColor: typeof color === 'string' && HEX_COLOR.test(color) ? color : null,
        sample: decodeSample(e.sample),
      };
    } else {
      entry = {
        id, group, order, displayName, promptFragment,
        swatch: Array.isArray(e.swatch)
          ? e.swatch.filter((c): c is string => typeof c === 'string' && HEX_COLOR.test(c))
          : [],
      };
    }
    kept.push([entry as Entry, index]);
  });
  kept.sort(
    (a, b) =>
      (groupOrder.get(a[0].group) ?? 0) - (groupOrder.get(b[0].group) ?? 0) || a[0].order - b[0].order || a[1] - b[1],
  );
  return { entries: kept.map(([e]) => e), dropped };
}

// `{code,data,message}` envelope -> presets; bad entries are dropped one by one and reported, unknown fields ignored.
export function decodeStudioPresets(envelope: unknown): StudioPresetsDecodeResult {
  const env = plainObject(envelope);
  const d = env && env.code === 0 ? plainObject(env.data) : null;
  if (!d) return { error: 'invalid_envelope' };
  if (d.contractId !== PRESET_CONTRACT_ID) return { error: 'unsupported_contract' };
  const revision = nonEmptyString(d.revision);
  const locale = nonEmptyString(d.locale);
  if (!revision || !locale || !Array.isArray(d.styles) || !Array.isArray(d.effects)) {
    return { error: 'invalid_envelope' };
  }
  const maxFragment = positiveInt(plainObject(d.limits)?.promptFragmentMaxChars) ?? DEFAULT_FRAGMENT_MAX_CHARS;
  const styleGroups = decodeGroups(d.styleGroups);
  const effectGroups = decodeGroups(d.effectGroups);
  const styles = decodeEntries('style', d.styles, styleGroups, maxFragment);
  const effects = decodeEntries('effect', d.effects, effectGroups, maxFragment);
  return {
    error: null,
    revision,
    locale,
    styleGroups,
    effectGroups,
    styles: styles.entries,
    effects: effects.entries,
    dropped: [...styles.dropped, ...effects.dropped],
  };
}

// Cache = { locale, revision, etag, checkedAtMs } (the raw body is stored next to it by the Store).
export function planStudioPresetRefresh({ cache, locale, nowMs }: StudioPresetRefreshInput): StudioPresetRefreshPlan {
  if (!cache || cache.locale !== locale) return { fetch: true, ifNoneMatch: null };
  const age = nowMs - cache.checkedAtMs;
  if (age >= 0 && age < PRESET_REFRESH_INTERVAL_MS) return { fetch: false, ifNoneMatch: null };
  return { fetch: true, ifNoneMatch: cache.etag ?? null };
}

// Applies one response (status 0 = transport failure). Failures never touch the cache nor checkedAtMs.
export function applyStudioPresetResponse({ cache, locale, nowMs, response }: StudioPresetApplyInput): StudioPresetApplyResult {
  const sameLocale = !!cache && cache.locale === locale;
  if (response.status === 304 && cache && sameLocale) {
    return { outcome: 'not_modified', cache: { ...cache, checkedAtMs: nowMs }, bodyReplaced: false };
  }
  if (response.status !== 200) return { outcome: 'failed', cache: cache ?? null, bodyReplaced: false };
  const decoded = decodeStudioPresets(response.body);
  if (decoded.error !== null) return { outcome: 'invalid', cache: cache ?? null, bodyReplaced: false };
  if (cache && sameLocale && cache.revision === decoded.revision) {
    return { outcome: 'unchanged', cache: { ...cache, checkedAtMs: nowMs }, bodyReplaced: false };
  }
  return {
    outcome: 'replaced',
    cache: { locale, revision: decoded.revision, etag: response.etag ?? null, checkedAtMs: nowMs },
    bodyReplaced: true,
  };
}
