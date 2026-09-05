import { beforeEach, describe, expect, it } from 'vitest';
import {
  advanceCapabilityEvidenceIdentity,
  beginCapabilityEvidenceIdentitiesForLoadedProviders,
  beginCapabilityEvidenceIdentityIfAbsent,
  capabilityEvidenceIdentityForQuery,
  readCapabilityEvidenceIdentity,
  resetCapabilityEvidenceIdentitiesForTesting,
  tombstoneCapabilityEvidenceIdentity,
} from './capability-evidence-identity';

describe('local capability evidence identity', () => {
  beforeEach(() => {
    localStorage.clear();
    resetCapabilityEvidenceIdentitiesForTesting();
  });

  it('pure read/query without an entry fails closed and does not write', () => {
    expect(readCapabilityEvidenceIdentity('uid-a', 'provider-1')).toBeNull();
    expect(capabilityEvidenceIdentityForQuery('uid-a', 'provider-1')).toBeNull();
    expect(readCapabilityEvidenceIdentity('', 'provider-1')).toBeNull();
    expect(localStorage.length).toBe(0);
  });

  it('hydration migration creates opaque identity once and never derives it from Provider fields', () => {
    beginCapabilityEvidenceIdentitiesForLoadedProviders('uid-a', ['relay-1']);
    const first = readCapabilityEvidenceIdentity('uid-a', 'relay-1');
    beginCapabilityEvidenceIdentitiesForLoadedProviders('uid-a', ['relay-1']);
    const second = readCapabilityEvidenceIdentity('uid-a', 'relay-1');

    expect(first).not.toBeNull();
    expect(second).toEqual(first);
    expect(first?.connectionGeneration).not.toBe('2026-08-09T00:00:00.000Z');
    expect(first?.credentialEpoch).not.toBe('sk-private-value');
    expect(first?.connectionGeneration).not.toBe(first?.credentialEpoch);
  });

  it('same deterministic Provider ID remains isolated across partitions', () => {
    const first = beginCapabilityEvidenceIdentityIfAbsent('uid-a', 'official-openai');
    const second = beginCapabilityEvidenceIdentityIfAbsent('uid-b', 'official-openai');

    expect(first?.partitionId).toBe('uid-a');
    expect(second?.partitionId).toBe('uid-b');
    expect(second?.connectionGeneration).not.toBe(first?.connectionGeneration);
    expect(second?.credentialEpoch).not.toBe(first?.credentialEpoch);
    expect(readCapabilityEvidenceIdentity('uid-a', 'official-openai')).toEqual(first);
  });

  it('key write/rotate/delete advances only credential epoch', () => {
    const initial = beginCapabilityEvidenceIdentityIfAbsent('uid-a', 'relay-1')!;
    const written = advanceCapabilityEvidenceIdentity('uid-a', 'relay-1', { credentialEpoch: true })!;
    const rotated = advanceCapabilityEvidenceIdentity('uid-a', 'relay-1', { credentialEpoch: true })!;
    const deleted = advanceCapabilityEvidenceIdentity('uid-a', 'relay-1', { credentialEpoch: true })!;

    expect(written.connectionGeneration).toBe(initial.connectionGeneration);
    expect(rotated.connectionGeneration).toBe(initial.connectionGeneration);
    expect(deleted.connectionGeneration).toBe(initial.connectionGeneration);
    expect(new Set([
      initial.credentialEpoch,
      written.credentialEpoch,
      rotated.credentialEpoch,
      deleted.credentialEpoch,
    ]).size).toBe(4);
  });

  it('endpoint/auth/security/transport semantic edit advances only connection generation', () => {
    const initial = beginCapabilityEvidenceIdentityIfAbsent('uid-a', 'relay-1')!;
    const edited = advanceCapabilityEvidenceIdentity('uid-a', 'relay-1', { connectionGeneration: true })!;

    expect(edited.connectionGeneration).not.toBe(initial.connectionGeneration);
    expect(edited.credentialEpoch).toBe(initial.credentialEpoch);
  });

  it('delete tombstone advances both epochs and deterministic recreate reuses only the tombstone', () => {
    const initial = beginCapabilityEvidenceIdentityIfAbsent('uid-a', 'official-openai')!;
    const tombstone = tombstoneCapabilityEvidenceIdentity('uid-a', 'official-openai')!;
    const recreated = beginCapabilityEvidenceIdentityIfAbsent('uid-a', 'official-openai')!;

    expect(tombstone.connectionGeneration).not.toBe(initial.connectionGeneration);
    expect(tombstone.credentialEpoch).not.toBe(initial.credentialEpoch);
    expect(recreated).toEqual(tombstone);
  });

  it('legacy broad-cache-shaped storage is rejected instead of being promoted into identity', () => {
    localStorage.setItem('oriveo.capability-evidence-identity.v1', JSON.stringify({
      version: 1,
      entries: {
        'uid-a|relay-1': {
          providerKind: 'relay',
          modelId: 'private-model',
          unsupportedParams: ['temperature'],
          updatedAt: '2026-08-09T00:00:00.000Z',
        },
      },
    }));

    expect(readCapabilityEvidenceIdentity('uid-a', 'relay-1')).toBeNull();
    const migrated = beginCapabilityEvidenceIdentityIfAbsent('uid-a', 'relay-1');
    expect(migrated).not.toBeNull();
    expect(JSON.stringify(migrated)).not.toContain('temperature');
    expect(JSON.stringify(migrated)).not.toContain('2026-08-09');
  });
});
