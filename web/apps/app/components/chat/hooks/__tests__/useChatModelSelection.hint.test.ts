// @vitest-environment jsdom

import { act, renderHook } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, LastUsedModelRef, Provider } from '@oriveo/shared';
import type { ActiveSelection } from '../../../../lib/core/chat/active-selection';

// De-dup key of the new-chat hint: the selection result is supplied by each case, de-dup goes through the production consumeModelRetiredHint (real localStorage).
const mocks = vi.hoisted(() => ({
  state: {
    lastUsedModelRef: null as LastUsedModelRef | null,
    setLastUsedModelRef: () => undefined,
    account: null,
  },
  selection: null as unknown as ActiveSelection,
  resolveCalls: [] as Array<{ selectedProviderId: string | null; selectedModelId: string | null }>,
  showToast: vi.fn(),
}));

vi.mock('../../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: typeof mocks.state) => unknown) => selector(mocks.state),
  getVanillaStore: () => ({ getState: () => mocks.state }),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

vi.mock('../../../Toast', () => ({
  showToast: (...args: unknown[]) => mocks.showToast(...args),
}));

vi.mock('../../../../lib/core/telemetry', () => ({
  trackEvent: () => undefined,
  telemetryProviderKind: (kind: string) => kind,
  telemetryModelID: (_kind: string, id: string) => id,
}));

vi.mock('../../../../lib/core/chat/active-selection', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../../lib/core/chat/active-selection')>()),
  selectConnectionRemovalJudgeable: () => true,
  resolveActiveSelection: (
    _providers: Provider[],
    _conversation: unknown,
    selectedProviderId: string | null,
    selectedModelId: string | null,
  ) => {
    mocks.resolveCalls.push({ selectedProviderId, selectedModelId });
    return mocks.selection;
  },
}));

import { useChatModelSelection } from '../useChatModelSelection';

const HINT_STORAGE_KEY = 'oriveo.model-retired-hint-seen.v1';

function makeModel(id: string): AIModel {
  return {
    id, name: id, capabilities: ['text'], reasoningModeAvailable: false,
    isAvailable: true, isDefault: false, priceTier: 'standard',
  };
}

function makeProvider(id: string, models: AIModel[]): Provider {
  return {
    id, kind: 'openAI', status: { kind: 'connected' }, models, catalogModels: [],
    apiKey: 'sk-test', apiKeyPreview: 'sk-...test',
  };
}

function seenKeys(): string[] {
  return JSON.parse(window.localStorage.getItem(HINT_STORAGE_KEY) ?? '[]') as string[];
}

function renderSelection(providers: Provider[]) {
  return renderHook(() => useChatModelSelection({
    runtimeProviders: providers,
    conversation: undefined,
    providers,
    evaluateExpensiveHint: () => undefined,
    metadataVersion: 0,
  }));
}

describe('useChatModelSelection new-chat retired hint de-dup key', () => {
  beforeEach(() => {
    window.localStorage.clear();
    mocks.showToast.mockReset();
    mocks.resolveCalls = [];
    mocks.state.lastUsedModelRef = null;
  });

  it('last-used tier keys on the last-used connection + raw model id, not the fallback connection', () => {
    const fallback = makeProvider('openai', [makeModel('gpt-mini')]);
    mocks.state.lastUsedModelRef = { providerID: 'deepseek', modelID: 'deepseek-chat' };
    mocks.selection = {
      provider: fallback,
      currentModel: fallback.models[0],
      defaultModelHint: 'last_used_retired',
      unusedPreferredModelId: 'deepseek-chat',
    };

    renderSelection([fallback]);

    expect(mocks.showToast).toHaveBeenCalledTimes(1);
    expect(seenKeys()).toEqual(['deepseek|deepseek-chat']);
  });

  it('same key is hinted only once per device', () => {
    const fallback = makeProvider('openai', [makeModel('gpt-mini')]);
    mocks.state.lastUsedModelRef = { providerID: 'deepseek', modelID: 'deepseek-chat' };
    mocks.selection = {
      provider: fallback,
      currentModel: fallback.models[0],
      defaultModelHint: 'last_used_retired',
      unusedPreferredModelId: 'deepseek-chat',
    };

    renderSelection([fallback]).unmount();
    renderSelection([fallback]);

    expect(mocks.showToast).toHaveBeenCalledTimes(1);
    expect(seenKeys()).toEqual(['deepseek|deepseek-chat']);
  });

  it('manual-pick tier keys on its own connection + model, not the last-used ref', () => {
    const picked = makeProvider('anthropic', [makeModel('claude-old'), makeModel('claude-new')]);
    // Last-used points at another connection; once the manual pick takes effect the key must not borrow it.
    mocks.state.lastUsedModelRef = { providerID: 'deepseek', modelID: 'deepseek-chat' };
    mocks.selection = { provider: picked, currentModel: picked.models[1], defaultModelHint: null, unusedPreferredModelId: null };

    const { result, rerender } = renderSelection([picked]);
    expect(mocks.showToast).not.toHaveBeenCalled();

    // After a manual pick, resolution goes through the selected tier: it reports the picked model as retired
    mocks.selection = {
      provider: picked,
      currentModel: picked.models[1],
      defaultModelHint: 'last_used_retired',
      unusedPreferredModelId: 'claude-old',
    };
    act(() => result.current.handleModelSelect(picked.models[0], picked));
    rerender();

    expect(mocks.resolveCalls.at(-1)).toEqual({ selectedProviderId: 'anthropic', selectedModelId: 'claude-old' });
    expect(mocks.showToast).toHaveBeenCalledTimes(1);
    expect(seenKeys()).toEqual(['anthropic|claude-old']);
  });
});
