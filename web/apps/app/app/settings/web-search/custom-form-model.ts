// Custom search service form state ↔ stored record / transport mapping, and the "Continue" validation.

import {
  normalizeSearchKey,
  snapshotPresetMapping,
  validateCustomSearchService,
  type CustomProtocol,
  type StaticParamValue,
  type TransportSpec,
} from '@oriveo/core/search/search-transport';
import { customFormFieldErrors, type CustomFormField, type CustomFormFieldErrors } from '@oriveo/core/search/search-settings';
import type { StoredCustomSearchService } from '../../../lib/search/search-service-store';
import { webAddressClass, type SettingsCatalog } from '../../../lib/search/search-settings-data';

export const MAX_STATIC_PARAMS = 10;

export interface CustomFormValues {
  name: string;
  address: string;
  key: string;
  protocol: CustomProtocol;
  sameAsId: string | null;
  /** The site referenced by "Same as X"; null = the first site of that provider */
  sameAsRegionId: string | null;
  method: 'GET' | 'POST';
  auth: 'bearer' | 'header' | 'none';
  headerName: string;
  queryField: string;
  countField: string;
  params: Array<{ name: string; value: string }>;
  resultsPath: string;
  titlePath: string;
  urlPath: string;
  snippetPath: string;
  sitePath: string;
  datePath: string;
}

export type CustomFormKey = keyof CustomFormValues;

export function emptyCustomForm(): CustomFormValues {
  return {
    name: '',
    address: '',
    key: '',
    protocol: 'searxng',
    sameAsId: null,
    sameAsRegionId: null,
    method: 'GET',
    auth: 'bearer',
    headerName: '',
    queryField: '',
    countField: '',
    params: [],
    resultsPath: '',
    titlePath: '',
    urlPath: '',
    snippetPath: '',
    sitePath: '',
    datePath: '',
  };
}

const first = (list: readonly string[] | undefined) => list?.[0] ?? '';

/** Prefill the edit form from a saved custom service (the key is never shown back). */
export function customFormFromRecord(record: StoredCustomSearchService): CustomFormValues {
  const base = { ...emptyCustomForm(), name: record.name, address: record.address, protocol: record.protocol };
  const m = record.mapping as (TransportSpec & { snapshotOf?: { serviceId?: string; region?: string | null } }) | null;
  if (record.protocol === 'same_as') return { ...base, sameAsId: m?.snapshotOf?.serviceId ?? null, sameAsRegionId: m?.snapshotOf?.region ?? null };
  if (record.protocol !== 'manual' || !m) return base;
  return {
    ...base,
    method: m.method,
    auth: m.auth.kind,
    headerName: m.auth.name ?? '',
    queryField: m.query.field,
    countField: m.count?.field ?? '',
    params: Object.entries(m.static?.params ?? {}).map(([name, value]) => ({ name, value: String(value) })),
    resultsPath: m.response.results,
    titlePath: first(m.response.title),
    urlPath: first(m.response.url),
    snippetPath: first(m.response.snippet),
    sitePath: first(m.response.site),
    datePath: first(m.response.date),
  };
}

/** Typed static values: whole numbers and true / false become non-strings, everything else stays text. */
function paramValue(raw: string): StaticParamValue {
  const v = raw.trim();
  if (v === 'true') return true;
  if (v === 'false') return false;
  if (/^-?\d{1,15}$/.test(v)) return Number(v);
  return raw;
}

export function manualMapping(values: CustomFormValues): TransportSpec {
  const location = values.method === 'GET' ? 'query' : 'body';
  const params: Record<string, StaticParamValue> = {};
  for (const p of values.params) if (p.name.trim()) params[p.name.trim()] = paramValue(p.value);
  const path = (v: string) => (v.trim() ? [v.trim()] : undefined);
  return {
    method: values.method,
    auth: values.auth === 'header' ? { kind: 'header', name: values.headerName.trim() } : { kind: values.auth },
    query: { field: values.queryField.trim(), in: location },
    count: values.countField.trim() ? { field: values.countField.trim(), in: location } : null,
    static: Object.keys(params).length ? { in: location, params } : null,
    response: {
      results: values.resultsPath.trim(),
      title: path(values.titlePath) ?? [],
      url: path(values.urlPath) ?? [],
      snippet: path(values.snippetPath) ?? [],
      ...(path(values.sitePath) ? { site: path(values.sitePath) } : {}),
      ...(path(values.datePath) ? { date: path(values.datePath) } : {}),
    },
    errors: [],
  };
}

export interface CustomFormCheck {
  feedback: CustomFormFieldErrors;
  mapping: TransportSpec | null;
  /** Normalized key; null = key left empty (optional for custom services) */
  key: string | null;
  host: string | null;
}

export interface CustomFormCheckOptions {
  /** Validate the typed key (normalizeSearchKey); off when the key field is hidden. */
  requireKeyCheck?: boolean;
  /** same_as with an unchanged reference: keep this stored snapshot and don't require the preset (customServiceEditPlan). */
  keepSnapshot?: TransportSpec | null;
}

/** Runs only on Continue / Save: validateCustomSearchService (+ normalizeSearchKey when a key was typed). */
export function checkCustomForm(values: CustomFormValues, catalog: SettingsCatalog | null, { requireKeyCheck = true, keepSnapshot = null }: CustomFormCheckOptions = {}): CustomFormCheck {
  const keep = values.protocol === 'same_as' && keepSnapshot ? keepSnapshot : null;
  const sameAsEntry = !keep && values.protocol === 'same_as' && values.sameAsId ? catalog?.entries.find((e) => e.id === values.sameAsId) ?? null : null;
  const sameAsRegion = sameAsEntry ? sameAsEntry.regions.find((r) => r.id === values.sameAsRegionId)?.id ?? sameAsEntry.regions[0]?.id ?? null : null;
  const mapping = values.protocol === 'manual'
    ? manualMapping(values)
    : keep
      ? keep
      : sameAsEntry
        ? (snapshotPresetMapping(sameAsEntry, sameAsRegion) as TransportSpec)
        : null;
  const validation = validateCustomSearchService({
    name: values.name,
    address: values.address.trim(),
    protocol: values.protocol,
    platform: 'web',
    addressClass: webAddressClass(values.address),
    presetId: values.sameAsId ?? undefined,
    catalogAvailable: keep ? true : catalog?.available ?? false,
    presetActive: keep ? true : !!sameAsEntry,
    manual: values.protocol === 'manual' ? mapping : undefined,
  });
  const errors = [...validation.errors];
  let key: string | null = null;
  if (requireKeyCheck && values.key.trim()) {
    const normalized = normalizeSearchKey(values.key);
    if (normalized.ok) key = normalized.key;
    else errors.push(normalized.error);
  }
  let host: string | null = null;
  try {
    host = new URL(values.address.trim()).host;
  } catch {
    host = null;
  }
  return { feedback: customFormFieldErrors({ errors, warnings: validation.warnings }), mapping, key, host };
}

/** Which validation field a form input clears when edited. */
export const FIELD_OF_INPUT: Partial<Record<CustomFormKey, CustomFormField>> = {
  name: 'name',
  address: 'address',
  key: 'key',
  protocol: 'protocol',
  sameAsId: 'protocol',
  sameAsRegionId: 'protocol',
  method: 'method',
  auth: 'auth',
  headerName: 'auth',
  queryField: 'query',
  countField: 'count',
  params: 'params',
  resultsPath: 'results',
  titlePath: 'title',
  urlPath: 'url',
  snippetPath: 'snippet',
  sitePath: 'site',
  datePath: 'date',
};
