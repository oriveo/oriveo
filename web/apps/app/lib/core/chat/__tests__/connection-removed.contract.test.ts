// A conversation whose connection was deleted: no fallback, no rewrite, send blocked (selection layer + send entry + user pick).
// Fixture source: shared/test-fixtures/provider-catalog/connection-removed.v1.json (cases CONNECTION-REMOVED-<id>).
// The banner fields assert the selection layer's connectionRemoved state; the banner UI is covered separately.
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { StoreApi } from 'zustand';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import type { AppStore } from '../../store/app-store';

// Catalog not loaded: retirement resolves to available. Only network / storage reads are isolated; the verdict itself goes through the production path.
vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../metadata/metadata-client')>()),
  getProviderRetiredModels: () => [],
  getProviderCatalogStatus: () => 'pending',
}));

import {
  resolveActiveSelection,
  resolveConnectionRemovedPrompt,
} from '../active-selection';
import { ConversationConnectionRemovedError, prepareSendStart } from '../send-start';
import { updateConversationModel } from '../../conversation-ops';

type CaseEvent = 'open' | 'send' | { pick: { providerId: string; modelId: string } };

interface ConnectionRemovedCase {
  id: string;
  conversation: { providerId: string; modelId: string };
  connections: string[];
  event: CaseEvent;
  expect: {
    banner: string | null;
    action?: string;
    sendAllowed?: boolean;
    requestSent?: boolean;
    storedProviderId: string;
    storedModelId: string;
  };
}

const fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'provider-catalog', 'connection-removed.v1.json');
    if (existsSync(candidate)) {
      return JSON.parse(readFileSync(candidate, 'utf8')) as { cases: ConnectionRemovedCase[] };
    }
    dir = path.dirname(dir);
  }
  throw new Error('connection-removed.v1.json not found');
})();

const MODEL_IDS = ['gpt-5.5', 'deepseek-flash'];

function makeModel(id: string): AIModel {
  return {
    id,
    name: id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: id === 'deepseek-flash',
    priceTier: '$',
  };
}

function makeProvider(id: string): Provider {
  return {
    id,
    name: id,
    kind: 'deepSeek',
    status: { kind: 'connected' },
    models: MODEL_IDS.map(makeModel),
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-...test',
  } as unknown as Provider;
}

function makeMessage(id: string, role: 'user' | 'assistant'): ChatMessage {
  return { id, role, text: role === 'user' ? 'Hello' : '', state: role === 'user' ? 'delivered' : 'generating' } as unknown as ChatMessage;
}

function makeConversation(c: ConnectionRemovedCase['conversation']): Conversation {
  return {
    id: 'conversation-1',
    title: 'Chat',
    providerID: c.providerId,
    providerKind: 'deepSeek',
    modelID: c.modelId,
    messages: [makeMessage('user-1', 'user'), { ...makeMessage('assistant-1', 'assistant'), state: 'delivered' }],
    createdAt: '2026-10-01T00:00:00.000Z',
    updatedAt: '2026-10-01T00:00:00.000Z',
  } as unknown as Conversation;
}

function makeStore(conversation: Conversation, providers: Provider[], providersHydrated = true) {
  const state = {
    providers,
    providersHydrated,
    conversations: [conversation],
    updateConversation: vi.fn((id: string, patch: Partial<Conversation>) => {
      state.conversations = state.conversations.map((c) => (c.id === id ? { ...c, ...patch } : c));
    }),
    addConversation: vi.fn(),
    setActiveConversationId: vi.fn(),
    setLastUsedModelRef: vi.fn(),
    beginStreamingForConversation: vi.fn(),
  };
  const store = {
    getState: () => state,
    setState: (patch: Partial<typeof state>) => { Object.assign(state, patch); },
  } as unknown as StoreApi<AppStore>;
  return { store, state };
}

// The banner / action / send block all come from the production verdict resolveConnectionRemovedPrompt (the composer consumes it directly).
function promptOf(selection: ReturnType<typeof resolveActiveSelection>, connectionCount: number) {
  return resolveConnectionRemovedPrompt(selection, connectionCount);
}

describe('connection removed contract', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  for (const testCase of fixture.cases) {
    it(`CONNECTION-REMOVED-${testCase.id}`, () => {
      const providers = testCase.connections.map(makeProvider);
      const { store, state } = makeStore(makeConversation(testCase.conversation), providers);
      // Other selected / lastUsed preferences must not be fallen through to either.
      const lastUsed = providers[0] ? { providerID: providers[0].id, modelID: 'deepseek-flash' } : null;
      const resolve = () => resolveActiveSelection(
        providers, state.conversations[0], lastUsed?.providerID ?? null, lastUsed?.modelID ?? null, lastUsed,
        state.providersHydrated,
      );
      const event = testCase.event;

      if (event === 'send') {
        const before = state.conversations[0];
        const selection = resolve();
        expect(promptOf(selection, providers.length)?.banner ?? null).toBe(testCase.expect.banner);
        // Defense: if the entry misses the verdict and sends through the first connection, the send entry writes nothing and opens no stream.
        const fallback = providers[0];
        expect(fallback).toBeDefined();
        expect(() => prepareSendStart({
          store,
          userMsg: makeMessage('user-2', 'user'),
          assistantMsg: makeMessage('assistant-2', 'assistant'),
          prevMessages: before.messages,
          conversation: before,
          provider: fallback!,
          model: makeModel('deepseek-flash'),
          reasoningMode: 'automatic',
          webSearchEnabled: false,
          attachments: undefined,
          skillId: undefined,
        })).toThrow(ConversationConnectionRemovedError);
        const requestSent = state.beginStreamingForConversation.mock.calls.length > 0;
        expect(requestSent).toBe(testCase.expect.requestSent);
        expect(state.updateConversation).not.toHaveBeenCalled();
        expect(state.setLastUsedModelRef).not.toHaveBeenCalled();
        expect(state.addConversation).not.toHaveBeenCalled();
        expect(state.conversations[0]).toBe(before);
      } else {
        if (typeof event === 'object') {
          const { providerId, modelId } = event.pick;
          updateConversationModel(store, 'conversation-1', modelId, providerId);
        }
        const selection = resolve();
        const prompt = promptOf(selection, providers.length);
        expect(prompt?.banner ?? null).toBe(testCase.expect.banner);
        if (prompt) {
          expect(prompt.sendAllowed).toBe(testCase.expect.sendAllowed);
          expect(prompt.action).toBe(testCase.expect.action);
          // Fixture: with no connection at all, choose_model goes to the connection setup path.
          expect(prompt.target).toBe(providers.length === 0 ? 'connection_setup' : 'model_switcher');
          // Another connection's model is not treated as this conversation's.
          expect(selection.provider).toBeUndefined();
          expect(selection.currentModel).toBeUndefined();
          expect(selection.connectionRemoved).toEqual({
            providerId: testCase.conversation.providerId,
            modelId: testCase.conversation.modelId,
          });
        } else {
          // No banner and no removal / retirement verdict: the selection layer lands on the stored connection and model, which can send.
          expect(testCase.expect.sendAllowed).toBe(true);
          expect(selection.modelRemoval).toBeUndefined();
          expect(selection.modelRetirement?.sendBlocked ?? false).toBe(false);
          expect(selection.provider?.id).toBe(testCase.expect.storedProviderId);
          expect(selection.currentModel?.id).toBe(testCase.expect.storedModelId);
        }
      }

      expect(state.conversations[0].providerID).toBe(testCase.expect.storedProviderId);
      expect(state.conversations[0].modelID).toBe(testCase.expect.storedModelId);
    });
  }
});

// The connection-list hydration gate (the send entry goes through the production prepareSendStart path).
describe('connection removed send gate: hydration', () => {
  function sendWith(store: StoreApi<AppStore>, conversation: Conversation, provider: Provider) {
    return prepareSendStart({
      store,
      userMsg: makeMessage('user-2', 'user'),
      assistantMsg: makeMessage('assistant-2', 'assistant'),
      prevMessages: conversation.messages,
      conversation,
      provider,
      model: makeModel('deepseek-flash'),
      reasoningMode: 'automatic',
      webSearchEnabled: false,
      attachments: undefined,
      skillId: undefined,
    });
  }

  it('before the connection list has loaded, a bound connection that is not in the list is still blocked and the connection is not silently swapped', () => {
    const fallback = makeProvider('deepseek-other');
    const conversation = makeConversation({ providerId: 'deepseek-removed', modelId: 'deepseek-flash' });
    const { store, state } = makeStore(conversation, [fallback], false);
    expect(() => sendWith(store, conversation, fallback)).toThrow(ConversationConnectionRemovedError);
    expect(state.beginStreamingForConversation).not.toHaveBeenCalled();
  });

  it('once loaded, a connection that is missing is still judged removed', () => {
    const fallback = makeProvider('deepseek-other');
    const conversation = makeConversation({ providerId: 'deepseek-removed', modelId: 'deepseek-flash' });
    const { store, state } = makeStore(conversation, [fallback]);
    expect(() => sendWith(store, conversation, fallback)).toThrow(ConversationConnectionRemovedError);
    expect(state.beginStreamingForConversation).not.toHaveBeenCalled();
  });
});
