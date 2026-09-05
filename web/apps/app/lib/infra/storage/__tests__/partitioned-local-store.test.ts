/**
 * @vitest-environment jsdom
 *
 * Per-UID partition key cleanup on the sign-out path.
 *
 * The fact under test: the `oriveo.` key space also holds non-partitioned keys
 * (`oriveo.sync.deviceId`, `oriveo.providersUsageSummary.<key>`, legacy bare keys and so on), so
 * cleanup can only do an exact prefix match against the real uid the caller passes in. Guessing which
 * segment looks like a uid deletes user data when the guess is wrong.
 */

import { afterEach, describe, expect, it, vi } from 'vitest';

// getActiveUIDSync is a synchronous mirror; a mutable holder simulates switching partitions (the same
// approach as preferences.test.ts).
const partitionMocks = vi.hoisted(() => ({ activeUID: 'guest' }));
vi.mock('../partition', () => ({
  getActiveUIDSync: () => partitionMocks.activeUID,
}));

import {
  clearGuestPartitionedStore,
  clearPartitionedStoreForUID,
  readPartitionedStore,
} from '../partitioned-local-store';

const UID_A = '64Qu3gE4MTYjrVmP1C1LCrZiTjj2';
const UID_B = 'AbCdEfGh123456789012345678xy';

afterEach(() => {
  window.localStorage.clear();
  partitionMocks.activeUID = 'guest';
});

describe('clearPartitionedStoreForUID', () => {
  it('deletes only the given uid\'s partition keys and touches neither similar non-partition keys nor other uids', () => {
    // Partition keys for the target uid (preferences.ts and partitioned-local-store.ts use the same scheme).
    localStorage.setItem(`oriveo.${UID_A}.preferences`, '{"theme":"dark"}');
    localStorage.setItem(`oriveo.${UID_A}.budget.lastAlertMonth`, '"2026-08"');
    // Neighbours that must survive.
    localStorage.setItem(`oriveo.${UID_B}.preferences`, '{"theme":"light"}');
    localStorage.setItem('oriveo.guest.preferences', '{"theme":"auto"}');
    localStorage.setItem('oriveo.sync.deviceId', 'device-1');
    localStorage.setItem('oriveo.providersUsageSummary.acct', '{}');
    localStorage.setItem('oriveo.preferences', '{"legacy":true}'); // legacy bare key
    localStorage.setItem('third-party:session', '{}');

    expect(clearPartitionedStoreForUID(UID_A)).toBe(2);

    expect(localStorage.getItem(`oriveo.${UID_A}.preferences`)).toBeNull();
    expect(localStorage.getItem(`oriveo.${UID_A}.budget.lastAlertMonth`)).toBeNull();
    expect(localStorage.getItem(`oriveo.${UID_B}.preferences`)).toBe('{"theme":"light"}');
    expect(localStorage.getItem('oriveo.guest.preferences')).toBe('{"theme":"auto"}');
    expect(localStorage.getItem('oriveo.sync.deviceId')).toBe('device-1');
    expect(localStorage.getItem('oriveo.providersUsageSummary.acct')).toBe('{}');
    expect(localStorage.getItem('oriveo.preferences')).toBe('{"legacy":true}');
    expect(localStorage.getItem('third-party:session')).toBe('{}');
  });

  it('rejects guest and an empty uid outright, since clearing the guest partition wipes everything a signed-out user has', () => {
    localStorage.setItem('oriveo.guest.preferences', '{"theme":"auto"}');
    expect(clearPartitionedStoreForUID('guest')).toBe(0);
    expect(clearPartitionedStoreForUID('')).toBe(0);
    expect(localStorage.getItem('oriveo.guest.preferences')).toBe('{"theme":"auto"}');
  });

  it('does not delete the longer uid when one uid is a prefix of another (the prefix includes the trailing dot)', () => {
    const shortUID = UID_A.slice(0, 20);
    localStorage.setItem(`oriveo.${UID_A}.preferences`, 'keep');
    expect(clearPartitionedStoreForUID(shortUID)).toBe(0);
    expect(localStorage.getItem(`oriveo.${UID_A}.preferences`)).toBe('keep');
  });
});

describe('clearGuestPartitionedStore (the account-switch boundary entry point)', () => {
  it('clears only guest partition keys and leaves real account partitions and non-partition keys alone', () => {
    localStorage.setItem('oriveo.guest.preferences', '{"theme":"auto"}');
    localStorage.setItem('oriveo.guest.capability-preference-settings.v2', '{}');
    localStorage.setItem(`oriveo.${UID_A}.preferences`, 'keep');
    localStorage.setItem('oriveo.sync.deviceId', 'device-1');

    expect(clearGuestPartitionedStore()).toBe(2);

    expect(localStorage.getItem('oriveo.guest.preferences')).toBeNull();
    expect(localStorage.getItem('oriveo.guest.capability-preference-settings.v2')).toBeNull();
    expect(localStorage.getItem(`oriveo.${UID_A}.preferences`)).toBe('keep');
    expect(localStorage.getItem('oriveo.sync.deviceId')).toBe('device-1');
  });
});

// Contract: accountScopeInvariants.legacyBareKeyClaim
//
// Bare keys written before partitioning existed have a definite account owner. The earlier
// implementation unconditionally assigned them to the first real signed-in account that touched the
// key, so after an account switch on the same machine B would inherit A's records, and these tables go
// into the sync envelope whole.
describe('inheriting a bare key requires evidence that this machine never had a real account', () => {
  const TABLE = 'capability-preference-settings.v2';
  const OTHER_TABLE = 'generation-parameter-settings.v1';

  it('once the watermark belongs to A, B gets neither the bare key content nor the bare key itself', () => {
    // Existing data: two tables written before partitioning shipped, both under bare keys.
    localStorage.setItem(`oriveo.${TABLE}`, '{"records":["record from A"]}');
    localStorage.setItem(`oriveo.${OTHER_TABLE}`, '{"scopes":["params from A"]}');

    // A is the first real account on this machine: it inherits the first table and stamps the account watermark.
    partitionMocks.activeUID = UID_A;
    expect(readPartitionedStore(TABLE)).toBe('{"records":["record from A"]}');
    expect(localStorage.getItem(`oriveo.${TABLE}`)).toBeNull();

    // Switch to B. The second table has not been read yet in A's session, so the bare key is still sitting
    // there untouched, which is exactly the entry point of the incident.
    partitionMocks.activeUID = UID_B;
    expect(readPartitionedStore(OTHER_TABLE)).toBeNull();
    expect(localStorage.getItem(`oriveo.${OTHER_TABLE}`)).toBeNull();
    expect(localStorage.getItem(`oriveo.${UID_B}.${OTHER_TABLE}`)).toBeNull();
  });

  it('when this machine never had a real account, the first real account still inherits, so the upgrade path for existing data is not broken', () => {
    localStorage.setItem(`oriveo.${TABLE}`, '{"records":["existing"]}');

    partitionMocks.activeUID = UID_B;
    expect(readPartitionedStore(TABLE)).toBe('{"records":["existing"]}');
    expect(localStorage.getItem(`oriveo.${TABLE}`)).toBeNull();
  });

  it('guest only copies when the machine has no account watermark; data already owned by a real account is deleted as an orphan', () => {
    localStorage.setItem(`oriveo.${TABLE}`, '{"records":["existing"]}');

    // auth boot briefly hydrates the guest partition first: copy a version and keep the bare key for the
    // first real account.
    partitionMocks.activeUID = 'guest';
    expect(readPartitionedStore(TABLE)).toBe('{"records":["existing"]}');
    expect(localStorage.getItem(`oriveo.${TABLE}`)).toBe('{"records":["existing"]}');

    // A signs in and consumes it, so the watermark lands on A.
    partitionMocks.activeUID = UID_A;
    expect(readPartitionedStore(TABLE)).toBe('{"records":["existing"]}');

    // Once the watermark is set, guest does not inherit a bare key that appears afterwards (existing data of another table).
    localStorage.setItem(`oriveo.${OTHER_TABLE}`, '{"scopes":["params from A"]}');
    partitionMocks.activeUID = 'guest';
    expect(readPartitionedStore(OTHER_TABLE)).toBeNull();
    expect(localStorage.getItem(`oriveo.${OTHER_TABLE}`)).toBeNull();
  });

  it('repeated reads and writes by the same account are idempotent: it still inherits when the watermark is its own', () => {
    localStorage.setItem(`oriveo.${TABLE}`, '{"records":["existing"]}');
    partitionMocks.activeUID = UID_A;
    readPartitionedStore(TABLE);
    // A one-off rewrite of existing data writes back to the bare key; with the watermark on A, A should
    // still inherit it.
    localStorage.setItem(`oriveo.${TABLE}`, '{"records":["rewritten"]}');
    localStorage.removeItem(`oriveo.${UID_A}.${TABLE}`);
    expect(readPartitionedStore(TABLE)).toBe('{"records":["rewritten"]}');
  });
});
