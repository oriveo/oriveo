// Retirement of the relay default model: the fallback model, the verification sample, and removal of the session model.
// Fixture source: shared/test-fixtures/relay/model-selection.v1.json (cases RD1-SELECT-<id>).
import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import type { AIModel, Conversation, LastUsedModelRef, Provider } from '@oriveo/shared';

// For relays, the selection snapshot first does official catalog enrichment; here only the fallback and removal criteria are tested, and enrichment passes through unchanged.
vi.mock('../../providers/relay-official-catalog-match', () => ({
  enrichRelayCatalog: (models: AIModel[]) => models,
}));

import { createAppStore } from '../../store/app-store';
import { updateConversationModel } from '../../conversation-ops';
import {
  createProviderSelectionSnapshot,
  resolveRelayFallbackModel,
  resolveRelayVerificationSampleModelID,
} from '../../providers/provider-selection-snapshot';
import { resolveActiveSelection } from '../active-selection';
import { resolveConversationModelRemoval } from '../conversation-model-status';

interface FixtureCase {
  id: string;
  provider: {
    id: string;
    kind: Provider['kind'];
    name: string;
    engineProfile?: 'ollama';
    models: Array<{ id: string; isDefault?: boolean }>;
    catalogModels: string[];
  };
  lastUsedModelRef: { providerId: string; modelId: string } | null;
  conversationModelId: string | null;
  expect: {
    fallbackModelId?: string | null;
    verificationSampleModelId?: string | null;
    removed: boolean;
    connectionName?: string;
    conversationModelId?: string;
  };
}

const fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'model-selection.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as { cases: FixtureCase[] };
    dir = path.dirname(dir);
  }
  throw new Error('model-selection.v1.json not found');
})();

function makeModel(id: string, isDefault = false): AIModel {
  return {
    id,
    name: id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault,
    priceTier: '',
  };
}

function providerFromFixture(input: FixtureCase['provider']): Provider {
  return {
    id: input.id,
    kind: input.kind,
    customName: input.name,
    status: { kind: 'connected' },
    models: input.models.map((model) => makeModel(model.id, model.isDefault === true)),
    catalogModels: input.catalogModels.map((id) => makeModel(id)),
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-...test',
    ...(input.kind === 'relay'
      ? {
          baseURLText: 'https://relay.example.com/v1',
          relayKind: 'openai_compatible' as const,
          relayRequested: {
            transport: 'openai_chat_completions' as const,
            authMode: 'bearer' as const,
            ...(input.engineProfile ? { engineProfile: input.engineProfile } : {}),
          },
        }
      : {}),
  };
}

function lastUsedFromFixture(ref: FixtureCase['lastUsedModelRef']): LastUsedModelRef | null {
  return ref ? { providerID: ref.providerId, modelID: ref.modelId } : null;
}

function conversationFor(provider: Provider, modelID: string): Conversation {
  return {
    id: 'conversation-1',
    title: '',
    hasCustomTitle: false,
    providerID: provider.id,
    providerKind: provider.kind,
    modelID,
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: '2026-10-12T00:00:00.000Z',
    createdAt: '2026-10-12T00:00:00.000Z',
  } as Conversation;
}

describe('RD1-SELECT fixture model-selection.v1.json', () => {
  for (const testCase of fixture.cases) {
    it(`RD1-SELECT-${testCase.id}`, () => {
      const provider = providerFromFixture(testCase.provider);
      const lastUsed = lastUsedFromFixture(testCase.lastUsedModelRef);

      if (provider.kind === 'relay') {
        expect(resolveRelayFallbackModel(provider.id, provider.models, lastUsed)?.id ?? null)
          .toBe(testCase.expect.fallbackModelId);
        expect(resolveRelayVerificationSampleModelID(provider, lastUsed))
          .toBe(testCase.expect.verificationSampleModelId);
        // The "default model" of the production selection snapshot = the fallback function result; the old isDefault plays no part.
        expect(createProviderSelectionSnapshot(provider, { lastUsedModelRef: lastUsed })?.defaultModel?.id ?? null)
          .toBe(testCase.expect.fallbackModelId);
      }

      const removal = resolveConversationModelRemoval(provider, testCase.conversationModelId);
      expect(Boolean(removal)).toBe(testCase.expect.removed);
      if (testCase.expect.connectionName) expect(removal?.connectionName).toBe(testCase.expect.connectionName);

      if (testCase.conversationModelId !== null && provider.kind === 'relay') {
        const conversation = conversationFor(provider, testCase.conversationModelId);
        const selection = resolveActiveSelection([provider], conversation, null, null, lastUsed, true);
        expect(Boolean(selection.modelRemoval)).toBe(testCase.expect.removed);
        if (testCase.expect.removed) {
          // No silent replacement: there is no current model, and the send entry returns with zero requests accordingly.
          expect(selection.currentModel).toBeUndefined();
          expect(selection.modelRemoval?.connectionName).toBe(testCase.expect.connectionName);
        } else if (testCase.expect.conversationModelId) {
          expect(selection.currentModel?.id).toBe(testCase.expect.conversationModelId);
        } else {
          // An empty session model takes the fallback.
          expect(selection.currentModel?.id).toBe(testCase.expect.fallbackModelId);
        }
        // The model stored in the session is left untouched.
        expect(conversation.modelID).toBe(testCase.conversationModelId);
      }
    });
  }
});

describe('RD-1 reselection after the session model is removed, and fallback for new chats', () => {
  it('RD1-BANNER-02 a removed session picks a new model through the production selection path -> session model updated, banner disappears', () => {
    const provider = providerFromFixture({
      id: 'relay-a', kind: 'relay', name: 'My Relay', models: [{ id: 'gpt-5.4' }], catalogModels: [],
    });
    const store = createAppStore({
      providers: [provider],
      conversations: [conversationFor(provider, 'claude-4-haiku')],
    });
    const before = resolveActiveSelection(
      store.getState().providers, store.getState().conversations[0], null, null, null, true,
    );
    expect(before.modelRemoval).toEqual({ modelID: 'claude-4-haiku', connectionName: 'My Relay' });

    // useChatModelSelection.handleModelSelect writes the model back into the session through exactly this function.
    updateConversationModel(store, 'conversation-1', 'gpt-5.4', provider.id);

    const after = resolveActiveSelection(
      store.getState().providers, store.getState().conversations[0], null, null, null, true,
    );
    expect(store.getState().conversations[0]?.modelID).toBe('gpt-5.4');
    expect(after.modelRemoval).toBeUndefined();
    expect(after.currentModel?.id).toBe('gpt-5.4');
  });

  it('RD1-SELECT the session stores the canonical id of an enabled model / case differs -> not counted as removed; only the base remains for a dated version -> removed', () => {
    const provider = providerFromFixture({
      id: 'relay-a', kind: 'relay', name: 'My Relay', models: [{ id: 'GPT-5.4' }], catalogModels: [],
    });
    provider.models = [{ ...provider.models[0]!, canonicalModelId: 'openai/gpt-5.4' }];
    for (const stored of ['gpt-5.4', 'openai/gpt-5.4']) {
      expect(resolveConversationModelRemoval(provider, stored), stored).toBeNull();
      const selection = resolveActiveSelection([provider], conversationFor(provider, stored), null, null, null, true);
      expect(selection.modelRemoval, stored).toBeUndefined();
      expect(selection.currentModel?.id, stored).toBe('GPT-5.4');
    }
    // On a relay, a dated snapshot and its base are two different models: a stored snapshot that is not among the enabled ones is removed, and is not merged into the base.
    expect(resolveConversationModelRemoval(provider, 'GPT-5.4-2026-03-01')).toMatchObject({ modelID: 'GPT-5.4-2026-03-01' });
  });

  it('RD1-NEWCHAT-01 when lastUsedModelRef points elsewhere, starting a new chat from a relay connection -> the first enabled model', () => {
    const provider = providerFromFixture({
      id: 'relay-a',
      kind: 'relay',
      name: 'My Relay',
      models: [{ id: 'gpt-5.4' }, { id: 'claude-4-haiku', isDefault: true }],
      catalogModels: [],
    });
    const elsewhere: LastUsedModelRef = { providerID: 'openai', modelID: 'gpt-5.6-sol' };

    // "Start chat" on the detail page (useProviderChatLauncher) takes the default model of the snapshot.
    expect(createProviderSelectionSnapshot(provider, { lastUsedModelRef: elsewhere })?.defaultModel?.id)
      .toBe('gpt-5.4');
    // When the chat page has selected this connection and no model has been tapped yet, it likewise lands on the first enabled model.
    expect(resolveActiveSelection([provider], undefined, provider.id, null, elsewhere, true).currentModel?.id)
      .toBe('gpt-5.4');
  });
});
