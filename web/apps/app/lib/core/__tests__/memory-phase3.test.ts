/**
 * Phase 3 Memory tests - sync, account and migration
 *
 * Covers:
 * - An old conversation without useMemory defaults to true.
 * - Old data without memory fields does not crash and falls back to correct defaults.
 * - LWW conflict resolution: the newer memoryUpdatedAt wins.
 * - Local-only fields such as memoryUsageCount are not synced.
 * - Empty local memory does not overwrite cloud data.
 * - Clearing memory atomically clears the anti-forget fields.
 * - The Memory LWW merge inside handlePreferencesChange.
 * - The useMemory merge inside handleConversationChanges.
 */
import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { createAppStore } from '../store/app-store';
import type { AppPreference, Conversation } from '@oriveo/shared';
import { updateMemory } from '../preference-ops';

// ── Mock dependencies ───────────────────────────────────────────────────────

const mockSyncAdapter = {
  didUpdatePreferences: vi.fn(),
};

vi.mock('../sync-port', () => ({
  getSyncAdapter: vi.fn(() => mockSyncAdapter),
}));

vi.mock('../../i18n/locale-utils', () => ({
  setLocaleCookie: vi.fn(),
}));

// isNewer is copied from sync-mappings.ts so this suite does not import the sync writer.
function isNewer(dateA: string | undefined, dateB: string | undefined): boolean {
  if (!dateA) return false;
  if (!dateB) return true;
  return new Date(dateA).getTime() > new Date(dateB).getTime();
}

/**
 * Reproduces the Memory LWW merge performed by handlePreferencesChange.
 * Mirrors the logic in sync-handlers.ts.
 */
function applyPreferencesChange(
  data: Record<string, unknown>,
  current: AppPreference,
): { changed: boolean; patch: Partial<AppPreference> } {
  let changed = false;
  const patch: Partial<AppPreference> = {};

  if (typeof data['theme'] === 'string' && data['theme'] !== current.theme) {
    patch.theme = data['theme'] as AppPreference['theme'];
    changed = true;
  }
  if (typeof data['language'] === 'string' && data['language'] !== current.language) {
    patch.language = data['language'] as AppPreference['language'];
    changed = true;
  }

  // Memory LWW
  const remoteMemoryUpdatedAt = typeof data['memoryUpdatedAt'] === 'string' ? data['memoryUpdatedAt'] : undefined;
  if (remoteMemoryUpdatedAt && isNewer(remoteMemoryUpdatedAt, current.memoryUpdatedAt)) {
    if (typeof data['memoryText'] === 'string') {
      patch.memoryText = data['memoryText'];
    } else {
      patch.memoryText = undefined;
    }
    if (typeof data['memoryAntiForgetEnabled'] === 'boolean') {
      patch.memoryAntiForgetEnabled = data['memoryAntiForgetEnabled'];
    } else {
      patch.memoryAntiForgetEnabled = undefined;
    }
    if (typeof data['memoryAntiForgetText'] === 'string') {
      patch.memoryAntiForgetText = data['memoryAntiForgetText'];
    } else {
      patch.memoryAntiForgetText = undefined;
    }
    patch.memoryUpdatedAt = remoteMemoryUpdatedAt;
    changed = true;
  }

  return { changed, patch };
}

/**
 * Reproduces the useMemory merge performed by mergeConversationFields.
 * Mirrors the logic in sync-handlers.ts.
 */
function mergeConversationUseMemory(
  data: Record<string, unknown>,
): boolean | undefined {
  if (typeof data['useMemory'] === 'boolean') return data['useMemory'];
  if (data['useMemory'] === null || !('useMemory' in data)) return undefined;
  return undefined;
}

// ── Helpers ────────────────────────────────────────────────────────────

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'conv-1',
    title: 'Test Chat',
    hasCustomTitle: false,
    providerID: 'p1',
    modelID: 'gpt-4',
    previewText: 'Hello',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: '2026-03-20T10:00:00.000Z',
    ...overrides,
  };
}

describe('MEM-3-08: old conversation missing useMemory field — defaults to true', () => {
  it('useMemory undefined is treated as true, so memory is injected', () => {
    const conv = makeConversation({ useMemory: undefined });
    // Injection condition: conversation?.useMemory !== false
    const useMemory = conv.useMemory !== false;
    expect(useMemory).toBe(true);
  });

  it('a missing useMemory field is treated as true', () => {
    // Old data shape: the Conversation object has no useMemory property at all
    const conv: Record<string, unknown> = {
      id: 'conv-old',
      title: 'Old Chat',
      hasCustomTitle: false,
      providerID: 'p1',
      modelID: 'gpt-3.5',
      previewText: 'Hi',
      estimatedCost: 0,
      isDraft: false,
      messages: [],
      draftText: '',
      updatedAt: '2025-01-01T00:00:00.000Z',
    };
    // No useMemory field
    expect('useMemory' in conv).toBe(false);
    // Reading it yields undefined, and undefined !== false is true
    expect((conv as Conversation).useMemory !== false).toBe(true);
  });

  it('works when useMemory = true', () => {
    const conv = makeConversation({ useMemory: true });
    expect(conv.useMemory !== false).toBe(true);
  });

  it('blocks injection when useMemory = false', () => {
    const conv = makeConversation({ useMemory: false });
    expect(conv.useMemory !== false).toBe(false);
  });
});

describe('MEM-3-20: old version data missing memory fields — no crash, correct defaults', () => {
  it('does not crash when preferences has no memory fields', () => {
    const store = createAppStore();
    const prefs = store.getState().preferences;

    // Every memory field is undefined in the default store
    expect(prefs.memoryText).toBeUndefined();
    expect(prefs.memoryAntiForgetEnabled).toBeUndefined();
    expect(prefs.memoryAntiForgetText).toBeUndefined();
    expect(prefs.memoryUpdatedAt).toBeUndefined();
  });

  it('setPreferences does not crash on an old preferences object with no memory fields', () => {
    const store = createAppStore();
    // Old data hydration: only theme/language/sendShortcut
    store.getState().setPreferences({
      theme: 'dark',
      language: 'en',
      sendShortcut: 'enter',
    });

    const prefs = store.getState().preferences;
    expect(prefs.theme).toBe('dark');
    expect(prefs.memoryText).toBeUndefined();
    expect(prefs.memoryAntiForgetEnabled).toBeUndefined();
  });

  it('memoryUsageCount defaults to 0', () => {
    const store = createAppStore();
    expect(store.getState().memoryUsageCount).toBe(0);
  });

  it('incrementMemoryUsageCount works when there is no memory data', () => {
    const store = createAppStore();
    store.getState().incrementMemoryUsageCount();
    expect(store.getState().memoryUsageCount).toBe(1);
    store.getState().incrementMemoryUsageCount();
    expect(store.getState().memoryUsageCount).toBe(2);
  });

  it('setConversationUseMemory works on an old conversation', () => {
    const store = createAppStore();
    const oldConv = makeConversation({ useMemory: undefined });
    store.getState().addConversation(oldConv);

    store.getState().setConversationUseMemory('conv-1', false);

    const updated = store.getState().conversations.find((c) => c.id === 'conv-1');
    expect(updated?.useMemory).toBe(false);
  });

  it('mergeConversationFields does not crash when a remote document has no useMemory', () => {
    // An old remote document
    const firestoreData: Record<string, unknown> = {
      title: 'Old Chat',
      providerID: 'p1',
      modelID: 'gpt-4',
      // No useMemory field
    };

    const result = mergeConversationUseMemory(firestoreData);
    expect(result).toBeUndefined(); // A missing field returns undefined instead of crashing
  });
});

describe('Sync: LWW conflict resolution — newer timestamp wins', () => {
  it('a newer remote memoryUpdatedAt wins', () => {
    const current: AppPreference = {
      theme: 'system',
      language: 'system',
      sendShortcut: 'enter',
      memoryText: 'Local memory',
      memoryUpdatedAt: '2026-03-20T09:00:00.000Z',
    };

    const remoteData = {
      memoryText: 'Remote memory',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Remote summary',
      memoryUpdatedAt: '2026-03-20T10:00:00.000Z', // Newer
    };

    const { changed, patch } = applyPreferencesChange(remoteData, current);
    expect(changed).toBe(true);
    expect(patch.memoryText).toBe('Remote memory');
    expect(patch.memoryAntiForgetEnabled).toBe(true);
    expect(patch.memoryAntiForgetText).toBe('Remote summary');
    expect(patch.memoryUpdatedAt).toBe('2026-03-20T10:00:00.000Z');
  });

  it('an older remote memoryUpdatedAt keeps the local value', () => {
    const current: AppPreference = {
      theme: 'system',
      language: 'system',
      sendShortcut: 'enter',
      memoryText: 'Local memory',
      memoryUpdatedAt: '2026-03-20T10:00:00.000Z',
    };

    const remoteData = {
      memoryText: 'Old remote memory',
      memoryUpdatedAt: '2026-03-20T09:00:00.000Z', // Older
    };

    const { changed, patch } = applyPreferencesChange(remoteData, current);
    expect(changed).toBe(false);
    expect(patch.memoryText).toBeUndefined();
  });

  it('an identical remote memoryUpdatedAt changes nothing', () => {
    const timestamp = '2026-03-20T10:00:00.000Z';
    const current: AppPreference = {
      theme: 'system',
      language: 'system',
      sendShortcut: 'enter',
      memoryText: 'Local memory',
      memoryUpdatedAt: timestamp,
    };

    const remoteData = {
      memoryText: 'Different text same timestamp',
      memoryUpdatedAt: timestamp,
    };

    const { changed, patch } = applyPreferencesChange(remoteData, current);
    expect(changed).toBe(false);
    expect(patch.memoryText).toBeUndefined();
  });

  it('no local memoryUpdatedAt plus a remote one takes the remote value', () => {
    const current: AppPreference = {
      theme: 'system',
      language: 'system',
      sendShortcut: 'enter',
      // No memory fields
    };

    const remoteData = {
      memoryText: 'Remote memory',
      memoryUpdatedAt: '2026-03-20T10:00:00.000Z',
    };

    const { changed, patch } = applyPreferencesChange(remoteData, current);
    expect(changed).toBe(true);
    expect(patch.memoryText).toBe('Remote memory');
  });

  it('a remote document without memoryUpdatedAt does not overwrite local', () => {
    const current: AppPreference = {
      theme: 'system',
      language: 'system',
      sendShortcut: 'enter',
      memoryText: 'Local memory',
      memoryUpdatedAt: '2026-03-20T10:00:00.000Z',
    };

    const remoteData = {
      memoryText: 'Remote without timestamp',
      // No memoryUpdatedAt
    };

    const { changed, patch } = applyPreferencesChange(remoteData, current);
    expect(changed).toBe(false);
    expect(patch.memoryText).toBeUndefined();
  });
});

describe('Sync: local-only fields (memoryUsageCount, memoryHasSeen) not synced', () => {
  it('memoryUsageCount lives only in AppState, not in AppPreference', () => {
    const store = createAppStore();
    store.getState().incrementMemoryUsageCount();
    store.getState().incrementMemoryUsageCount();
    store.getState().incrementMemoryUsageCount();

    expect(store.getState().memoryUsageCount).toBe(3);

    // memoryUsageCount is not part of preferences
    const prefs = store.getState().preferences;
    expect('memoryUsageCount' in prefs).toBe(false);
  });

  it('the preferences sync payload carries no memoryUsageCount', () => {
    const store = createAppStore();
    store.getState().incrementMemoryUsageCount();

    // What updateMemory pushes to sync contains no memoryUsageCount
    updateMemory(store, 'Test memory', false, undefined);

    const syncCall = mockSyncAdapter.didUpdatePreferences.mock.calls[0][0];
    expect(syncCall).not.toHaveProperty('memoryUsageCount');
    expect(syncCall).toHaveProperty('memoryText');
    expect(syncCall).toHaveProperty('memoryUpdatedAt');
  });
});

describe('Sync: empty local memory does not overwrite cloud data', () => {
  it('a remote memoryText with a newer timestamp overwrites the empty local value', () => {
    const current: AppPreference = {
      theme: 'system',
      language: 'system',
      sendShortcut: 'enter',
      // No local memory
    };

    const remoteData = {
      memoryText: 'Cloud memory',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Cloud summary',
      memoryUpdatedAt: '2026-03-20T10:00:00.000Z',
    };

    const { changed, patch } = applyPreferencesChange(remoteData, current);
    expect(changed).toBe(true);
    expect(patch.memoryText).toBe('Cloud memory');
    expect(patch.memoryAntiForgetEnabled).toBe(true);
  });

  it('a missing remote memoryText with a memoryUpdatedAt sets patch.memoryText to undefined', () => {
    const current: AppPreference = {
      theme: 'system',
      language: 'system',
      sendShortcut: 'enter',
      memoryText: 'Local memory',
      memoryUpdatedAt: '2026-03-20T08:00:00.000Z',
    };

    // The remote side cleared memory: a timestamp but no memoryText
    const remoteData = {
      memoryUpdatedAt: '2026-03-20T10:00:00.000Z',
    };

    const { changed, patch } = applyPreferencesChange(remoteData, current);
    expect(changed).toBe(true);
    expect(patch.memoryText).toBeUndefined();
    expect(patch.memoryAntiForgetEnabled).toBeUndefined();
    expect(patch.memoryAntiForgetText).toBeUndefined();
  });
});

describe('Sync: clear memory atomically clears anti-forget fields', () => {
  let store: ReturnType<typeof createAppStore>;

  beforeEach(() => {
    store = createAppStore();
    vi.clearAllMocks();
  });

  it('clearing through updateMemory sets every memory field to undefined', () => {
    // Set first
    updateMemory(store, 'Memory text', true, 'Anti-forget summary');
    vi.clearAllMocks();

    // Clear
    updateMemory(store, '', false, '');

    const prefs = store.getState().preferences;
    expect(prefs.memoryText).toBeUndefined();
    expect(prefs.memoryAntiForgetEnabled).toBeUndefined();
    expect(prefs.memoryAntiForgetText).toBeUndefined();
    // memoryUpdatedAt still holds a value, recording when it was cleared
    expect(prefs.memoryUpdatedAt).toBeDefined();
  });

  it('the patch pushed to sync has undefined memory fields after clearing', () => {
    updateMemory(store, 'Text', true, 'Summary');
    vi.clearAllMocks();

    updateMemory(store, '', false, '');

    const syncPatch = mockSyncAdapter.didUpdatePreferences.mock.calls[0][0];
    expect(syncPatch.memoryText).toBeUndefined();
    expect(syncPatch.memoryAntiForgetEnabled).toBeUndefined();
    expect(syncPatch.memoryAntiForgetText).toBeUndefined();
    expect(syncPatch.memoryUpdatedAt).toBeDefined();
  });

  it('a whitespace-only memoryText counts as cleared', () => {
    updateMemory(store, '   \n\t  ', true, 'Summary');

    const prefs = store.getState().preferences;
    expect(prefs.memoryText).toBeUndefined();
    expect(prefs.memoryAntiForgetEnabled).toBeUndefined();
    expect(prefs.memoryAntiForgetText).toBeUndefined();
  });
});

describe('handlePreferencesChange: Memory LWW merge', () => {
  it('a remote update of every memory field', () => {
    const current: AppPreference = {
      theme: 'system',
      language: 'system',
      sendShortcut: 'enter',
      memoryText: 'Old',
      memoryAntiForgetEnabled: false,
      memoryAntiForgetText: 'Old summary',
      memoryUpdatedAt: '2026-03-20T08:00:00.000Z',
    };

    const remoteData = {
      memoryText: 'New memory',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'New summary',
      memoryUpdatedAt: '2026-03-20T12:00:00.000Z',
    };

    const { changed, patch } = applyPreferencesChange(remoteData, current);
    expect(changed).toBe(true);
    expect(patch.memoryText).toBe('New memory');
    expect(patch.memoryAntiForgetEnabled).toBe(true);
    expect(patch.memoryAntiForgetText).toBe('New summary');
    expect(patch.memoryUpdatedAt).toBe('2026-03-20T12:00:00.000Z');
  });

  it('a remote update of only memoryText clears the anti-forget fields', () => {
    const current: AppPreference = {
      theme: 'system',
      language: 'system',
      sendShortcut: 'enter',
      memoryText: 'Old',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Old summary',
      memoryUpdatedAt: '2026-03-20T08:00:00.000Z',
    };

    const remoteData = {
      memoryText: 'Updated text only',
      // The remote side has no memoryAntiForgetEnabled or memoryAntiForgetText
      memoryUpdatedAt: '2026-03-20T12:00:00.000Z',
    };

    const { changed, patch } = applyPreferencesChange(remoteData, current);
    expect(changed).toBe(true);
    expect(patch.memoryText).toBe('Updated text only');
    // Missing fields are set to undefined
    expect(patch.memoryAntiForgetEnabled).toBeUndefined();
    expect(patch.memoryAntiForgetText).toBeUndefined();
  });

  it('a theme change leaves the memory fields alone', () => {
    const current: AppPreference = {
      theme: 'light',
      language: 'system',
      sendShortcut: 'enter',
      memoryText: 'My memory',
      memoryUpdatedAt: '2026-03-20T10:00:00.000Z',
    };

    const remoteData = {
      theme: 'dark',
    };

    const { changed, patch } = applyPreferencesChange(remoteData, current);
    expect(changed).toBe(true);
    expect(patch.theme).toBe('dark');
    expect(patch.memoryText).toBeUndefined(); // Not touched by the patch
  });
});

describe('handleConversationChanges: useMemory field merge', () => {
  it('a remote document with useMemory: true merges to true', () => {
    const result = mergeConversationUseMemory({ useMemory: true });
    expect(result).toBe(true);
  });

  it('a remote document with useMemory: false merges to false', () => {
    const result = mergeConversationUseMemory({ useMemory: false });
    expect(result).toBe(false);
  });

  it('a remote useMemory of null merges to undefined', () => {
    const result = mergeConversationUseMemory({ useMemory: null });
    expect(result).toBeUndefined();
  });

  it('a remote document without useMemory merges to undefined', () => {
    const result = mergeConversationUseMemory({ title: 'Chat' });
    expect(result).toBeUndefined();
  });

  it('a non-boolean remote useMemory merges to undefined', () => {
    const result = mergeConversationUseMemory({ useMemory: 'yes' as unknown });
    expect(result).toBeUndefined();
  });
});

describe('Store: setConversationUseMemory', () => {
  let store: ReturnType<typeof createAppStore>;

  beforeEach(() => {
    store = createAppStore();
    const conv = makeConversation();
    store.getState().addConversation(conv);
  });

  it('sets useMemory = false', () => {
    store.getState().setConversationUseMemory('conv-1', false);
    const conv = store.getState().conversations.find((c) => c.id === 'conv-1');
    expect(conv?.useMemory).toBe(false);
  });

  it('sets useMemory = true', () => {
    store.getState().setConversationUseMemory('conv-1', true);
    const conv = store.getState().conversations.find((c) => c.id === 'conv-1');
    expect(conv?.useMemory).toBe(true);
  });

  it('leaves updatedAt alone, so a metadata change does not affect ordering', () => {
    const before = store.getState().conversations[0].updatedAt;

    store.getState().setConversationUseMemory('conv-1', false);

    const conv = store.getState().conversations.find((c) => c.id === 'conv-1');
    expect(conv?.updatedAt).toBe(before);
  });

  it('does not crash on a conversation id that does not exist', () => {
    expect(() => {
      store.getState().setConversationUseMemory('non-existent-id', false);
    }).not.toThrow();
    // The existing conversation is untouched
    expect(store.getState().conversations).toHaveLength(1);
  });
});

describe('Store: incrementMemoryUsageCount', () => {
  it('increments from 0', () => {
    const store = createAppStore();
    expect(store.getState().memoryUsageCount).toBe(0);
    store.getState().incrementMemoryUsageCount();
    expect(store.getState().memoryUsageCount).toBe(1);
  });

  it('increments repeatedly', () => {
    const store = createAppStore();
    for (let i = 0; i < 5; i++) {
      store.getState().incrementMemoryUsageCount();
    }
    expect(store.getState().memoryUsageCount).toBe(5);
  });

  it('increments from a custom initial value', () => {
    const store = createAppStore({ memoryUsageCount: 42 });
    store.getState().incrementMemoryUsageCount();
    expect(store.getState().memoryUsageCount).toBe(43);
  });
});

describe('Integration: full sync lifecycle simulation', () => {
  let store: ReturnType<typeof createAppStore>;

  beforeEach(() => {
    store = createAppStore();
    vi.clearAllMocks();
  });

  it('local update, sync push, remote change written back, LWW merge', () => {
    // 1. Update memory locally
    updateMemory(store, 'My preference: concise answers', true, 'Keep it short');
    const localPrefs = store.getState().preferences;
    expect(localPrefs.memoryText).toBe('My preference: concise answers');
    expect(localPrefs.memoryAntiForgetEnabled).toBe(true);
    expect(localPrefs.memoryAntiForgetText).toBe('Keep it short');

    // 2. Check the sync push
    expect(mockSyncAdapter.didUpdatePreferences).toHaveBeenCalledTimes(1);
    const pushed = mockSyncAdapter.didUpdatePreferences.mock.calls[0][0];
    expect(pushed.memoryText).toBe('My preference: concise answers');

    // 3. Remote change written back with a newer timestamp
    const remoteData = {
      memoryText: 'Updated from iPad',
      memoryAntiForgetEnabled: false,
      memoryUpdatedAt: '2099-01-01T00:00:00.000Z', // Clearly newer than local
    };

    const { changed, patch } = applyPreferencesChange(remoteData, store.getState().preferences);
    expect(changed).toBe(true);

    // 4. Apply the patch
    store.getState().setPreferences(patch);
    const finalPrefs = store.getState().preferences;
    expect(finalPrefs.memoryText).toBe('Updated from iPad');
    expect(finalPrefs.memoryAntiForgetEnabled).toBe(false);
    // The remote side has no memoryAntiForgetText, so it becomes undefined
    expect(finalPrefs.memoryAntiForgetText).toBeUndefined();
  });

  it('first sync on an old device: no local memory, remote has it, merged correctly', () => {
    // 1. The store starts with no memory
    expect(store.getState().preferences.memoryText).toBeUndefined();
    expect(store.getState().preferences.memoryUpdatedAt).toBeUndefined();

    // 2. Remote data arrives
    const remoteData = {
      memoryText: 'I am a Go engineer',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Prefer Go',
      memoryUpdatedAt: '2026-03-20T10:00:00.000Z',
    };

    const { changed, patch } = applyPreferencesChange(remoteData, store.getState().preferences);
    expect(changed).toBe(true);

    store.getState().setPreferences(patch);
    const prefs = store.getState().preferences;
    expect(prefs.memoryText).toBe('I am a Go engineer');
    expect(prefs.memoryAntiForgetEnabled).toBe(true);
    expect(prefs.memoryAntiForgetText).toBe('Prefer Go');
    expect(prefs.memoryUpdatedAt).toBe('2026-03-20T10:00:00.000Z');
  });
});
