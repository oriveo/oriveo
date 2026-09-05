import { describe, expect, it } from 'vitest';
import { createAppStore } from '../app-store';

describe('library slice', () => {
  it('stores connections, quota, progress, and confirmation', () => {
    const store = createAppStore();
    const connection = {
      id: 'notion-1',
      provider: 'notion' as const,
      displayName: 'Workspace',
      scopes: ['page-1'],
      status: 'active' as const,
    };
    const steps = [{
      id: '1:search', step: 1, tool: 'library_search' as const, label: 'roadmap', status: 'running' as const,
    }];
    const confirmation = { id: 'confirm-1', reason: 'sensitive' as const, detail: { docTitles: ['Roadmap'] } };

    store.getState().setLibraryConnections([connection]);
    store.getState().setLibraryQuota({ used: 3, limit: 10, remaining: 7 });
    store.getState().setLibraryConnectionQuota({ used: 1, limit: 1, remaining: 0 });
    store.getState().setLibraryLoadState('error', 'library_source_error');
    store.getState().setLibraryResearchEnabled(true);
    store.getState().setLibraryResearchSteps('conv-1', steps);
    store.getState().setLibraryConfirmation(confirmation);

    expect(store.getState()).toMatchObject({
      libraryConnections: [connection],
      libraryQuota: { used: 3, limit: 10, remaining: 7 },
      libraryConnectionQuota: { used: 1, limit: 1, remaining: 0 },
      libraryLoadState: 'error',
      libraryErrorCode: 'library_source_error',
      libraryResearchEnabled: true,
      libraryResearchSteps: { 'conv-1': steps },
      libraryConfirmation: confirmation,
    });
  });

  it('resets all account-scoped Library state', () => {
    const store = createAppStore({
      libraryConnections: [{ id: 'notion-1', provider: 'notion', displayName: 'Workspace', scopes: [], status: 'active' }],
      libraryQuota: { used: 4, limit: 5, remaining: 1 },
      libraryConnectionQuota: { used: 1, limit: 1, remaining: 0 },
      libraryLoadState: 'ready',
      libraryResearchEnabled: true,
      libraryResearchSteps: { 'conv-1': [{ id: '1', step: 1, tool: 'library_list', label: 'notion', status: 'completed' }] },
      libraryConfirmation: { id: 'confirm-1', reason: 'broad_read', detail: {} },
    });

    store.getState().resetLibraryState();

    expect(store.getState()).toMatchObject({
      libraryConnections: [], libraryQuota: null, libraryConnectionQuota: null,
      libraryLoadState: 'idle', libraryErrorCode: null,
      libraryResearchEnabled: false, libraryResearchSteps: {}, libraryConfirmation: null,
    });
  });
});
