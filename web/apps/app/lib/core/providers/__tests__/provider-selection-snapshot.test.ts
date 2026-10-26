import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import type { RetirementCatalog } from '../../chat/conversation-model-status';
import {
  createProviderSelectionSnapshot,
  isModelSelectableForNewChat,
  resolveProviderModelRetirement,
  resolveRetirementSuccessorModel,
} from '../provider-selection-snapshot';
import { resolveNewChatSelection } from '../../chat/active-selection';

const {
  mockGetProviderDefaultModelId,
  mockResolveCatalogModel,
  mockGetProviderRetiredModels,
  mockListProviderModelIds,
  mockGetProviderCatalogStatus,
} = vi.hoisted(() => ({
  mockGetProviderDefaultModelId: vi.fn(),
  mockResolveCatalogModel: vi.fn(),
  mockGetProviderRetiredModels: vi.fn((): unknown[] => []),
  mockListProviderModelIds: vi.fn((): string[] => []),
  mockGetProviderCatalogStatus: vi.fn((): 'loaded' | 'pending' | 'absent' => 'pending'),
}));

const { mockEnrichRelayCatalog } = vi.hoisted(() => ({
  mockEnrichRelayCatalog: vi.fn((models: AIModel[]) => models),
}));

vi.mock('../../metadata/metadata-client', async (importOriginal) => (await import('../../../__tests__/mocks/metadata-client')).metadataClientMock(importOriginal, {
  getProviderCatalogStatus: mockGetProviderCatalogStatus,
  getProviderDefaultModelId: mockGetProviderDefaultModelId,
  getProviderRetiredModels: mockGetProviderRetiredModels,
  getRelayRuntimeConfig: () => ({ version: 'test' }),
  listProviderModelIds: mockListProviderModelIds,
  resolveCatalogModel: mockResolveCatalogModel,
}));

vi.mock('../relay-official-catalog-match', () => ({
  enrichRelayCatalog: mockEnrichRelayCatalog,
}));

function makeModel(id: string, overrides: Partial<AIModel> = {}): AIModel {
  return {
    id,
    name: overrides.name ?? id,
    canonicalModelId: overrides.canonicalModelId,
    capabilities: overrides.capabilities ?? ['text'],
    reasoningModeAvailable: overrides.reasoningModeAvailable ?? false,
    isAvailable: overrides.isAvailable ?? true,
    isDefault: overrides.isDefault ?? false,
    priceTier: overrides.priceTier ?? '$',
  };
}

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: overrides.id ?? 'provider-1',
    kind: overrides.kind ?? 'openAI',
    status: overrides.status ?? { kind: 'connected' },
    models: overrides.models ?? [],
    catalogModels: overrides.catalogModels ?? [],
    apiKey: overrides.apiKey ?? 'sk-test',
    apiKeyPreview: overrides.apiKeyPreview ?? 'sk-...test',
    relayRequested: overrides.relayRequested,
    relayResolvedTransport: overrides.relayResolvedTransport,
  };
}

describe('provider-selection-snapshot', () => {
  beforeEach(() => {
    mockEnrichRelayCatalog.mockClear();
    mockGetProviderRetiredModels.mockReset();
    mockGetProviderRetiredModels.mockReturnValue([]);
    mockListProviderModelIds.mockReset();
    mockListProviderModelIds.mockReturnValue([]);
    mockGetProviderCatalogStatus.mockReset();
    mockGetProviderCatalogStatus.mockReturnValue('pending');
  });

  it('selects current by requested model id (canonical and dated snapshot are aligned)', () => {
    mockGetProviderDefaultModelId.mockReset();
    const provider = makeProvider({
      models: [
        makeModel('gpt-5.4-nano-2026-03-01', {
          name: 'GPT-5.4 Nano',
          canonicalModelId: 'gpt-5.4-nano',
        }),
        makeModel('o4-mini', { name: 'o4-mini', isDefault: true }),
      ],
    });

    const snapshot = createProviderSelectionSnapshot(provider, {
      requestedModelId: 'gpt-5.4-nano',
    });

    expect(snapshot?.currentModel?.id).toBe('gpt-5.4-nano-2026-03-01');
    // A new chat does not read the connection isDefault; when the catalog has no default, take the first usable enabled model.
    expect(snapshot?.defaultModel?.id).toBe('gpt-5.4-nano-2026-03-01');
    expect(snapshot?.enabledModels.map((model) => model.id)).toEqual([
      'gpt-5.4-nano-2026-03-01',
      'o4-mini',
    ]);
  });

  it('with no user default, uses the metadata defaultModelId (only when it matches an enabled model)', () => {
    mockGetProviderDefaultModelId.mockReset();
    mockGetProviderDefaultModelId.mockReturnValue('o4-mini');
    const provider = makeProvider({
      kind: 'openAI',
      models: [
        makeModel('gpt-4o', { canonicalModelId: 'gpt-4o' }),
        makeModel('o4-mini-2026-04-10', { canonicalModelId: 'o4-mini' }),
      ],
    });

    const snapshot = createProviderSelectionSnapshot(provider);

    expect(snapshot?.defaultModel?.id).toBe('o4-mini-2026-04-10');
    expect(snapshot?.currentModel?.id).toBe('o4-mini-2026-04-10');
  });

  it('does not fall back to catalogModels when there are no enabled models', () => {
    mockGetProviderDefaultModelId.mockReset();
    mockGetProviderDefaultModelId.mockReturnValue('catalog-only');
    const provider = makeProvider({
      kind: 'openRouter',
      models: [],
      catalogModels: [makeModel('catalog-only')],
    });

    const snapshot = createProviderSelectionSnapshot(provider);

    expect(snapshot?.enabledModels).toEqual([]);
    expect(snapshot?.defaultModel).toBeNull();
    expect(snapshot?.currentModel).toBeNull();
  });

  it('a relay provider does not go through the metadata default lookup', () => {
    mockGetProviderDefaultModelId.mockReset();
    mockResolveCatalogModel.mockReset();
    const provider = makeProvider({
      kind: 'relay',
      models: [makeModel('relay/custom')],
    });

    const snapshot = createProviderSelectionSnapshot(provider);

    expect(snapshot?.defaultModel?.id).toBe('relay/custom');
    expect(snapshot?.currentModel?.id).toBe('relay/custom');
    expect(mockGetProviderDefaultModelId).not.toHaveBeenCalled();
  });

  it('a relay provider runs official catalog enrichment before entering chat selection', () => {
    const provider = makeProvider({
      kind: 'relay',
      relayResolvedTransport: 'openai_chat_completions',
      models: [
        makeModel('gpt-5.4', { capabilities: ['text', 'web', 'imageGeneration'] }),
      ],
    });
    mockEnrichRelayCatalog.mockReturnValueOnce([
      makeModel('gpt-5.4', { capabilities: ['text'] }),
    ]);

    const snapshot = createProviderSelectionSnapshot(provider);

    expect(mockEnrichRelayCatalog).toHaveBeenCalledWith(
      provider.models,
      'openai_chat_completions',
      { version: 'test' },
    );
    expect(snapshot?.currentModel?.capabilities).toEqual(['text']);
    expect(snapshot?.enabledModels[0].capabilities).toEqual(['text']);
  });


  it('when a past conversation references a disabled model, currentModel keeps the metadata resolution instead of falling back to the default', () => {
    mockGetProviderDefaultModelId.mockReset();
    mockResolveCatalogModel.mockReset();
    mockGetProviderDefaultModelId.mockReturnValue('gpt-4o');
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'o4-mini',
      displayName: 'o4-mini',
      contextLength: undefined,
      capabilities: ['text', 'reasoning'],
      pricing: {
        promptPerToken: 0.000002,
        completionPerToken: 0.000008,
        cachedInputPerMToken: null,
      },
      profiles: {
        reasoning: 'openai.responses.reasoning.deep',
      },
      uiHints: undefined,
      isDefault: false,
    });
    const provider = makeProvider({
      kind: 'openAI',
      models: [
        makeModel('gpt-4o', {
          name: 'GPT-4o',
          canonicalModelId: 'gpt-4o',
          isDefault: true,
        }),
      ],
    });

    const snapshot = createProviderSelectionSnapshot(provider, {
      requestedModelId: 'o4-mini-2026-04-10',
    });

    expect(snapshot?.currentModel).toMatchObject({
      id: 'o4-mini',
      canonicalModelId: 'o4-mini',
      name: 'o4-mini',
    });
    expect(snapshot?.defaultModel?.id).toBe('gpt-4o');
  });

  describe('official provider retirement verdict (model-retired.v1)', () => {
    // Catalog of the tombstone_with_successor fixture: deepseek-chat is in the tombstones, succeeded by deepseek-flash.
    const tombstone = {
      id: 'deepseek-chat', displayName: 'DeepSeek Chat', retiredAt: '2026-07-24T00:00:00Z', routedTo: 'deepseek-flash',
    };
    const deepSeek = () => makeProvider({
      id: 'deepseek-1',
      kind: 'deepSeek',
      models: [makeModel('deepseek-chat'), makeModel('deepseek-v4-pro'), makeModel('deepseek-flash')],
    });

    beforeEach(() => {
      mockGetProviderDefaultModelId.mockReset();
      mockGetProviderDefaultModelId.mockReturnValue('deepseek-flash');
      mockResolveCatalogModel.mockReset();
      mockResolveCatalogModel.mockReturnValue(null);
      mockGetProviderRetiredModels.mockReturnValue([tombstone]);
      mockListProviderModelIds.mockReturnValue(['deepseek-flash', 'deepseek-v4-pro']);
      mockGetProviderCatalogStatus.mockReturnValue('loaded');
    });

    it('historical conversation model hits a tombstone: no current model, verdict retired with a successor, no default model filled in', () => {
      const snapshot = createProviderSelectionSnapshot(deepSeek(), { requestedModelId: 'deepseek-chat' });

      expect(snapshot?.currentModel).toBeNull();
      expect(snapshot?.modelRetirement).toEqual({
        status: 'retired',
        successorId: 'deepseek-flash',
        displayName: 'DeepSeek Chat',
        sendBlocked: true,
        modelId: 'deepseek-chat',
      });
      // The verdict catalog only builds entries for the conversation model and its successor, without looking up every enabled model.
      mockResolveCatalogModel.mockClear();
      resolveProviderModelRetirement(deepSeek(), 'deepseek-chat');
      expect(new Set(mockResolveCatalogModel.mock.calls.map(([id]) => id))).toEqual(new Set(['deepseek-chat', 'deepseek-flash']));
      expect(snapshot?.defaultModelHint).toBeNull();
    });

    it('historical conversation model is neither in the catalog nor enabled: no current model, verdict missing', () => {
      const snapshot = createProviderSelectionSnapshot(deepSeek(), { requestedModelId: 'deepseek-gone' });

      expect(snapshot?.currentModel).toBeNull();
      expect(snapshot?.modelRetirement?.status).toBe('missing');
    });

    it('historical conversation model is usable: selected as usual, with no verdict', () => {
      const snapshot = createProviderSelectionSnapshot(deepSeek(), { requestedModelId: 'deepseek-v4-pro' });

      expect(snapshot?.currentModel?.id).toBe('deepseek-v4-pro');
      expect(snapshot?.modelRetirement).toBeUndefined();
      expect(snapshot?.unusedPreferredModelId).toBeNull();
    });

    it('new-chat preference (last used) is retired: falls back to the fixture default model with last_used_retired', () => {
      const snapshot = createProviderSelectionSnapshot(deepSeek(), { preferredModelId: 'deepseek-chat' });

      expect(snapshot?.currentModel?.id).toBe('deepseek-flash');
      expect(snapshot?.defaultModelHint).toBe('last_used_retired');
      expect(snapshot?.unusedPreferredModelId).toBe('deepseek-chat');
      expect(snapshot?.modelRetirement).toBeUndefined();
    });

    it('new-chat preference is usable: used as-is, with no hint', () => {
      const snapshot = createProviderSelectionSnapshot(deepSeek(), { preferredModelId: 'deepseek-v4-pro' });

      expect(snapshot?.currentModel?.id).toBe('deepseek-v4-pro');
      expect(snapshot?.defaultModelHint).toBeNull();
      expect(snapshot?.unusedPreferredModelId).toBeNull();
    });

    // A new chat does not read the connection isDefault; here isDefault sits on the retired deepseek-chat, the result is still the catalog default, and with no last-used model there is no hint.
    it('a new chat does not read the connection default: with no last-used model it uses the catalog default and gives no hint (cross-end-closure newChatDefaultCases)', () => {
      const provider = deepSeek();
      provider.models = [makeModel('deepseek-chat', { isDefault: true }), makeModel('deepseek-v4-pro'), makeModel('deepseek-flash')];

      const snapshot = createProviderSelectionSnapshot(provider);

      expect(snapshot?.defaultModel?.id).toBe('deepseek-flash');
      expect(snapshot?.defaultModelHint).toBeNull();
      expect(snapshot?.unusedPreferredModelId).toBeNull();
    });

    it('catalog pending: a historical conversation model that is not enabled is still judged available, no default model is filled in, and the current model is a bare model of the stored id', () => {
      mockGetProviderCatalogStatus.mockReturnValue('pending');

      const snapshot = createProviderSelectionSnapshot(deepSeek(), { requestedModelId: 'deepseek-old' });

      expect(snapshot?.modelRetirement).toBeUndefined();
      expect(snapshot?.currentModel).toMatchObject({ id: 'deepseek-old', name: 'deepseek-old' });
      expect(snapshot?.defaultModel?.id).toBe('deepseek-flash');
      expect(snapshot?.defaultModelHint).toBeNull();
    });

    it('catalog status not loaded (pending / absent): even a tombstone hit is judged available', () => {
      for (const status of ['pending', 'absent'] as const) {
        mockGetProviderCatalogStatus.mockReturnValue(status);
        expect(resolveProviderModelRetirement(deepSeek(), 'deepseek-chat')).toMatchObject({
          status: 'available', sendBlocked: false, modelId: 'deepseek-chat',
        });
      }
      mockGetProviderCatalogStatus.mockReturnValue('loaded');
      expect(resolveProviderModelRetirement(deepSeek(), 'deepseek-chat')?.status).toBe('retired');
    });
  });

  // Adapter layer: the catalog of the fixture conversationCases is fed in through the metadata mock, and the verdict must match the fixture.
  describe('the successor must be enabled', () => {
    it('successor is in the catalog but not enabled: returns null, no model added through catalog resolution', () => {
      mockResolveCatalogModel.mockReturnValue({
        canonicalModelId: 'deepseek-flash',
        displayName: 'DeepSeek Flash',
        contextLength: 64000,
      });
      const provider = makeProvider({
        id: 'deepseek-1',
        kind: 'deepSeek',
        models: [makeModel('deepseek-chat'), makeModel('deepseek-v4-pro')],
      });

      expect(resolveRetirementSuccessorModel(provider, 'deepseek-flash')).toBeNull();
    });

    it('successor matches an enabled model by canonicalModelId: returns that model', () => {
      const enabled = makeModel('deepseek-flash-2026-07-01', { canonicalModelId: 'deepseek-flash', name: 'DeepSeek Flash' });
      const provider = makeProvider({
        id: 'deepseek-1',
        kind: 'deepSeek',
        models: [makeModel('deepseek-chat'), enabled],
      });

      expect(resolveRetirementSuccessorModel(provider, 'deepseek-flash')).toBe(enabled);
    });
  });

  describe('resolveProviderModelRetirement adapts model-retired.v1', () => {
    interface ConversationCase {
      id: string;
      catalog: RetirementCatalog | null;
      userModels: string[];
      conversation: { modelId: string; storedName: string | null };
      expect: { status: string; successorId: string | null; displayName: string; sendBlocked: boolean; modelIdAfter: string };
    }
    const fixture = (() => {
      let dir = process.cwd();
      for (let depth = 0; depth < 8; depth += 1) {
        const candidate = path.join(dir, 'shared', 'test-fixtures', 'provider-catalog', 'model-retired.v1.json');
        if (existsSync(candidate)) {
          return JSON.parse(readFileSync(candidate, 'utf8')) as {
            now: string;
            conversationCases: ConversationCase[];
            newChatCases: Array<{
              id: string;
              catalog: RetirementCatalog | null;
              userModels: string[];
              userModelCanonicalIds?: Record<string, string>;
              preferredModelId: string | null;
              expect: { modelId: string | null; hint: string | null };
            }>;
          };
        }
        dir = path.dirname(dir);
      }
      throw new Error('model-retired.v1.json not found');
    })();

    function feedCatalog(catalog: RetirementCatalog | null) {
      mockGetProviderCatalogStatus.mockReturnValue(catalog ? 'loaded' : 'pending');
      mockListProviderModelIds.mockReturnValue(catalog?.models.map((entry) => entry.id) ?? []);
      mockGetProviderRetiredModels.mockReturnValue(catalog?.retiredModels ?? []);
      mockGetProviderDefaultModelId.mockReturnValue(catalog?.defaultModelId);
      mockResolveCatalogModel.mockReset();
      mockResolveCatalogModel.mockImplementation((id: string) => {
        if (!catalog) return null;
        const canonical = catalog.resolveMap?.[id] ?? id;
        const entry = catalog.models.find((model) => model.id === canonical);
        if (!entry) return null;
        return { canonicalModelId: canonical, displayName: entry.displayName, lifecycle: entry.lifecycle };
      });
    }

    beforeEach(() => {
      vi.useFakeTimers();
      vi.setSystemTime(new Date(fixture.now));
    });

    for (const testCase of fixture.conversationCases) {
      it(`RETIRED-${testCase.id}`, () => {
        try {
          feedCatalog(testCase.catalog);
          const provider = makeProvider({ kind: 'deepSeek', models: testCase.userModels.map((id) => makeModel(id)) });

          const result = resolveProviderModelRetirement(provider, testCase.conversation.modelId);

          expect({
            status: result?.status,
            successorId: result?.successorId,
            sendBlocked: result?.sendBlocked,
            modelId: result?.modelId,
          }).toEqual({
            status: testCase.expect.status,
            successorId: testCase.expect.successorId,
            sendBlocked: testCase.expect.sendBlocked,
            modelId: testCase.expect.modelIdAfter,
          });
          // The adapter layer carries no display name stored by the conversation; the display name of cases without a stored name must match too.
          if (!testCase.conversation.storedName) expect(result?.displayName).toBe(testCase.expect.displayName);
        } finally {
          vi.useRealTimers();
        }
      });
    }

    // New-chat default (shared/test-fixtures/capability/cross-end-closure.v1.json newChatDefaultCases):
    // last used -> catalog default -> first usable, without reading the connection default (isDefault); the hint is only given when the last-used model was not used.
    const closure = (() => {
      let dir = process.cwd();
      for (let depth = 0; depth < 8; depth += 1) {
        const candidate = path.join(dir, 'shared', 'test-fixtures', 'capability', 'cross-end-closure.v1.json');
        if (existsSync(candidate)) {
          return JSON.parse(readFileSync(candidate, 'utf8')) as {
            newChatDefaultCases: {
              appliesTo: string[];
              cases: Array<{
                id: string;
                catalog: RetirementCatalog;
                userModels: string[];
                userModelCanonicalIds?: Record<string, string>;
                lastUsedModelId: string | null;
                connectionDefaultModelId: string | null;
                expect: { modelId: string | null; hint: string | null };
              }>;
            };
            newChatAcrossConnectionsCases: {
              appliesTo: string[];
              cases: Array<{
                id: string;
                connections: Array<{
                  id: string; kind?: string; catalog: RetirementCatalog; userModels: string[]; missingCredential?: boolean; issue?: boolean;
                }>;
                lastUsedRef: { connectionId: string; modelId: string } | null;
                expect: { connectionId: string | null; modelId: string | null; hint: string | null };
              }>;
            };
          };
        }
        dir = path.dirname(dir);
      }
      throw new Error('cross-end-closure.v1.json not found');
    })();

    it('CLOSURE newChatDefaultCases applies to web', () => {
      expect(closure.newChatDefaultCases.appliesTo).toContain('web');
      expect(closure.newChatDefaultCases.cases.length).toBeGreaterThan(0);
    });

    for (const testCase of closure.newChatDefaultCases.cases) {
      it(`CLOSURE-${testCase.id}`, () => {
        try {
          feedCatalog(testCase.catalog);
          // Mark isDefault on the enabled models as the fixture says, to verify that a new chat does not read it; when the connection default is not among the enabled models there is no isDefault.
          const provider = makeProvider({
            kind: 'deepSeek',
            models: testCase.userModels.map((id) => makeModel(id, {
              isDefault: id === testCase.connectionDefaultModelId,
              canonicalModelId: testCase.userModelCanonicalIds?.[id],
            })),
          });

          const snapshot = createProviderSelectionSnapshot(provider, { preferredModelId: testCase.lastUsedModelId });

          expect({ modelId: snapshot?.defaultModel?.id ?? null, hint: snapshot?.defaultModelHint ?? null })
            .toEqual(testCase.expect);
        } finally {
          vi.useRealTimers();
        }
      });
    }

    // When the own id is not in the catalog, the canonical must itself be usable (not past its shutdown date) to count as selectable, not merely listed.
    it('isModelSelectableForNewChat: missing id with shut-down canonical is not selectable', () => {
      const testCase = closure.newChatDefaultCases.cases.find((entry) => entry.id === 'last_used_missing_with_shut_down_canonical_skipped');
      expect(testCase).toBeDefined();
      try {
        feedCatalog(testCase!.catalog);
        const provider = makeProvider({ kind: 'deepSeek', models: [] });

        expect(isModelSelectableForNewChat(provider, makeModel('gpt-x-preview', { canonicalModelId: 'gpt-x' }))).toBe(false);
        expect(isModelSelectableForNewChat(provider, makeModel('gpt-y'))).toBe(true);
      } finally {
        vi.useRealTimers();
      }
    });

    // Alias: the catalog default tier of a new chat matches by alias among the usable enabled models and returns the enabled model (model-retired.v1 alias_*).
    describe('new chat default matches alias (model-retired alias_*)', () => {
      const aliasCases = fixture.newChatCases.filter((testCase) => testCase.id.startsWith('alias_'));

      it('fixture carries alias cases (8 + retired-with-canonical)', () => {
        expect(aliasCases.length).toBeGreaterThanOrEqual(9);
        expect(aliasCases.map((testCase) => testCase.id)).toContain('alias_match_retired_enabled_with_canonical_skipped');
      });

      for (const testCase of aliasCases) {
        it(`RETIRED-${testCase.id}`, () => {
          try {
            feedCatalog(testCase.catalog);
            const provider = makeProvider({
              kind: 'openAI',
              models: testCase.userModels.map((id) => makeModel(id, { canonicalModelId: testCase.userModelCanonicalIds?.[id] })),
            });

            const snapshot = createProviderSelectionSnapshot(provider, { preferredModelId: testCase.preferredModelId });

            expect(snapshot?.defaultModel?.id ?? null).toBe(testCase.expect.modelId);
          } finally {
            vi.useRealTimers();
          }
        });
      }
    });

    it('a conversation with an empty modelID: when the last-used model pointing at this connection is usable, it is the new-chat default', () => {
      feedCatalog(null);
      mockGetProviderDefaultModelId.mockReturnValue('deepseek-flash');
      const provider = makeProvider({ id: 'ds', kind: 'deepSeek', models: [makeModel('deepseek-flash'), makeModel('deepseek-v4-pro')] });

      const here = createProviderSelectionSnapshot(provider, {
        requestedModelId: '', lastUsedModelRef: { providerID: 'ds', modelID: 'deepseek-v4-pro' },
      });
      const elsewhere = createProviderSelectionSnapshot(provider, {
        requestedModelId: '', lastUsedModelRef: { providerID: 'other', modelID: 'deepseek-v4-pro' },
      });

      expect(here?.currentModel?.id).toBe('deepseek-v4-pro');
      expect(elsewhere?.currentModel?.id).toBe('deepseek-flash');
    });

    // A new chat across connections without a connection limit (cross-end-closure newChatAcrossConnectionsCases): one catalog per connection, fed by connection kind.
    it('CLOSURE newChatAcrossConnectionsCases applies to web', () => {
      expect(closure.newChatAcrossConnectionsCases.appliesTo).toContain('web');
      expect(closure.newChatAcrossConnectionsCases.cases.length).toBeGreaterThan(0);
    });

    for (const testCase of closure.newChatAcrossConnectionsCases.cases) {
      it(`CLOSURE-ACROSS-${testCase.id}`, () => {
        try {
          // Official kinds are assigned by position; they must be real provider kinds, because the missing-key check only applies to those.
          const kindOf = (index: number) => (['deepseek', 'openAI', 'anthropic'] as const)[index];
          const catalogByKind = new Map<string, RetirementCatalog>(
            testCase.connections.map((connection, index) => [kindOf(index), connection.catalog]),
          );
          mockGetProviderCatalogStatus.mockImplementation((kind?: string) => (catalogByKind.has(kind ?? '') ? 'loaded' : 'pending'));
          mockListProviderModelIds.mockImplementation((kind?: string) => catalogByKind.get(kind ?? '')?.models.map((entry) => entry.id) ?? []);
          mockGetProviderRetiredModels.mockImplementation((kind?: string) => catalogByKind.get(kind ?? '')?.retiredModels ?? []);
          mockGetProviderDefaultModelId.mockImplementation((kind?: string) => catalogByKind.get(kind ?? '')?.defaultModelId);
          mockResolveCatalogModel.mockReset();
          mockResolveCatalogModel.mockImplementation((id: string, kind?: string) => {
            const catalog = catalogByKind.get(kind ?? '');
            if (!catalog) return null;
            const canonical = catalog.resolveMap?.[id] ?? id;
            const entry = catalog.models.find((model) => model.id === canonical);
            if (!entry) return null;
            return { canonicalModelId: canonical, displayName: entry.displayName, lifecycle: entry.lifecycle };
          });
          const providers = testCase.connections.map((connection, index) => makeProvider({
            id: connection.id,
            kind: kindOf(index),
            models: connection.userModels.map((id) => makeModel(id)),
            // Missing credential = no key on this device (the production needsKey criterion); an error = status issue, which is not dropped and keeps its list position.
            ...(connection.missingCredential ? { apiKey: '' } : {}),
            ...(connection.issue ? { status: { kind: 'issue' as const } } : {}),
          }));
          const lastUsed = testCase.lastUsedRef
            ? { providerID: testCase.lastUsedRef.connectionId, modelID: testCase.lastUsedRef.modelId }
            : null;

          const picked = resolveNewChatSelection(providers, lastUsed);

          expect({
            connectionId: picked?.provider?.id ?? null,
            modelId: picked?.model?.id ?? null,
            hint: picked?.defaultModelHint ?? null,
          }).toEqual(testCase.expect);
        } finally {
          mockGetProviderCatalogStatus.mockReset();
          mockListProviderModelIds.mockReset();
          mockGetProviderRetiredModels.mockReset();
          mockGetProviderDefaultModelId.mockReset();
          vi.useRealTimers();
        }
      });
    }
  });

  describe('new-chat fallback retirement is lazy', () => {
    const MODEL_COUNT = 810;
    const ids = Array.from({ length: MODEL_COUNT }, (_, index) => `model-${String(index).padStart(3, '0')}`);
    const pastShutdown = new Set<string>();

    function loadedCatalogOf810(): Provider {
      mockGetProviderCatalogStatus.mockReturnValue('loaded');
      mockGetProviderDefaultModelId.mockReset();
      mockGetProviderDefaultModelId.mockReturnValue(undefined);
      mockListProviderModelIds.mockReturnValue([...ids]);
      mockResolveCatalogModel.mockReset();
      mockResolveCatalogModel.mockImplementation((id: string) => (ids.includes(id)
        ? {
          canonicalModelId: id,
          displayName: id,
          ...(pastShutdown.has(id)
            ? { lifecycle: { state: 'deprecated', shutdownAt: '2020-01-01T00:00:00Z' } }
            : {}),
        }
        : null));
      return makeProvider({ kind: 'openAI', models: ids.map((id) => makeModel(id)) });
    }

    beforeEach(() => {
      pastShutdown.clear();
    });

    it('810 enabled models, the first usable: the catalog is only looked up for the matched candidate (resolveCatalogModel call count is constant)', () => {
      const provider = loadedCatalogOf810();

      const snapshot = createProviderSelectionSnapshot(provider);

      expect(snapshot?.currentModel?.id).toBe('model-000');
      expect(snapshot?.defaultModel?.id).toBe('model-000');
      expect(mockResolveCatalogModel.mock.calls.length).toBeLessThanOrEqual(5);
    });

    it('a historical conversation with a usable requestedModelId: the catalog is not looked up ahead of time for the default model', () => {
      const provider = loadedCatalogOf810();

      const snapshot = createProviderSelectionSnapshot(provider, { requestedModelId: 'model-500' });

      expect(snapshot?.currentModel?.id).toBe('model-500');
      expect(mockResolveCatalogModel.mock.calls.length).toBeLessThanOrEqual(5);
    });

    it('first 3 are past their shutdown date: picks the 4th, and brings back a hint when the preference is shut down', () => {
      const provider = loadedCatalogOf810();
      pastShutdown.add('model-000');
      pastShutdown.add('model-001');
      pastShutdown.add('model-002');

      const fallback = createProviderSelectionSnapshot(provider);
      const preferred = createProviderSelectionSnapshot(provider, { preferredModelId: 'model-001' });

      expect(fallback?.currentModel?.id).toBe('model-003');
      expect(fallback?.defaultModelHint).toBeNull();
      expect(preferred?.currentModel?.id).toBe('model-003');
      expect(preferred?.defaultModelHint).toBe('last_used_retired');
      expect(preferred?.unusedPreferredModelId).toBe('model-001');
    });

    function medianMs(run: () => void): number {
      const samples: number[] = [];
      for (let index = 0; index < 15; index += 1) {
        const started = performance.now();
        run();
        samples.push(performance.now() - started);
      }
      samples.sort((a, b) => a - b);
      return samples[Math.floor(samples.length / 2)];
    }

    // Same budget on every client: 810 models, the first 100 past their shutdown date, last used retired, catalog default not enabled, capped at one frame (16 ms).
    it('last used retired + catalog default not enabled + first 100 past shutdown: picks the 101st, median < 16 ms', () => {
      const provider = loadedCatalogOf810();
      for (const id of ids.slice(0, 100)) pastShutdown.add(id);
      mockGetProviderRetiredModels.mockReturnValue([{ id: 'last-used-retired', displayName: 'Last Used' }]);
      mockGetProviderDefaultModelId.mockReturnValue('catalog-default-not-enabled');
      const lastUsedModelRef = { providerID: provider.id, modelID: 'last-used-retired' };

      const snapshot = createProviderSelectionSnapshot(provider, { lastUsedModelRef });
      const median = medianMs(() => createProviderSelectionSnapshot(provider, { lastUsedModelRef }));
      console.info(`[lazy-retirement] 810 models / first 100 retired median ${median.toFixed(3)} ms`);

      expect(snapshot?.currentModel?.id).toBe('model-100');
      expect(snapshot?.defaultModelHint).toBe('last_used_retired');
      expect(median).toBeLessThan(16);
    });

    it('all 810 past their shutdown date: returns empty, median < 16 ms', () => {
      const provider = loadedCatalogOf810();
      for (const id of ids) pastShutdown.add(id);

      const snapshot = createProviderSelectionSnapshot(provider);
      const median = medianMs(() => createProviderSelectionSnapshot(provider));
      console.info(`[lazy-retirement] 810 models / all retired median ${median.toFixed(3)} ms`);

      expect(snapshot?.currentModel).toBeNull();
      expect(snapshot?.defaultModel).toBeNull();
      expect(median).toBeLessThan(16);
    });
  });
});
