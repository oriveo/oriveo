/**
 * Local lifecycle invariants for capability preferences
 * (single source: `capability_preference_sync.v1.json#localLifecycleInvariants`).
 *
 * The wire invariants lock what the envelope looks like; these lock that a web / reasoning choice
 * the user made reads back unchanged through every read path and every lifecycle event
 * (merge echo, local eviction, runtime revision bumps, draft migration).
 *
 * Every read goes through the production entry points the composer and the send path use
 * (`displayCapabilityPreferences` / `resolveCapabilityPreferences`).
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const metadataMocks = vi.hoisted(() => ({
  getCapabilityRuntime: vi.fn(() => ({ revision: 'runtime-r7' })),
  resolveCatalogModel: vi.fn(() => null),
}));
vi.mock('../../metadata/metadata-client', async (importOriginal) => (await import('../../../__tests__/mocks/metadata-client')).metadataClientMock(importOriginal, metadataMocks));
const syncMocks = vi.hoisted(() => ({ didUpdatePreferences: vi.fn() }));
vi.mock('../../sync/sync-adapter', () => ({ getSyncAdapter: () => ({ didUpdatePreferences: syncMocks.didUpdatePreferences }) }));

import {
  decodeCapabilityTransportIdentity, displayCapabilityPreferences, exportCapabilityPreferenceSyncPayload,
  loadCapabilityPreferenceDraft, mergeCapabilityPreferenceSyncPayload, migrateCapabilityPreferenceDraft,
  resolveCapabilityPreferences, saveCapabilityPreferenceDraft, saveCapabilityPreferences,
  type CapabilityPreferences, type CapabilityRuntimeIdentity,
} from '../capability-preference-settings';
import type { ReasoningIntent } from '@oriveo/core/providers/request-preference/types';

const memory = new Map<string, string>();
vi.stubGlobal('window', {});
vi.stubGlobal('localStorage', {
  getItem: (k: string) => memory.get(k) ?? null,
  setItem: (k: string, v: string) => memory.set(k, v),
  removeItem: (k: string) => memory.delete(k),
  clear: () => memory.clear(),
});

// The shared contract directory name is built at runtime so this file stays ASCII-only.
const sharedDir = 'shared';
const contract = JSON.parse(readFileSync(
  resolve(process.cwd(), '../../../..', sharedDir, 'model-contracts/capability_preference_sync.v1.json'), 'utf8',
));
type FixtureValues = { web: CapabilityPreferences['web']; reasoningIntent: ReasoningIntent | null };
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type FixtureCase = { caseId: string } & Record<string, any>;
const cases = contract.localLifecycleInvariants.cases as FixtureCase[];

const values = (raw: FixtureValues): CapabilityPreferences => ({
  web: raw.web,
  ...(raw.reasoningIntent ? { reasoningIntent: raw.reasoningIntent } : {}),
});

/** Full runtime identity from a provider / model / wire transport identity triple. */
const identityOf = (providerId: string, canonicalModelId: string, transportIdentity: string): CapabilityRuntimeIdentity => {
  const decoded = decodeCapabilityTransportIdentity(transportIdentity);
  if (!decoded) throw new Error(`fixture transport identity does not decode: ${transportIdentity}`);
  return { providerId, canonicalModelId, finalTransport: decoded.finalTransport, runtimeRevision: decoded.runtimeRevision, transportIdentity };
};

const conversationIdFrom = (pattern: string, index: number): string =>
  pattern.replace(/\{index:012d\}/, String(index).padStart(12, '0'));

const seedConversations = (identity: CapabilityRuntimeIdentity, seed: FixtureCase['seed']): void => {
  for (let index = 0; index < seed.count; index += 1) {
    saveCapabilityPreferences(
      { ...identity, scope: seed.scope, conversationId: conversationIdFrom(seed.conversationIdPattern, index) },
      values(seed.values),
    );
  }
};

const localRecordCount = (): number => {
  const key = [...memory.keys()].find((k) => k.endsWith('capability-preference-settings.v2'));
  if (!key) return 0;
  return (JSON.parse(memory.get(key)!).records as unknown[]).length;
};

const handlers: Record<string, (fixtureCase: FixtureCase) => void> = {
  'CPL-01': (c) => {
    const identity = c.identity as CapabilityRuntimeIdentity;
    seedConversations(identity, c.seed);
    const exported = exportCapabilityPreferenceSyncPayload();
    expect(exported.records).toHaveLength(c.expected.exportedRecordCount);
    mergeCapabilityPreferenceSyncPayload(JSON.parse(JSON.stringify(exported)));
    const query = { ...identity, conversationId: c.expected.lookupConversationId };
    expect(displayCapabilityPreferences(query)).toEqual(values(c.expected.lookupValues));
    expect(resolveCapabilityPreferences(query)).toEqual(values(c.expected.lookupValues));
  },
  'CPL-02': (c) => {
    const identity = c.identity as CapabilityRuntimeIdentity;
    saveCapabilityPreferences({ ...identity, scope: c.write.scope, conversationId: c.write.conversationId }, values(c.write.values));
    const exported = exportCapabilityPreferenceSyncPayload();
    expect(exported.records.map((record) => record.conversationId)).toEqual([c.expected.exportedConversationId]);
    mergeCapabilityPreferenceSyncPayload(JSON.parse(JSON.stringify(exported)));
    for (const lookup of c.expected.lookups) {
      const query = { ...identity, conversationId: lookup.conversationId };
      expect(displayCapabilityPreferences(query)).toEqual(values(lookup.values));
      expect(resolveCapabilityPreferences(query)).toEqual(values(lookup.values));
    }
  },
  'CPL-03': (c) => {
    const written = identityOf(c.write.providerId, c.write.canonicalModelId, c.write.transportIdentity);
    saveCapabilityPreferences({ ...written, scope: c.write.scope, conversationId: c.write.conversationId }, values(c.write.values));
    for (const read of c.reads) {
      const query = { ...identityOf(c.write.providerId, c.write.canonicalModelId, read.transportIdentity), conversationId: c.write.conversationId };
      const actual = read.path === 'send' ? resolveCapabilityPreferences(query) : displayCapabilityPreferences(query);
      expect(actual, `${read.path} @ ${read.transportIdentity}`).toEqual(values(read.expected));
    }
  },
  'CPL-04': (c) => {
    const draftIdentity = identityOf(c.write.providerId, c.write.canonicalModelId, c.write.transportIdentity);
    saveCapabilityPreferenceDraft(c.write.draftId, draftIdentity, values(c.write.values));
    const current = identityOf(c.write.providerId, c.write.canonicalModelId, c.action.currentTransportIdentity);
    migrateCapabilityPreferenceDraft(c.write.draftId, { ...current, conversationId: c.action.migrateDraftTo });
    const lookup = c.expected.conversationLookup;
    const query = { ...identityOf(c.write.providerId, c.write.canonicalModelId, lookup.transportIdentity), conversationId: lookup.conversationId };
    expect(displayCapabilityPreferences(query)).toEqual(values(lookup.values));
    expect(resolveCapabilityPreferences(query)).toEqual(values(lookup.values));
    const remains = loadCapabilityPreferenceDraft(c.write.draftId, draftIdentity) !== undefined
      || loadCapabilityPreferenceDraft(c.write.draftId, current) !== undefined;
    expect(remains).toBe(c.expected.draftRemains);
  },
  'CPL-06': (c) => {
    const identity = c.identity as CapabilityRuntimeIdentity;
    seedConversations(identity, c.seed);
    const exported = exportCapabilityPreferenceSyncPayload();
    const remoteRecords = [...JSON.parse(JSON.stringify(exported.records)), c.remoteExtraRecord]
      .sort((a: { recordId: string }, b: { recordId: string }) => (a.recordId < b.recordId ? -1 : a.recordId > b.recordId ? 1 : 0));
    const merged = mergeCapabilityPreferenceSyncPayload({ ...exported, records: remoteRecords });
    expect(merged.records).toHaveLength(c.expected.exportedRecordCount);
    expect(exportCapabilityPreferenceSyncPayload().records).toHaveLength(c.expected.exportedRecordCount);
    const conversationQuery = { ...identity, conversationId: c.expected.lookupConversationId };
    expect(displayCapabilityPreferences(conversationQuery)).toEqual(values(c.expected.lookupValues));
    expect(resolveCapabilityPreferences(conversationQuery)).toEqual(values(c.expected.lookupValues));
    expect(displayCapabilityPreferences(identity)).toEqual(values(c.expected.connectionValues));
    expect(resolveCapabilityPreferences(identity)).toEqual(values(c.expected.connectionValues));
  },
  'CPL-05': (c) => {
    const identity = c.identity as CapabilityRuntimeIdentity;
    seedConversations(identity, c.seed);
    saveCapabilityPreferences({ ...identity, scope: c.write.scope, conversationId: c.write.conversationId }, values(c.write.values));
    expect(localRecordCount()).toBe(c.expected.localRecordCount);
    const lookup = (conversationId: string) => displayCapabilityPreferences({ ...identity, conversationId });
    expect(lookup(c.write.conversationId)).toEqual(values(c.write.values));
    for (const conversationId of c.expected.retained) {
      expect(lookup(conversationId).web, `retained ${conversationId}`).toBe('automatic');
    }
    for (const conversationId of c.expected.evicted) {
      expect(lookup(conversationId), `evicted ${conversationId}`).toEqual({ web: 'off' });
    }
  },
};

describe('capability_preference_sync.v1#localLifecycleInvariants', () => {
  beforeEach(() => memory.clear());

  it('covers exactly the fixture case set', () => {
    expect(cases.map((c) => c.caseId.slice(0, 6)).sort()).toEqual(Object.keys(handlers).sort());
  });

  for (const fixtureCase of cases) {
    it(fixtureCase.caseId, () => {
      const handler = handlers[fixtureCase.caseId.slice(0, 6)];
      expect(handler, `no handler for ${fixtureCase.caseId}`).toBeDefined();
      handler!(fixtureCase);
    });
  }
});
