import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { createAppStore } from '../store/app-store';
import { updateTheme, updateLanguage, updateMemory } from '../preference-ops';

const mockSyncAdapter = {
  didUpdatePreferences: vi.fn(),
};

vi.mock('../sync-port', () => ({
  getSyncAdapter: vi.fn(() => mockSyncAdapter),
}));

vi.mock('../../i18n/locale-utils', () => ({
  setLocaleCookie: vi.fn(),
}));

import { setLocaleCookie } from '../../i18n/locale-utils';

describe('preference-ops', () => {
  let store: ReturnType<typeof createAppStore>;

  beforeEach(() => {
    store = createAppStore();
    vi.clearAllMocks();
  });

  it('updateTheme — setPreferences + sync.didUpdatePreferences', () => {
    updateTheme(store, 'dark');
    expect(store.getState().preferences.theme).toBe('dark');
    expect(mockSyncAdapter.didUpdatePreferences).toHaveBeenCalledWith({ theme: 'dark' });
  });

  it('updateLanguage — setPreferences + sync + setLocaleCookie', () => {
    updateLanguage(store, 'ja');
    expect(store.getState().preferences.language).toBe('ja');
    expect(mockSyncAdapter.didUpdatePreferences).toHaveBeenCalledWith({ language: 'ja' });
    expect(setLocaleCookie).toHaveBeenCalledWith('ja');
  });

  describe('updateMemory', () => {
    it('saves the memory text and the anti-forget settings', () => {
      updateMemory(store, 'I am an engineer', true, 'Keep concise');

      const prefs = store.getState().preferences;
      expect(prefs.memoryText).toBe('I am an engineer');
      expect(prefs.memoryAntiForgetEnabled).toBe(true);
      expect(prefs.memoryAntiForgetText).toBe('Keep concise');
      expect(prefs.memoryUpdatedAt).toBeDefined();
      expect(mockSyncAdapter.didUpdatePreferences).toHaveBeenCalledTimes(1);
    });

    it('clears the anti-forget fields when memoryText is cleared', () => {
      // Set first
      updateMemory(store, 'Some text', true, 'Summary');
      vi.clearAllMocks();

      // Clear
      updateMemory(store, '', false, '');

      const prefs = store.getState().preferences;
      expect(prefs.memoryText).toBeUndefined();
      expect(prefs.memoryAntiForgetEnabled).toBeUndefined();
      expect(prefs.memoryAntiForgetText).toBeUndefined();
      expect(prefs.memoryUpdatedAt).toBeDefined();
      expect(mockSyncAdapter.didUpdatePreferences).toHaveBeenCalledTimes(1);
    });

    it('treats a whitespace-only memoryText as cleared and clears every memory field', () => {
      updateMemory(store, '   ', true, 'Summary');

      const prefs = store.getState().preferences;
      expect(prefs.memoryText).toBeUndefined();
      expect(prefs.memoryAntiForgetEnabled).toBeUndefined();
      expect(prefs.memoryAntiForgetText).toBeUndefined();
      expect(prefs.memoryUpdatedAt).toBeDefined();
    });

    it('sets memoryUpdatedAt in ISO 8601 format', () => {
      updateMemory(store, 'Test memory', false, undefined);

      const prefs = store.getState().preferences;
      // ISO 8601 check: Date can parse it and toISOString() round-trips
      expect(prefs.memoryUpdatedAt).toBeDefined();
      const parsed = new Date(prefs.memoryUpdatedAt!);
      expect(parsed.toISOString()).toBe(prefs.memoryUpdatedAt);
    });

    it('still sets memoryUpdatedAt when clearing, recording when it was cleared', () => {
      updateMemory(store, 'Text', true, 'Summary');
      vi.clearAllMocks();

      updateMemory(store, '', false, '');

      const prefs = store.getState().preferences;
      expect(prefs.memoryUpdatedAt).toBeDefined();
      const parsed = new Date(prefs.memoryUpdatedAt!);
      expect(parsed.toISOString()).toBe(prefs.memoryUpdatedAt);
    });

    it('keeps every field when saving a non-empty memory', () => {
      updateMemory(store, 'I prefer Go', true, 'Keep responses concise');

      const prefs = store.getState().preferences;
      expect(prefs.memoryText).toBe('I prefer Go');
      expect(prefs.memoryAntiForgetEnabled).toBe(true);
      expect(prefs.memoryAntiForgetText).toBe('Keep responses concise');
      expect(prefs.memoryUpdatedAt).toBeDefined();
    });

    it('pushes the change through the sync adapter', () => {
      updateMemory(store, 'Test', false, undefined);

      expect(mockSyncAdapter.didUpdatePreferences).toHaveBeenCalledWith(
        expect.objectContaining({
          memoryText: 'Test',
          memoryAntiForgetEnabled: false,
          memoryUpdatedAt: expect.any(String),
        }),
      );
    });
  });
});
