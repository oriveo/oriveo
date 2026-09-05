// active-selection: locks the four-level fallback priority of resolveActiveSelection.
// The snapshot factory is mocked so that a snapshot is produced when the provider exists and null
// otherwise, which keeps the focus on the resolution order and fall-through behavior
// (conversation > manually selected > lastUsed > first provider). The internal model resolution of
// createProviderSelectionSnapshot has its own tests and is not retested here.

import { describe, expect, it, vi } from 'vitest';
import type { Conversation, LastUsedModelRef, Provider } from '@oriveo/shared';

vi.mock('../../providers/provider-selection-snapshot', () => ({
  createProviderSelectionSnapshot: (provider: Provider | undefined, options?: { requestedModelId?: string | null }) => {
    if (!provider) return null;
    return {
      provider,
      enabledModels: [],
      currentModel: { id: options?.requestedModelId ?? `${provider.id}-default`, name: 'M' },
      defaultModel: null,
    };
  },
}));

import { resolveActiveSelection } from '../active-selection';

function makeProvider(id: string): Provider {
  return { id, kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'k', apiKeyPreview: '' } as Provider;
}

const PROVIDERS = [makeProvider('p1'), makeProvider('p2'), makeProvider('p3')];

describe('resolveActiveSelection four-level fallback', () => {
  it('a bound conversation wins: its providerID/modelID are used', () => {
    const conversation = { providerID: 'p2', modelID: 'conv-model' } as Conversation;
    const result = resolveActiveSelection(PROVIDERS, conversation, 'p3', 'sel-model', { providerID: 'p1', modelID: 'last-model' });
    expect(result.provider?.id).toBe('p2');
    expect(result.currentModel?.id).toBe('conv-model');
  });

  it('with no conversation, the manual selection is used (selectedProviderId + selectedModelId)', () => {
    const result = resolveActiveSelection(PROVIDERS, undefined, 'p3', 'sel-model', { providerID: 'p1', modelID: 'last-model' });
    expect(result.provider?.id).toBe('p3');
    expect(result.currentModel?.id).toBe('sel-model');
  });

  it('with no conversation and no manual selection, lastUsedModelRef is used', () => {
    const result = resolveActiveSelection(PROVIDERS, undefined, null, null, { providerID: 'p1', modelID: 'last-model' });
    expect(result.provider?.id).toBe('p1');
    expect(result.currentModel?.id).toBe('last-model');
  });

  it('with everything missing, it falls back to the first provider', () => {
    const result = resolveActiveSelection(PROVIDERS, undefined, null, null, null);
    expect(result.provider?.id).toBe('p1');
    expect(result.currentModel?.id).toBe('p1-default');
  });

  it('a conversation provider missing from runtimeProviders falls through to the manual selection', () => {
    const conversation = { providerID: 'missing', modelID: 'conv-model' } as Conversation;
    const result = resolveActiveSelection(PROVIDERS, conversation, 'p2', 'sel-model', null);
    expect(result.provider?.id).toBe('p2');
    expect(result.currentModel?.id).toBe('sel-model');
  });

  it('a missing selected provider falls through to lastUsed', () => {
    const result = resolveActiveSelection(PROVIDERS, undefined, 'missing', 'sel-model', { providerID: 'p3', modelID: 'last-model' });
    expect(result.provider?.id).toBe('p3');
    expect(result.currentModel?.id).toBe('last-model');
  });

  it('an empty runtimeProviders returns undefined provider/currentModel', () => {
    const result = resolveActiveSelection([], undefined, null, null, null);
    expect(result.provider).toBeUndefined();
    expect(result.currentModel).toBeUndefined();
  });

  it('a null selectedModelId still resolves the selected provider, passing requestedModelId through as null', () => {
    const result = resolveActiveSelection(PROVIDERS, undefined, 'p2', null, null);
    expect(result.provider?.id).toBe('p2');
    expect(result.currentModel?.id).toBe('p2-default');
  });
});
