import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Resilience behavior assertions: hydrate failures report to Sentry, the refreshProviderMetadata
// cancelled sentinel, pin cloud-push throttling, and conversation debounce calling clearTimeout on
// unsubscribe.
// Everything runs on mocks plus fake timers, isolated from persistence.test.ts (which uses a real IDB),
// so this file must be run on its own.

const h = vi.hoisted(() => ({
  captureException: vi.fn(),
  getAllProviders: vi.fn(),
  getAllConversations: vi.fn(),
  getAllFolders: vi.fn(),
  getAllNotes: vi.fn(),
  getAllNoteFolders: vi.fn(),
  getSessionValue: vi.fn(),
  putConversationsBatch: vi.fn(),
  putProvider: vi.fn(),
  deleteProvider: vi.fn(),
  putConversation: vi.fn(),
  putConversationPreservingHydratedMessages: vi.fn(),
  deleteConversation: vi.fn(),
  putFolder: vi.fn(),
  deleteFolder: vi.fn(),
  setSessionValue: vi.fn(),
  deleteImage: vi.fn(),
  getPreference: vi.fn((_key: string, fallback: unknown) => fallback),
  setPreference: vi.fn(),
  removePreference: vi.fn(),
  getSyncAdapter: vi.fn(),
  initMetadata: vi.fn(async () => {}),
  enrichStoredModel: vi.fn((m: unknown) => ({ ...(m as object) })),
  deduplicateByCanonical: vi.fn((x: unknown) => x),
  assignFolderColors: vi.fn(),
  readStreamPartialBackup: vi.fn(() => ({})),
  clearStreamPartialBackup: vi.fn(),
  addBreadcrumb: vi.fn(),
  didUpdatePreferences: vi.fn(),
  // A mutable synchronous activeUID mirror, used to simulate a partition switch during a debounce.
  activeUID: 'user-A',
}));

vi.mock('@sentry/nextjs', () => ({
  captureException: h.captureException,
  addBreadcrumb: h.addBreadcrumb,
}));
vi.mock('../../../infra/storage/idb', () => ({
  getAllProviders: h.getAllProviders,
  getAllConversations: h.getAllConversations,
  getAllFolders: h.getAllFolders,
  getAllNotes: h.getAllNotes,
  getAllNoteFolders: h.getAllNoteFolders,
  getSessionValue: h.getSessionValue,
  putConversationsBatch: h.putConversationsBatch,
  putProvider: h.putProvider,
  deleteProvider: h.deleteProvider,
  putConversation: h.putConversation,
  putConversationPreservingHydratedMessages: h.putConversationPreservingHydratedMessages,
  deleteConversation: h.deleteConversation,
  putFolder: h.putFolder,
  deleteFolder: h.deleteFolder,
  setSessionValue: h.setSessionValue,
}));
vi.mock('../../../infra/storage/image-store', () => ({ deleteImage: h.deleteImage }));
vi.mock('../../../infra/storage/preferences', () => ({
  getPreference: h.getPreference,
  setPreference: h.setPreference,
  removePreference: h.removePreference,
}));
vi.mock('../../sync-port', () => ({ getSyncAdapter: h.getSyncAdapter }));
vi.mock('../../metadata/metadata-client', () => ({ initMetadata: h.initMetadata }));
vi.mock('../../providers/catalog-model', () => ({
  enrichStoredModel: h.enrichStoredModel,
  deduplicateByCanonical: h.deduplicateByCanonical,
}));
vi.mock('../../folder-ops', () => ({ assignFolderColors: h.assignFolderColors }));
vi.mock('../stream-partial-backup', () => ({
  readStreamPartialBackup: h.readStreamPartialBackup,
  clearStreamPartialBackup: h.clearStreamPartialBackup,
}));
vi.mock('../../../infra/storage/partition', () => ({
  getActiveUIDSync: () => h.activeUID,
}));

import { createAppStore } from '../app-store';
import { hydrateStore, refreshProviderMetadata } from '../persistence';
import { subscribePinned, subscribeConversations } from '../persistence-subscribers';
import type { Provider, Conversation } from '@oriveo/shared';

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'p1', kind: 'openAI', status: { kind: 'connected' },
    models: [{ id: 'm1', name: 'M1', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '' }],
    catalogModels: [], apiKey: 'sk', apiKeyPreview: '••', ...overrides,
  };
}
function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'c1', title: 'T', hasCustomTitle: false, providerID: 'p1', modelID: 'm1',
    previewText: '', estimatedCost: 0, isDraft: false, messages: [], draftText: '',
    updatedAt: new Date().toISOString(), ...overrides,
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  h.activeUID = 'user-A';
  h.getPreference.mockImplementation((_key: string, fallback: unknown) => fallback);
  h.getAllProviders.mockResolvedValue([]);
  h.getAllConversations.mockResolvedValue([]);
  h.getAllFolders.mockResolvedValue([]);
  h.getAllNotes.mockResolvedValue([]);
  h.getAllNoteFolders.mockResolvedValue([]);
  h.getSessionValue.mockResolvedValue(null);
  h.putConversationPreservingHydratedMessages.mockResolvedValue(true);
  h.readStreamPartialBackup.mockReturnValue({});
  h.initMetadata.mockImplementation(async () => {});
  h.enrichStoredModel.mockImplementation((m: unknown) => ({ ...(m as object) }));
  h.deduplicateByCanonical.mockImplementation((x: unknown) => x);
  h.getSyncAdapter.mockReturnValue({ didUpdatePreferences: h.didUpdatePreferences });
});

describe('hydrateStore reports failures to Sentry', () => {
  it('falls back silently when an IDB read throws but still reports through captureException', async () => {
    h.getAllProviders.mockRejectedValue(new Error('idb boom'));
    h.getAllConversations.mockResolvedValue([]);
    h.getAllFolders.mockResolvedValue([]);
    h.getSessionValue.mockResolvedValue(null);

    const store = createAppStore();
    await hydrateStore(store);

    expect(h.captureException).toHaveBeenCalledTimes(1);
    expect(h.captureException.mock.calls[0][1]).toMatchObject({ tags: { module: 'store.hydrate' } });
    // Hydration failed, but the app still starts - with an empty list rather than stale data.
    expect(store.getState().providers).toEqual([]);
  });
});

describe('hydrateStore stream partial recovery', () => {
  it('restores Managed replay anchors from sessionStorage backup when marking stuck streams interrupted', async () => {
    h.getAllConversations.mockResolvedValue([
      makeConversation({
        id: 'c1',
        providerID: 'catalog-provider',
        providerKind: 'openAI',
        modelID: 'gpt-4.1',
        messages: [
          {
            id: 'a1',
            role: 'assistant',
            text: 'short',
            providerID: 'catalog-provider',
            providerKind: 'openAI',
            providerMode: 'managed',
            providerName: 'a user-owned provider',
            modelID: 'gpt-4.1',
            modelName: 'GPT-4.1',
            estimatedCost: 0,
            state: 'generating',
            createdAt: '2026-05-12T00:00:00.000Z',
          },
        ],
      }),
    ]);
    h.readStreamPartialBackup.mockReturnValue({
      c1: {
        conversationId: 'c1',
        msgId: 'a1',
        partial: 'longer partial',
        ts: 1,
        managedRequestId: 'mreq_1',
        lastSseSequence: 7,
      },
    });

    const store = createAppStore();
    await hydrateStore(store);

    expect(h.putConversationsBatch).toHaveBeenCalledTimes(1);
    const [written] = h.putConversationsBatch.mock.calls[0][0] as Conversation[];
    expect(written.messages[0]).toMatchObject({
      id: 'a1',
      text: 'longer partial',
      state: 'interrupted',
      providerMode: 'managed',
      managedRequestId: 'mreq_1',
      lastSseSequence: 7,
    });
    expect(h.clearStreamPartialBackup).toHaveBeenCalledTimes(1);
  });
});

describe('refreshProviderMetadata cancelled sentinel', () => {
  it('cancelled=true: the enrich write is discarded after the await and the providers reference is unchanged', async () => {
    const store = createAppStore();
    const providers = [makeProvider()];
    store.setState({ providers });
    const before = store.getState().providers;

    await refreshProviderMetadata(store, { cancelled: true });

    expect(h.initMetadata).toHaveBeenCalledTimes(1); //   await
    expect(store.getState().providers).toBe(before); // not written back
  });

  it('cancelled=false: enrich writes back to providers when something changed', async () => {
    const store = createAppStore();
    store.setState({ providers: [makeProvider()] });
    const before = store.getState().providers;

    await refreshProviderMetadata(store, { cancelled: false });

    expect(store.getState().providers).not.toBe(before); // enrich   →  
  });
});

describe('subscribePinned cloud-push throttling', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('merges consecutive toggles into a leading push plus a single trailing push', () => {
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    const unsub = subscribePinned(store);

    store.getState().togglePinConversation('c1'); // leading: pushes immediately
    store.getState().togglePinConversation('c2'); // inside the window: coalesced
    store.getState().togglePinConversation('c3'); // still inside the window: coalesced
    expect(h.didUpdatePreferences).toHaveBeenCalledTimes(1);

    vi.advanceTimersByTime(1000); // trailing fires
    expect(h.didUpdatePreferences).toHaveBeenCalledTimes(2);
    // The trailing call carries the final state, not just the toggle that triggered it.
    expect(h.didUpdatePreferences.mock.calls[1][0].pinnedConversationIds).toEqual(['c1', 'c2', 'c3']);

    // The local setPreference is not throttled: every toggle is persisted immediately.
    expect(h.setPreference.mock.calls.filter((c) => c[0] === 'pinnedConversationIds')).toHaveLength(3);

    unsub();
  });

  it('clears the pending push timer on unsubscribe so no trailing push fires', () => {
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    const unsub = subscribePinned(store);

    store.getState().togglePinConversation('c1'); // leading
    store.getState().togglePinConversation('c2'); // pending
    expect(h.didUpdatePreferences).toHaveBeenCalledTimes(1);

    unsub();
    vi.advanceTimersByTime(2000);
    expect(h.didUpdatePreferences).toHaveBeenCalledTimes(1); // the trailing push was cancelled
  });
});

describe('subscribeConversations debounce cleanup on unsubscribe', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('unsubscribing during the debounce calls clearTimeout and never calls putConversation', () => {
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    const unsub = subscribeConversations(store);

    store.getState().addConversation(makeConversation({ id: 'c1' }));
    unsub(); // the pending debounce timer should be cleared
    vi.advanceTimersByTime(600);

    expect(h.putConversationPreservingHydratedMessages).not.toHaveBeenCalled();
  });

  it('without unsubscribing, putConversation runs normally when the debounce expires (control)', () => {
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    const unsub = subscribeConversations(store);

    store.getState().addConversation(makeConversation({ id: 'c1' }));
    vi.advanceTimersByTime(600);

    expect(h.putConversationPreservingHydratedMessages).toHaveBeenCalledTimes(1);
    expect(h.putConversationPreservingHydratedMessages.mock.calls[0][0].id).toBe('c1');
    unsub();
  });

  // Signing out mid-stream: the partition has already switched to guest during the debounce, so this
  // write is discarded rather than writing the previous account's whole conversation into the guest
  // partition.
  it('an activeUID change during the debounce discards the write, preventing cross-account leakage', () => {
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    const unsub = subscribeConversations(store);

    h.activeUID = 'user-A';
    store.getState().addConversation(makeConversation({ id: 'c1' }));
    // Simulate abortAllStreams switching the partition to guest, after scheduling but before the debounce fires.
    h.activeUID = 'guest';
    vi.advanceTimersByTime(600);

    expect(h.putConversationPreservingHydratedMessages).not.toHaveBeenCalled();
    unsub();
  });

  it('an unchanged activeUID during the debounce writes normally (control)', () => {
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    const unsub = subscribeConversations(store);

    h.activeUID = 'user-A';
    store.getState().addConversation(makeConversation({ id: 'c1' }));
    vi.advanceTimersByTime(600);

    expect(h.putConversationPreservingHydratedMessages).toHaveBeenCalledTimes(1);
    unsub();
  });

  it('a final persistence failure is caught and produces no unhandled rejection', async () => {
    h.putConversationPreservingHydratedMessages.mockRejectedValueOnce(new Error('transaction aborted'));
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    const unsub = subscribeConversations(store);

    store.getState().addConversation(makeConversation({ id: 'c1' }));
    await vi.advanceTimersByTimeAsync(600);

    expect(h.addBreadcrumb).toHaveBeenCalledWith(expect.objectContaining({
      category: 'fire-and-forget',
      message: 'storage.conversation.persist',
    }));
    unsub();
  });
});
