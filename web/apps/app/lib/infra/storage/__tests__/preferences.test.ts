// @vitest-environment jsdom
//
// Unit tests for the cross-account memory leak fix: preferences are partitioned by
// activeUID, and existing data is migrated once.

import { describe, it, expect, beforeEach, vi } from 'vitest';

// getActiveUIDSync is a synchronous mirror; a mutable holder simulates switching partitions.
const uidHolder = vi.hoisted(() => ({ uid: 'guest' }));
vi.mock('../partition', () => ({
  getActiveUIDSync: () => uidHolder.uid,
}));

import { getPreference, setPreference, removePreference } from '../preferences';

describe('preferences per-UID isolation', () => {
  beforeEach(() => {
    localStorage.clear();
    uidHolder.uid = 'guest';
  });

  it('setPreference writes a key scoped to activeUID', () => {
    uidHolder.uid = 'user-A';
    setPreference('preferences', { memoryText: 'memory for A' });
    expect(localStorage.getItem('oriveo.user-A.preferences')).toBe(
      JSON.stringify({ memoryText: 'memory for A' }),
    );
    // The old global key must not be written.
    expect(localStorage.getItem('oriveo.preferences')).toBeNull();
  });

  it('one UID cannot read another UID preferences, which is the core leak', () => {
    uidHolder.uid = 'user-A';
    setPreference('preferences', { memoryText: 'memory for A' });

    // Switch to the other account; it must read the fallback, not account A's memory.
    uidHolder.uid = 'user-B';
    expect(getPreference('preferences', { memoryText: '' })).toEqual({ memoryText: '' });

    // The guest partition is separate too.
    uidHolder.uid = 'guest';
    expect(getPreference('preferences', { memoryText: '' })).toEqual({ memoryText: '' });
  });

  it('expectedUID pins a late import to the account that started it', () => {
    uidHolder.uid = 'user-B';

    setPreference('preferences', { memoryText: 'imported value for A' }, 'user-A');

    expect(getPreference('preferences', { memoryText: '' }, 'user-A')).toEqual({
      memoryText: 'imported value for A',
    });
    expect(getPreference('preferences', { memoryText: '' }, 'user-B')).toEqual({ memoryText: '' });
  });

  it('removePreference only clears the key of the current UID', () => {
    uidHolder.uid = 'user-A';
    setPreference('pinnedConversationIds', ['c1']);
    uidHolder.uid = 'user-B';
    setPreference('pinnedConversationIds', ['c2']);

    uidHolder.uid = 'user-A';
    removePreference('pinnedConversationIds');
    expect(localStorage.getItem('oriveo.user-A.pinnedConversationIds')).toBeNull();
    // Account B keeps its own value.
    expect(localStorage.getItem('oriveo.user-B.pinnedConversationIds')).toBe(JSON.stringify(['c2']));
  });
});

describe('one-time migration of existing preferences', () => {
  beforeEach(() => {
    localStorage.clear();
    uidHolder.uid = 'guest';
  });

  it('a real account read migrates the old global value to a UID key and deletes the old global key, so the first signed-in account inherits it', () => {
    // Simulate pre-upgrade data: the old global key holds a memory.
    localStorage.setItem('oriveo.preferences', JSON.stringify({ memoryText: 'existing user memory' }));

    uidHolder.uid = 'user-A';
    const value = getPreference('preferences', { memoryText: '' });
    expect(value).toEqual({ memoryText: 'existing user memory' });
    // The value is now stored under user-A.
    expect(localStorage.getItem('oriveo.user-A.preferences')).toBe(
      JSON.stringify({ memoryText: 'existing user memory' }),
    );
    // The old global key is deleted after the migration.
    expect(localStorage.getItem('oriveo.preferences')).toBeNull();
  });

  it('a second account reads nothing once the old global key is deleted, preventing cross-account contamination', () => {
    localStorage.setItem('oriveo.preferences', JSON.stringify({ memoryText: 'existing user memory' }));

    uidHolder.uid = 'user-A';
    getPreference('preferences', { memoryText: '' }); // user-A claims the value

    uidHolder.uid = 'user-B';
    expect(getPreference('preferences', { memoryText: '' })).toEqual({ memoryText: '' });
  });

  it('a guest migration only copies the old global key without deleting it, so it does not steal it from the first real sign-in', () => {
    localStorage.setItem('oriveo.preferences', JSON.stringify({ memoryText: 'existing user memory' }));

    // auth boot briefly hydrates as guest first.
    uidHolder.uid = 'guest';
    expect(getPreference('preferences', { memoryText: '' })).toEqual({ memoryText: 'existing user memory' });
    // guest gets a copy while the old global key stays in place.
    expect(localStorage.getItem('oriveo.guest.preferences')).toBe(
      JSON.stringify({ memoryText: 'existing user memory' }),
    );
    expect(localStorage.getItem('oriveo.preferences')).not.toBeNull();

    // The first real sign-in then takes it over.
    uidHolder.uid = 'user-A';
    expect(getPreference('preferences', { memoryText: '' })).toEqual({ memoryText: 'existing user memory' });
    // The old global key is gone once a real account claimed it.
    expect(localStorage.getItem('oriveo.preferences')).toBeNull();
  });

  it('an existing per-UID value is not overwritten by the old global key', () => {
    uidHolder.uid = 'user-A';
    setPreference('preferences', { memoryText: 'new value' });
    // An old global key that appears later must not overwrite an existing per-UID value.
    localStorage.setItem('oriveo.preferences', JSON.stringify({ memoryText: 'old value' }));
    expect(getPreference('preferences', { memoryText: '' })).toEqual({ memoryText: 'new value' });
  });

  // What is inherited here is memoryText and the pinned list, which are more sensitive
  // than the model control tables, so the test must match the one in partitioned-local-store.
  it('once this device belongs to account A, B inherits no old global key and the old global key is deleted', () => {
    // A is the first real account on this device: one preferences read claims the device and consumes that existing value.
    localStorage.setItem('oriveo.preferences', JSON.stringify({ memoryText: 'memory for A' }));
    uidHolder.uid = 'user-A';
    getPreference('preferences', { memoryText: '' });

    // The other existing key was never read during A's session, so the bare key is still sitting there.
    localStorage.setItem('oriveo.pinnedConversationIds', JSON.stringify(['conversation for A']));

    uidHolder.uid = 'user-B';
    expect(getPreference('pinnedConversationIds', [])).toEqual([]);
    expect(localStorage.getItem('oriveo.pinnedConversationIds')).toBeNull();
    expect(localStorage.getItem('oriveo.user-B.pinnedConversationIds')).toBeNull();
  });

  it('guest inherits nothing once the device belongs to a real account, since the unowned precondition no longer holds', () => {
    localStorage.setItem('oriveo.preferences', JSON.stringify({ memoryText: 'memory for A' }));
    uidHolder.uid = 'user-A';
    getPreference('preferences', { memoryText: '' });

    localStorage.setItem('oriveo.pinnedConversationIds', JSON.stringify(['conversation for A']));
    uidHolder.uid = 'guest';
    expect(getPreference('pinnedConversationIds', [])).toEqual([]);
    expect(localStorage.getItem('oriveo.pinnedConversationIds')).toBeNull();
  });

  it('migration is idempotent: repeated gets neither migrate again nor contaminate anything', () => {
    localStorage.setItem('oriveo.preferences', JSON.stringify({ memoryText: 'existing user memory' }));
    uidHolder.uid = 'user-A';
    getPreference('preferences', { memoryText: '' });
    getPreference('preferences', { memoryText: '' });
    getPreference('preferences', { memoryText: '' });
    expect(localStorage.getItem('oriveo.user-A.preferences')).toBe(
      JSON.stringify({ memoryText: 'existing user memory' }),
    );
    expect(localStorage.getItem('oriveo.preferences')).toBeNull();
  });
});
