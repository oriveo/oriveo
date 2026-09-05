/**
 * Hard cap on draft slots, closing off an unbounded first-party key space.
 *
 * `draftId` is a fresh UUID issued on every ChatView mount, so a TTL bounds age but not count: a
 * heavy user can accumulate thousands of slots within 30 days and eat 1-2MB of localStorage. The
 * eviction order under the cap must be existing entries with no `updatedAt` first, then the
 * oldest, and the entry just written can never evict itself.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../../infra/storage/partition', () => ({ getActiveUIDSync: () => 'guest' }));
vi.mock('../../metadata/metadata-client', () => ({
  getCapabilityRuntime: () => ({ revision: 'runtime-r7' }),
  resolveCatalogModel: () => ({ canonicalModelId: 'model-a', transport: 'openai_responses' }),
}));

import {
  encodeCapabilityTransportIdentity,
  loadCapabilityPreferenceDraft,
  saveCapabilityPreferenceDraft,
} from '../capability-preference-settings';

const memory = new Map<string, string>();
vi.stubGlobal('window', { dispatchEvent: () => true });
vi.stubGlobal('localStorage', {
  getItem: (key: string) => memory.get(key) ?? null,
  setItem: (key: string, value: string) => { memory.set(key, value); },
  removeItem: (key: string) => { memory.delete(key); },
});

const DRAFT_STORE_KEY = 'oriveo.guest.capability-preference-drafts.v2';
const transportIdentity = encodeCapabilityTransportIdentity('openai_responses', 'runtime-r7');

function identityFor(modelId: string) {
  return {
    providerId: 'a0000000-0000-0000-0000-000000000001',
    canonicalModelId: modelId,
    finalTransport: 'openai_responses',
    runtimeRevision: 'runtime-r7',
    transportIdentity,
  };
}

function storedDraftCount(): number {
  return Object.keys(JSON.parse(memory.get(DRAFT_STORE_KEY) ?? '{}')).length;
}

describe('capability preference draft slot cap', () => {
  beforeEach(() => memory.clear());

  it('pins the total slot count at the cap no matter how many writes happen', () => {
    for (let i = 0; i < 260; i++) {
      saveCapabilityPreferenceDraft(`draft-${i}`, identityFor(`model-${i}`), { web: 'automatic' });
    }
    expect(storedDraftCount()).toBeLessThanOrEqual(200);
    // The most recently written entry must still be there: the cap evicts old slots, not the new one.
    expect(loadCapabilityPreferenceDraft('draft-259', identityFor('model-259'))).toEqual({ web: 'automatic' });
  });

  it('evicts existing entries without updatedAt first when over the cap', () => {
    // Seed an existing slot with no updatedAt directly; TTL pruning spares it, so only the cap can evict it.
    memory.set(DRAFT_STORE_KEY, JSON.stringify({
      'legacy-slot': {
        providerId: 'a0000000-0000-0000-0000-000000000001',
        canonicalModelId: 'model-legacy',
        finalTransport: 'openai_responses',
        runtimeRevision: 'runtime-r7',
        transportIdentity,
        values: { web: 'force' },
      },
    }));
    for (let i = 0; i < 205; i++) {
      saveCapabilityPreferenceDraft(`draft-${i}`, identityFor(`model-${i}`), { web: 'automatic' });
    }
    const stored = JSON.parse(memory.get(DRAFT_STORE_KEY) ?? '{}') as Record<string, unknown>;
    expect(stored['legacy-slot']).toBeUndefined();
    expect(Object.keys(stored).length).toBeLessThanOrEqual(200);
  });

  it('evicts nothing while under the cap, including entries without updatedAt', () => {
    memory.set(DRAFT_STORE_KEY, JSON.stringify({
      'legacy-slot': {
        providerId: 'a0000000-0000-0000-0000-000000000001',
        canonicalModelId: 'model-legacy',
        finalTransport: 'openai_responses',
        runtimeRevision: 'runtime-r7',
        transportIdentity,
        values: { web: 'force' },
      },
    }));
    saveCapabilityPreferenceDraft('draft-a', identityFor('model-a'), { web: 'automatic' });
    const stored = JSON.parse(memory.get(DRAFT_STORE_KEY) ?? '{}') as Record<string, unknown>;
    expect(stored['legacy-slot']).toBeDefined();
    expect(Object.keys(stored).length).toBe(2);
  });
});
