// active-selection: locks the four-level fallback priority of resolveActiveSelection.
// The snapshot factory is mocked so that a snapshot is produced when the provider exists and null
// otherwise, which keeps the focus on the resolution order and fall-through behavior
// (conversation > manually selected > lastUsed > first provider). The internal model resolution of
// createProviderSelectionSnapshot has its own tests and is not retested here.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Conversation, LastUsedModelRef, Provider } from '@oriveo/shared';

const { mockGetProviderRetiredModels, mockGetProviderCatalogStatus } = vi.hoisted(() => ({
  mockGetProviderRetiredModels: vi.fn((): unknown[] => []),
  mockGetProviderCatalogStatus: vi.fn((): 'loaded' | 'pending' | 'absent' => 'pending'),
}));

// Retirement is decided through the production path (the real resolveProviderModelRetirement + resolveModelRetirement); only the catalog reads are replaced.
vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../metadata/metadata-client')>()),
  getProviderRetiredModels: mockGetProviderRetiredModels,
  getProviderCatalogStatus: mockGetProviderCatalogStatus,
}));

vi.mock('../../providers/provider-selection-snapshot', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../providers/provider-selection-snapshot')>()),
  createProviderSelectionSnapshot: (
    provider: Provider | undefined,
    options?: { requestedModelId?: string | null; preferredModelId?: string | null },
  ) => {
    if (!provider) return null;
    return {
      provider,
      enabledModels: [],
      currentModel: { id: options?.requestedModelId ?? options?.preferredModelId ?? `${provider.id}-default`, name: 'M' },
      defaultModel: null,
      defaultModelHint: null,
    };
  },
}));

import { isProviderUsableForNewChat, resolveActiveSelection } from '../active-selection';

function makeProvider(id: string): Provider {
  return { id, kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'k', apiKeyPreview: '' } as Provider;
}

const PROVIDERS = [makeProvider('p1'), makeProvider('p2'), makeProvider('p3')];

describe('resolveActiveSelection four-level fallback', () => {
  it('a conversation that is already bound wins: uses the conversation providerID/modelID', () => {
    const conversation = { providerID: 'p2', modelID: 'conv-model' } as Conversation;
    const result = resolveActiveSelection(PROVIDERS, conversation, 'p3', 'sel-model', { providerID: 'p1', modelID: 'last-model' }, true);
    expect(result.provider?.id).toBe('p2');
    expect(result.currentModel?.id).toBe('conv-model');
  });

  it('with no conversation, takes the manually selected value (selectedProviderId + selectedModelId)', () => {
    const result = resolveActiveSelection(PROVIDERS, undefined, 'p3', 'sel-model', { providerID: 'p1', modelID: 'last-model' }, true);
    expect(result.provider?.id).toBe('p3');
    expect(result.currentModel?.id).toBe('sel-model');
  });

  it('with no conversation and nothing selected, takes lastUsedModelRef', () => {
    const result = resolveActiveSelection(PROVIDERS, undefined, null, null, { providerID: 'p1', modelID: 'last-model' }, true);
    expect(result.provider?.id).toBe('p1');
    expect(result.currentModel?.id).toBe('last-model');
  });

  it('falls back to the first provider when everything is absent', () => {
    const result = resolveActiveSelection(PROVIDERS, undefined, null, null, null, true);
    expect(result.provider?.id).toBe('p1');
    expect(result.currentModel?.id).toBe('p1-default');
  });

  it('reports a removed connection when the conversation provider is not in runtimeProviders, and does not fall through to selected / lastUsed / the first provider', () => {
    const conversation = { providerID: 'missing', modelID: 'conv-model' } as Conversation;
    const result = resolveActiveSelection(PROVIDERS, conversation, 'p2', 'sel-model', { providerID: 'p3', modelID: 'last-model' }, true);
    expect(result.provider).toBeUndefined();
    expect(result.currentModel).toBeUndefined();
    expect(result.connectionRemoved).toEqual({ providerId: 'missing', modelId: 'conv-model' });
  });

  it('does not report connectionRemoved before the connection list has loaded (providersHydrated is false)', () => {
    const conversation = { providerID: 'missing', providerKind: 'openAI', modelID: 'conv-model' } as unknown as Conversation;
    const result = resolveActiveSelection(PROVIDERS, conversation, null, null, null, false);
    expect(result.connectionRemoved).toBeUndefined();
    expect(result.provider).toBeUndefined();
    expect(result.currentModel).toBeUndefined();
  });

  it('a conversation not yet bound to a connection (empty providerID) falls through to selected under the new-conversation rules', () => {
    const conversation = { providerID: '', modelID: '' } as Conversation;
    const result = resolveActiveSelection(PROVIDERS, conversation, 'p2', 'sel-model', null, true);
    expect(result.provider?.id).toBe('p2');
    expect(result.connectionRemoved).toBeUndefined();
  });

  it('falls through to lastUsed when the selected provider does not exist', () => {
    const result = resolveActiveSelection(PROVIDERS, undefined, 'missing', 'sel-model', { providerID: 'p3', modelID: 'last-model' }, true);
    expect(result.provider?.id).toBe('p3');
    expect(result.currentModel?.id).toBe('last-model');
  });

  it('a new conversation across all connections skips connections that lack a key and takes the next one in list order', () => {
    const noKey = { ...makeProvider('p1'), apiKey: '' } as Provider;
    const result = resolveActiveSelection([noKey, makeProvider('p2')], undefined, null, null, null, true);
    expect(result.provider?.id).toBe('p2');
    expect(result.currentModel?.id).toBe('p2-default');
  });

  it('a new conversation across all connections does not skip a connection in an error status (unusable only means missing credentials)', () => {
    const issue = { ...makeProvider('p1'), status: { kind: 'issue', message: 'x' } } as Provider;
    const result = resolveActiveSelection([issue, makeProvider('p2')], undefined, null, null, null, true);
    expect(result.provider?.id).toBe('p1');
  });

  it('a relay with authMode none and an empty key does not count as missing credentials and is usable for a new conversation', () => {
    const relayNoAuth = {
      ...makeProvider('relay-none'), kind: 'relay', apiKey: '',
      relayRequested: { transport: 'openai_chat', authMode: 'none' },
    } as unknown as Provider;
    const relayBearer = {
      ...makeProvider('relay-bearer'), kind: 'relay', apiKey: '',
      relayRequested: { transport: 'openai_chat', authMode: 'bearer' },
    } as unknown as Provider;
    expect(isProviderUsableForNewChat(relayNoAuth)).toBe(true);
    expect(isProviderUsableForNewChat(relayBearer)).toBe(false);
  });

  it('returns undefined provider/currentModel when runtimeProviders is empty', () => {
    const result = resolveActiveSelection([], undefined, null, null, null, true);
    expect(result.provider).toBeUndefined();
    expect(result.currentModel).toBeUndefined();
  });

  it('still resolves the selected provider when selectedModelId is null (preferredModelId is passed through as null)', () => {
    const result = resolveActiveSelection(PROVIDERS, undefined, 'p2', null, null, true);
    expect(result.provider?.id).toBe('p2');
    expect(result.currentModel?.id).toBe('p2-default');
  });
});

describe('resolveActiveSelection conversation model retirement (model-retired.v1)', () => {
  beforeEach(() => {
    mockGetProviderRetiredModels.mockReset();
    mockGetProviderRetiredModels.mockReturnValue([]);
    mockGetProviderCatalogStatus.mockReset();
    mockGetProviderCatalogStatus.mockReturnValue('pending');
  });

  it('a conversation model that hits a tombstone: currentModel is empty with the verdict attached, and it does not fall to selected / lastUsed / the first provider', () => {
    mockGetProviderCatalogStatus.mockReturnValue('loaded');
    mockGetProviderRetiredModels.mockReturnValue([
      { id: 'conv-model', displayName: 'Conv Model', retiredAt: '2026-07-24T00:00:00Z', routedTo: null },
    ]);
    const conversation = { providerID: 'p2', modelID: 'conv-model' } as Conversation;

    const result = resolveActiveSelection(PROVIDERS, conversation, 'p3', 'sel-model', { providerID: 'p1', modelID: 'last-model' }, true);

    expect(result.provider?.id).toBe('p2');
    expect(result.currentModel).toBeUndefined();
    expect(result.modelRetirement).toEqual({
      status: 'retired', successorId: null, displayName: 'Conv Model', sendBlocked: true, modelId: 'conv-model',
    });
    expect(conversation.modelID).toBe('conv-model');
  });

  it('catalog not loaded (no tombstones, no model table): the verdict is available and the conversation model is used as usual', () => {
    const conversation = { providerID: 'p2', modelID: 'conv-model' } as Conversation;

    const result = resolveActiveSelection(PROVIDERS, conversation, null, null, null, true);

    expect(result.currentModel?.id).toBe('conv-model');
    expect(result.modelRetirement).toBeUndefined();
  });
});
