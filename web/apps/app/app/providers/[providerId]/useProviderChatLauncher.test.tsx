// Chat launcher hook for user-owned providers. 

import { renderHook, act } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';

const routerPush = vi.fn();
const setLastUsedModelRef = vi.fn();
const setActiveConversationId = vi.fn();
let isMobileMock = false;
let lastUsedModelRefMock: { providerID: string; modelID: string } | null = null;
let catalogDefaultModelId: string | undefined;
let catalogStatusMock: 'pending' | 'loaded' = 'pending';
let retiredModelsMock: { id: string; retiredAt?: string; routedTo?: string | null }[] = [];
let catalogIdsMock: string[] = [];

vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: routerPush }),
}));

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: {
    setLastUsedModelRef: typeof setLastUsedModelRef;
    setActiveConversationId: typeof setActiveConversationId;
    lastUsedModelRef: typeof lastUsedModelRefMock;
  }) => unknown) => selector({ setLastUsedModelRef, setActiveConversationId, lastUsedModelRef: lastUsedModelRefMock }),
}));

vi.mock('../../../lib/hooks/useMediaQuery', () => ({
  useMediaQuery: () => isMobileMock,
}));

vi.mock('../../../lib/core/metadata/metadata-client', async (importOriginal) => (await import('../../../lib/__tests__/mocks/metadata-client')).metadataClientMock(importOriginal, {
  getProviderDefaultModelId: () => catalogDefaultModelId,
  getProviderCatalogStatus: () => catalogStatusMock,
  getProviderRetiredModels: () => retiredModelsMock,
  listProviderModelIds: () => catalogIdsMock,
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
    lastUsedModelRefMock = null;
    catalogDefaultModelId = undefined;
    catalogStatusMock = 'pending';
    retiredModelsMock = [];
    catalogIdsMock = [];
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

  it('hero card follows the new-conversation chain: catalog default first, connection isDefault is not read', () => {
    catalogDefaultModelId = 'gpt-4o';
    const provider = makeProvider([makeModel('o4-mini', true), makeModel('gpt-4o')]);
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    act(() => result.current.startChatWithDefaultModel());

    expect(setLastUsedModelRef).toHaveBeenCalledWith({ providerID: 'provider-1', modelID: 'gpt-4o' });
  });

  it('hero card is scoped to this connection: last used pointing at this connection beats the catalog default', () => {
    catalogDefaultModelId = 'gpt-4o';
    lastUsedModelRefMock = { providerID: 'provider-1', modelID: 'o4-mini' };
    const provider = makeProvider([makeModel('gpt-4o'), makeModel('o4-mini')]);
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    act(() => result.current.startChatWithDefaultModel());

    expect(setLastUsedModelRef).toHaveBeenCalledWith({ providerID: 'provider-1', modelID: 'o4-mini' });
  });

  it('hero card ignores a last used model that points at another connection and uses the catalog default of this connection', () => {
    catalogDefaultModelId = 'gpt-4o';
    lastUsedModelRefMock = { providerID: 'provider-2', modelID: 'o4-mini' };
    const provider = makeProvider([makeModel('o4-mini', true), makeModel('gpt-4o')]);
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    act(() => result.current.startChatWithDefaultModel());

    expect(setLastUsedModelRef).toHaveBeenCalledWith({ providerID: 'provider-1', modelID: 'gpt-4o' });
  });

  it('falls back to the first enabled model on the hero card when nothing is marked isDefault, instead of navigating without writing a ref', () => {
    // A plain `models.find(m => m.isDefault)` pushes with nothing when every flag is false, leaving the
    // previous provider model at the top, which is exactly the regression guarded here
    const provider = makeProvider([makeModel('gpt-4o'), makeModel('o4-mini')]);
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    act(() => result.current.startChatWithDefaultModel());

    expect(setLastUsedModelRef).toHaveBeenCalledWith({ providerID: 'provider-1', modelID: 'gpt-4o' });
    expect(routerPush).toHaveBeenCalledWith('/chat');
  });

  it('selection is empty when the provider has no models: the button is unavailable and a click does not navigate', () => {
    const provider = makeProvider([]);
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    expect(result.current.startChatModelID).toBeNull();
    act(() => result.current.startChatWithDefaultModel());

    expect(setLastUsedModelRef).not.toHaveBeenCalled();
    expect(setActiveConversationId).not.toHaveBeenCalled();
    expect(routerPush).not.toHaveBeenCalled();
  });

  it('selection is empty when every enabled model is delisted: no navigation to /chat that would keep the previous model', () => {
    catalogStatusMock = 'loaded';
    retiredModelsMock = [
      { id: 'gpt-4o', retiredAt: '2026-01-01', routedTo: null },
      { id: 'o4-mini', retiredAt: '2026-01-01', routedTo: null },
    ];
    const provider = makeProvider([makeModel('gpt-4o', true), makeModel('o4-mini')]);
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    expect(result.current.startChatModelID).toBeNull();
    act(() => result.current.startChatWithDefaultModel());

    expect(setLastUsedModelRef).not.toHaveBeenCalled();
    expect(routerPush).not.toHaveBeenCalled();
  });

  it('when a model is available the selection result is the model written on click (availability and click share one source)', () => {
    catalogStatusMock = 'loaded';
    catalogIdsMock = ['o4-mini'];
    retiredModelsMock = [{ id: 'gpt-4o', retiredAt: '2026-01-01', routedTo: null }];
    const provider = makeProvider([makeModel('gpt-4o', true), makeModel('o4-mini')]);
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    expect(result.current.startChatModelID).toBe('o4-mini');
    act(() => result.current.startChatWithDefaultModel());

    expect(setLastUsedModelRef).toHaveBeenCalledWith({ providerID: 'provider-1', modelID: 'o4-mini' });
    expect(routerPush).toHaveBeenCalledWith('/chat');
  });

  it('a connection without credentials (missing key) cannot start: selection is empty, the button is hidden and a click does not record last used', () => {
    const provider = {
      ...makeProvider([makeModel('gpt-4o', true)]),
      status: { kind: 'needsKey' },
      apiKey: '',
    } as unknown as Provider;
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    expect(result.current.startChatModelID).toBeNull();
    act(() => result.current.startChatWithDefaultModel());

    expect(setLastUsedModelRef).not.toHaveBeenCalled();
    expect(routerPush).not.toHaveBeenCalled();
  });

  it('model row: a connection without credentials cannot start, so no conversation clear, no last used write and no navigation', () => {
    const provider = {
      ...makeProvider([makeModel('gpt-4o', true)]),
      status: { kind: 'needsKey' },
      apiKey: '',
    } as unknown as Provider;
    const { result } = renderHook(() => useProviderChatLauncher(provider));

    expect(result.current.canStartChatWithModel).toBe(false);
    act(() => result.current.startChatWithModel(makeModel('gpt-4o')));

    expect(setActiveConversationId).not.toHaveBeenCalled();
    expect(setLastUsedModelRef).not.toHaveBeenCalled();
    expect(routerPush).not.toHaveBeenCalled();
  });
});
