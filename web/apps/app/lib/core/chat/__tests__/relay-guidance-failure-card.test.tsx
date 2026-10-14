import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
  * RL2-GUIDE-18: the relay guidance must be the body the user sees on the chat failure card.
  * The production send chain (sendMessage / continueAnswering -> production Relay orchestration layer -> fake upstream returning an official CLI gate 403) stores the failure message,
  * then MessageRecoveryCard is rendered with real zh-Hans copy: the body is the localized guidance sentence, the original upstream text is in the technical detail, and the title is not "Invalid API Key".
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';
import { RELAY_GUIDANCE } from '@oriveo/core/providers/relay-error-classifier';
import { RELAY_HTML_PAGE_ERROR } from '@oriveo/core/providers/relay-stream';

const zhHans = JSON.parse(readFileSync(path.join(process.cwd(), 'messages', 'zh-Hans.json'), 'utf8')) as Record<string, unknown>;

function lookup(namespace: string, key: string): string {
  const value = [...namespace.split('.'), ...key.split('.')].filter(Boolean)
    .reduce<unknown>((node, part) => (node as Record<string, unknown> | undefined)?.[part], zhHans);
  return typeof value === 'string' ? value : key;
}

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  store: null as unknown,
  translators: new Map<string, (key: string) => string>(),
}));

vi.mock('next-intl', () => ({
  // One function instance per namespace: the component puts t into deps, and a new instance each time would cause endless re-renders.
  useTranslations: (namespace = '') => {
    let translate = mocks.translators.get(namespace);
    if (!translate) {
      translate = (key: string) => lookup(namespace, key);
      mocks.translators.set(namespace, translate);
    }
    return translate;
  },
}));
vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn(), addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../../utils/chat-stream-utils', async () => ({
  ...await vi.importActual<typeof import('../../../utils/chat-stream-utils')>('../../../utils/chat-stream-utils'),
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
}));
vi.mock('../../usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../usage/budget-check', () => ({ checkBudgetExceeded: vi.fn() }));
vi.mock('../../sync', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../../store/app-store';
import { continueAnswering, sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';
import { MessageRecoveryCard } from '../../../../components/chat/MessageRecoveryCard';

const GATE_MESSAGE = 'This API endpoint is only accessible via the official Claude CLI';
const GATE_BODY = JSON.stringify({ type: 'error', error: { type: 'permission_error', message: GATE_MESSAGE } });
const ZH_GUIDANCE = lookup('errors', 'relay.clientGated');

const provider = {
  id: 'relay-1', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'anthropic_messages', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'anthropic_messages', relayResolvedAuthMode: 'x_api_key',
} as unknown as Provider;
const model = {
  id: 'claude-sonnet-4-5', name: 'claude-sonnet-4-5', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
} as AIModel;

let requests = 0;
let respond: () => Response;

function newStore(messages: ChatMessage[] = []) {
  const conv = {
    id: 'conv-1', title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, previewText: '', estimatedCost: 0,
    isDraft: false, messages, draftText: '', updatedAt: '2026-10-12T00:00:00.000Z',
  } as Conversation;
  const store = createAppStore({ providers: [provider], conversations: [conv] });
  mocks.store = store;
  return store;
}

const ctxOf = (store: ReturnType<typeof createAppStore>) => ({
  store, appendChunk: (chunk: string) => batchAppendStreaming('conv-1', chunk), te: (key: string) => lookup('errors', key),
});

function renderFailureCard(failed: ChatMessage) {
  render(
    <MessageRecoveryCard
      state="failed"
      errorTitle={failed.errorTitle}
      errorDetail={failed.errorDetail}
      errorKind={failed.errorKind}
      errorSource={failed.errorSource}
      technicalDetail={failed.errorTechnicalDetail}
    />,
  );
}

function expectGuidanceCard(failed: ChatMessage) {
  expect(failed.state).toBe('failed');
  // Store the English guidance source sentence; it is localized at render time (RL2-COPY-R1)
  expect(failed.errorDetail).toBe(RELAY_GUIDANCE.clientGated);
  expect(failed.errorTechnicalDetail).toContain(GATE_MESSAGE);
  expect(failed.errorKind).not.toBe('invalidKey');
  renderFailureCard(failed);
  expect(screen.getByText(ZH_GUIDANCE)).toBeTruthy();
  expect(screen.getByText(/only accessible via the official Claude CLI/)).toBeTruthy();
  expect(screen.queryByText(lookup('errors', 'invalidKey.title'))).toBeNull();
}

beforeEach(() => {
  localStorage.clear();
  requests = 0;
  respond = () => new Response(GATE_BODY, { status: 403, headers: { 'Content-Type': 'application/json' } });
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hi' }]);
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: {
        fetch: async () => {
          requests += 1;
          return respond();
        },
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    }));
});

describe('RL2-GUIDE-18 the chat failure card shows the localized guidance sentence and the upstream original detail', () => {
  it('RL2-GUIDE-18 sendMessage: CLI gate 403 -> body is the zh-Hans guidance sentence, technical detail is the upstream original, protocol not switched', async () => {
    const store = newStore();
    const conv = store.getState().conversations[0];
    await sendMessage(ctxOf(store), { text: 'hello', prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic' }).done;
    expect(requests).toBe(1);
    const failed = store.getState().conversations[0].messages.find((m) => m.role === 'assistant') as ChatMessage;
    expectGuidanceCard(failed);
  });

  it('RL2-GUIDE-18 continueAnswering: the same payload lands on the same card', async () => {
    const user: ChatMessage = {
      id: 'u1', role: 'user', text: 'hello', providerID: provider.id, providerKind: provider.kind, providerName: 'Relay',
      modelID: model.id, modelName: model.name, estimatedCost: 0, state: 'delivered',
    };
    const interrupted: ChatMessage = { ...user, id: 'msg-1', role: 'assistant', text: 'partial', state: 'interrupted' };
    const store = newStore([user, interrupted]);
    const conv = store.getState().conversations[0];
    await continueAnswering(ctxOf(store), {
      messageId: 'msg-1', conversation: conv, messages: conv.messages, provider, model, reasoningMode: 'automatic',
    }).done;
    const failed = store.getState().conversations[0].messages.find((m) => m.id === 'msg-1') as ChatMessage;
    expectGuidanceCard(failed);
  });
  it('RL2-GUIDE-18b when the streamed body is a web page the failure card shows the localized web-page sentence', async () => {
    // Follows the connection (single protocol, no fallback candidate): sent only once, the web-page sentence is the final state.
    respond = () => new Response('\n<!DOCTYPE html><html><body><div id="root"></div></body></html>', {
      status: 200, headers: { 'Content-Type': 'text/event-stream' },
    });
    const store = newStore();
    const conv = store.getState().conversations[0];
    await sendMessage(ctxOf(store), { text: 'hello', prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic' }).done;
    expect(requests).toBe(1);
    const failed = store.getState().conversations[0].messages.find((m) => m.role === 'assistant') as ChatMessage;
    const zhWebPage = lookup('errors', 'relay.webPageReturned');
    expect(failed.state).toBe('failed');
    expect(failed.errorDetail).toBe(RELAY_HTML_PAGE_ERROR);
    renderFailureCard(failed);
    expect(screen.getAllByText(zhWebPage).length).toBeGreaterThan(0);
    expect(screen.queryByText(/returned a web page instead of a model response/)).toBeNull();
  });
});
