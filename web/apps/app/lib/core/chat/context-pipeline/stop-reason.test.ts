import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * stopReason persistence: when a relay stream finishes normally, done carries a StreamFinish and the assistant message records stopReason from it.
 * Assertions read the message saved at sendMessage finish for the stream received by the production Relay orchestration layer through transport.fetch.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  store: null as unknown,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest } from '../../metadata/metadata-client';
import { sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';

const model = {
  id: 'stop-model', name: 'stop-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
  contextLength: 20000, maxOutputTokens: 1000,
} as AIModel;
const provider = {
  id: 'relay-stop', kind: 'relay', status: { kind: 'connected' }, models: [model], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;

const sse = (frames: string[]) => new Response(frames.map((f) => `data: ${f}\n\n`).join(''), {
  status: 200, headers: { 'Content-Type': 'text/event-stream' },
});
let respond: () => Response = () => sse([]);

beforeEach(() => {
  localStorage.clear();
  __resetMetadataClientForTest();
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: { fetch: async () => respond() },
      buildFetchArgs: (url: string, headers: Record<string, string>) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    } as never));
});

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('relay stream finish recorded as stopReason', () => {
  it('relay_openai_chat_clean_end_records_stop', async () => {
    respond = () => sse([
      '{"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}',
      '{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
      '[DONE]',
    ]);
    const conv = {
      id: 'conv-stop', title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, providerKind: 'relay', previewText: '',
      estimatedCost: 0, isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-15T00:00:00.000Z', createdAt: '2026-10-15T00:00:00.000Z',
    };
    const store = createAppStore({ providers: [provider], conversations: [conv as never] });
    mocks.store = store;
    const stored = store.getState().conversations[0];
    await sendMessage({
      store, appendChunk: (chunk: string) => batchAppendStreaming('conv-stop', chunk), te: (key: string) => key,
    }, { text: 'hello', prevMessages: stored.messages, conversation: stored, provider, model, reasoningMode: 'automatic' }).done;

    const assistant = store.getState().conversations[0].messages.find((m) => m.role === 'assistant');
    expect(assistant?.state).toBe('delivered');
    expect(assistant?.text).toBe('ok');
    expect(assistant?.stopReason).toBe('stop');
  });
});
