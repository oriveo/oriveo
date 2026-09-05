// Chat launcher hook for user-owned providers. 

import { renderHook, act } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';

const routerPush = vi.fn();
const setLastUsedModelRef = vi.fn();
const setActiveConversationId = vi.fn();
let isMobileMock = false;

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: routerPush }),
}));

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: {
    setLastUsedModelRef: typeof setLastUsedModelRef;
    setActiveConversationId: typeof setActiveConversationId;
  }) => unknown) => selector({ setLastUsedModelRef, setActiveConversationId }),
}));

vi.mock('../../../lib/hooks/useMediaQuery', () => ({
  useMediaQuery: () => isMobileMock,
}));

vi.mock('../../../lib/core/metadata/metadata-client', () => ({
  getProviderDefaultModelId: () => undefined,
  getRelayRuntimeConfig: () => undefined,
  resolveCatalogModel: () => null,
  resolveCatalogModelAcrossProvidersWithProvider: () => null,
  DEFAULT_RELAY_RUNTIME_CONFIG: { transports: {} },
}));

import { useProviderChatLauncher } from './useProviderChatLauncher';

function makeModel(id: string, isDefault = false): AIModel {
  return {
    id,
    name: id,
    capabilities: [],
    isAvailable: true,
    isDefault,
    priceTier: '',
  } as unknown as AIModel;
}

function makeProvider(models: AIModel[]): Provider {
  return {
    id: 'provider-1',
    kind: 'openAI',
    status: { kind: 'connected' },
    models,
    catalogModels: [],
    apiKey: 'k',
    apiKeyPreview: '',
  } as unknown as Provider;
}

describe('useProviderChatLauncher', () => {
  beforeEach(() => {
    routerPush.mockReset();
    setLastUsedModelRef.mockReset();
    setActiveConversationId.mockReset();
    isMobileMock = false;
  });

  it('clears the active conversation, records the model and opens a new conversation when an added model is tapped', () => {
    const provider = makeProvider([makeModel('gpt-4o', true), makeModel('o4-mini')]);
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    act(() => result.current.startChatWithModel(makeModel('o4-mini')));

    // Without clearing activeConversationId, the first ChatView frame takes the already-bound branch and shows the previous conversation model
    expect(setActiveConversationId).toHaveBeenCalledWith(null);
    expect(setLastUsedModelRef).toHaveBeenCalledWith({ providerID: 'provider-1', modelID: 'o4-mini' });
    expect(routerPush).toHaveBeenCalledWith('/chat');
  });

  it('adds compose=1 on mobile, since /chat otherwise renders the home view and never reaches a new conversation', () => {
    isMobileMock = true;
    const provider = makeProvider([makeModel('gpt-4o', true)]);
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    act(() => result.current.startChatWithModel(makeModel('gpt-4o')));

    expect(routerPush).toHaveBeenCalledWith('/chat?compose=1');
  });

  it('resolves the default model authoritatively for the hero card', () => {
    const provider = makeProvider([makeModel('gpt-4o'), makeModel('o4-mini', true)]);
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    act(() => result.current.startChatWithDefaultModel());

    expect(setLastUsedModelRef).toHaveBeenCalledWith({ providerID: 'provider-1', modelID: 'o4-mini' });
  });

  it('falls back to the first enabled model on the hero card when nothing is marked isDefault', () => {
    // A plain `models.find(m => m.isDefault)` pushes with nothing when every flag is false, leaving the
    // previous provider model at the top, which is exactly the regression guarded here
    const provider = makeProvider([makeModel('gpt-4o'), makeModel('o4-mini')]);
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    act(() => result.current.startChatWithDefaultModel());

    expect(setLastUsedModelRef).toHaveBeenCalledWith({ providerID: 'provider-1', modelID: 'gpt-4o' });
    expect(routerPush).toHaveBeenCalledWith('/chat');
  });

  it('writes no empty ref when the provider has no models, but still opens a new conversation so the user can pick one', () => {
    const provider = makeProvider([]);
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    act(() => result.current.startChatWithDefaultModel());

    expect(setLastUsedModelRef).not.toHaveBeenCalled();
    expect(setActiveConversationId).toHaveBeenCalledWith(null);
    expect(routerPush).toHaveBeenCalledWith('/chat');
  });
});
