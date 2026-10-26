// @vitest-environment jsdom
//
// Web negative cache v2 of input capabilities for all connections: key = connection x model x protocol family x capability key, 7-day expiry (only expiry deletes an entry), a ruling revision mismatch only reads as null without deleting the entry; the revision is FNV-1a 32 of the canonical ruling.

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  INPUT_NEGATIVE_CACHE_STORAGE_KEY,
  INPUT_NEGATIVE_CACHE_TTL_MS,
  clearInputNegativeCache,
  clearInputNegativeCacheConnection,
  inputVerdictRevision,
  type InputVerdictLike,
  paramCapabilityKey,
  readInputNegativeCache,
  recordInputNegativeCache,
} from '../input-negative-cache';

const key = { connectionId: 'c1', modelId: 'm1', wireFamily: 'openai_chat_completions', capabilityKey: 'vision_input' };
const T0 = 1_760_000_000_000;

function stored(): Array<Record<string, unknown>> {
  const raw = window.localStorage.getItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY);
  return raw ? (JSON.parse(raw) as { entries: Array<Record<string, unknown>> }).entries : [];
}

beforeEach(() => window.localStorage.clear());
afterEach(() => window.localStorage.clear());

describe('input negative cache v2', () => {
  it('stores under the v2 key with recordedAt / signatureId / verdictRevision', () => {
    recordInputNegativeCache(key, { signatureId: 'sig-a', verdictRevision: 'rev1' }, T0);
    expect(INPUT_NEGATIVE_CACHE_STORAGE_KEY).toBe('oriveo.capability-negative-cache.v2');
    expect(stored()).toEqual([{ ...key, recordedAt: T0, signatureId: 'sig-a', verdictRevision: 'rev1' }]);
    expect(readInputNegativeCache(key, 'rev1', T0 + 1)).toEqual({ recordedAt: T0, signatureId: 'sig-a', verdictRevision: 'rev1' });
  });

  it('keys on every dimension, params as param:<name>', () => {
    recordInputNegativeCache({ ...key, capabilityKey: paramCapabilityKey('temperature') }, { signatureId: 's', verdictRevision: 'r' }, T0);
    expect(stored()[0]?.capabilityKey).toBe('param:temperature');
    expect(readInputNegativeCache(key, 'r', T0)).toBeNull();
    expect(readInputNegativeCache({ ...key, capabilityKey: 'param:temperature', wireFamily: 'anthropic_messages' }, 'r', T0)).toBeNull();
    expect(readInputNegativeCache({ ...key, capabilityKey: 'param:temperature', modelId: 'm2' }, 'r', T0)).toBeNull();
    expect(readInputNegativeCache({ ...key, capabilityKey: 'param:temperature', connectionId: 'c2' }, 'r', T0)).toBeNull();
    expect(readInputNegativeCache({ ...key, capabilityKey: 'param:temperature' }, 'r', T0)).not.toBeNull();
  });

  it('expires after 7 days and deletes the entry', () => {
    recordInputNegativeCache(key, { signatureId: 's', verdictRevision: 'r' }, T0);
    expect(readInputNegativeCache(key, 'r', T0 + INPUT_NEGATIVE_CACHE_TTL_MS - 1)).not.toBeNull();
    expect(readInputNegativeCache(key, 'r', T0 + INPUT_NEGATIVE_CACHE_TTL_MS)).toBeNull();
    expect(stored()).toEqual([]);
  });

  it('verdict revision mismatch returns null but keeps the entry (only TTL deletes)', () => {
    const other = { ...key, capabilityKey: 'file_input' };
    recordInputNegativeCache(key, { signatureId: 's', verdictRevision: 'old' }, T0);
    recordInputNegativeCache(other, { signatureId: 's', verdictRevision: 'old' }, T0);
    expect(readInputNegativeCache(key, 'new', T0)).toBeNull();
    expect(stored().map((e) => e.capabilityKey)).toEqual(['vision_input', 'file_input']);
    // A context-free read surface reads once with another revision; the read surface with context still hits.
    expect(readInputNegativeCache(key, 'old', T0)).toEqual({ recordedAt: T0, signatureId: 's', verdictRevision: 'old' });
  });

  it('same key overwrites; clear by key and by connection', () => {
    recordInputNegativeCache(key, { signatureId: 's1', verdictRevision: 'r' }, T0);
    recordInputNegativeCache(key, { signatureId: 's2', verdictRevision: 'r' }, T0 + 5);
    expect(stored()).toHaveLength(1);
    expect(readInputNegativeCache(key, 'r', T0 + 6)?.signatureId).toBe('s2');
    recordInputNegativeCache({ ...key, connectionId: 'c2' }, { signatureId: 's', verdictRevision: 'r' }, T0);
    clearInputNegativeCache([key]);
    expect(stored().map((e) => e.connectionId)).toEqual(['c2']);
    clearInputNegativeCacheConnection('c2');
    expect(window.localStorage.getItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY)).toBeNull();
  });

  it('bad stored data reads as empty and v1 is untouched', () => {
    window.localStorage.setItem('oriveo.relay-negative-cache.v1', '{"version":1,"entries":[]}');
    window.localStorage.setItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY, '{not json');
    expect(readInputNegativeCache(key, 'r', T0)).toBeNull();
    window.localStorage.setItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY, JSON.stringify({ version: 2, entries: [{ ...key, recordedAt: T0 }] }));
    expect(readInputNegativeCache(key, 'r', T0)).toBeNull();
    expect(window.localStorage.getItem('oriveo.relay-negative-cache.v1')).toBe('{"version":1,"entries":[]}');
  });
});

describe('inputVerdictRevision', () => {
  // The same file on every client: shared/test-fixtures/capability/negative-cache.v1.json verdictRevisionCases
  const fixture = JSON.parse(readFileSync(
    resolve(__dirname, '../../../../../../../shared/test-fixtures/capability/negative-cache.v1.json'), 'utf8',
  )) as { verdictRevisionCases: Array<{ id: string; verdict: InputVerdictLike | null; revision: string }> };
  for (const item of fixture.verdictRevisionCases) {
    it(`VERDICT-REVISION-${item.id}`, () => {
      expect(inputVerdictRevision(item.verdict)).toBe(item.revision);
    });
  }

  it('ignores sourceRefs order, changes with any field', () => {
    const base = { state: 'auto_available', reasonCode: 'x', wireFamily: 'w', sourceRefs: ['s1', 's2'] };
    const rev = inputVerdictRevision(base);
    expect(rev).toMatch(/^[0-9a-f]{8}$/);
    expect(inputVerdictRevision({ ...base, sourceRefs: ['s2', 's1'] })).toBe(rev);
    expect(inputVerdictRevision({ ...base, state: 'unavailable' })).not.toBe(rev);
    expect(inputVerdictRevision({ ...base, reasonCode: 'y' })).not.toBe(rev);
    expect(inputVerdictRevision({ ...base, wireFamily: 'v' })).not.toBe(rev);
    expect(inputVerdictRevision({ ...base, sourceRefs: ['s1'] })).not.toBe(rev);
  });
});
