// @vitest-environment node
//
// RL2-RESOLVE-03: under one Relay connection, one model is set to Messages and another follows the connection default Chat;
// through the production path (buildProviderStreamOptions → service.sendStream('relay') → relay-orchestrator)
// requests with two transports go out. Transport and root address come only from effectiveTransport / effectiveAPIRoot.
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { __resetMetadataClientForTest } from '../../metadata/metadata-client';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../chat/stream-options';
import { sendStream } from '../service';

interface Captured { url: string; headers: Record<string, string>; body: Record<string, unknown> }

function stubFetch(): { first: () => Captured | undefined; count: () => number } {
  const calls: Captured[] = [];
  vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    if (url.includes('/api/metadata')) throw new Error('metadata unavailable');
    const headers = Object.fromEntries(Object.entries((init?.headers ?? {}) as Record<string, string>)
      .map(([key, value]) => [key.toLowerCase(), value]));
    calls.push({ url, headers, body: JSON.parse(String(init?.body)) as Record<string, unknown> });
    return new Response('data: [DONE]\n\n', { status: 200, headers: { 'content-type': 'text/event-stream' } });
  });
  return { first: () => calls[0], count: () => calls.length };
}

function model(id: string, relayTransport?: AIModel['relayTransport']): AIModel {
  return {
    id,
    name: id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: id === 'gpt-4o-mini',
    priceTier: '',
    ...(relayTransport ? { relayTransport, relayTransportSource: 'user' as const } : {}),
  } as AIModel;
}

const chatModel = model('gpt-4o-mini');
const messagesModel = model('claude-sonnet-4', 'anthropic_messages');

const provider = {
  id: 'relay-rl2-resolve-03',
  kind: 'relay',
  status: { kind: 'connected' },
  models: [chatModel, messagesModel],
  catalogModels: [],
  apiKey: 'sk-relay',
  apiKeyPreview: '••',
  baseURLText: 'https://relay.example.com',
  relayRequested: {
    transport: 'openai_chat_completions',
    authMode: 'auto',
    resolvedAPIBaseURLs: {
      openai_chat_completions: 'https://relay.example.com/v1',
      anthropic_messages: 'https://relay.example.com/anthropic/v1',
    },
  },
} as unknown as Provider;

async function capture(target: AIModel): Promise<Captured> {
  const stub = stubFetch();
  const options = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(target, undefined, false), target);
  const handle = sendStream('relay', provider.apiKey, target.id, [
    { role: 'system', content: 'be brief' },
    { role: 'user', content: 'hello' },
  ], provider.baseURLText, options);
  const reader = handle.stream.getReader();
  for (let i = 0; i < 20 && stub.count() === 0; i += 1) {
    const { done } = await reader.read();
    if (done) break;
  }
  await reader.cancel().catch(() => undefined);
  const captured = stub.first();
  if (!captured) throw new Error('relay orchestrator sent no request');
  return captured;
}

describe('RL2-RESOLVE-03 one connection emits two transports by model', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    __resetMetadataClientForTest();
  });

  it('Messages model goes to /messages with Anthropic body and auth; Chat model goes to /chat/completions', async () => {
    const messages = await capture(messagesModel);
    expect(messages.url).toBe('https://relay.example.com/anthropic/v1/messages');
    expect(messages.headers['x-api-key']).toBe('sk-relay');
    expect(messages.headers['anthropic-version']).toBe('2023-06-01');
    expect(messages.body).toMatchObject({
      model: 'claude-sonnet-4',
      system: 'be brief',
      messages: [{ role: 'user', content: [{ type: 'text', text: 'hello' }] }],
    });
    expect(messages.body).not.toHaveProperty('stream_options');

    const chat = await capture(chatModel);
    expect(chat.url).toBe('https://relay.example.com/v1/chat/completions');
    expect(chat.headers.authorization).toBe('Bearer sk-relay');
    expect(chat.body).toMatchObject({
      model: 'gpt-4o-mini',
      messages: [{ role: 'system', content: 'be brief' }, { role: 'user', content: 'hello' }],
    });
    expect(chat.body).not.toHaveProperty('system');
  });

  it('the transport and root address injected into StreamOptions are exactly the resolver results; the orchestrator only consumes', () => {
    const forMessages = buildProviderStreamOptions(provider, undefined, messagesModel);
    expect(forMessages?.relayTransport).toBe('anthropic_messages');
    expect(forMessages?.relayResolvedBaseURLText).toBe('https://relay.example.com/anthropic/v1');
    expect(forMessages?.relayResolvedAPIBaseURLIsExact).toBe(true);
    expect(forMessages?.relayAuthMode).toBe('x_api_key');
    const forChat = buildProviderStreamOptions(provider, undefined, chatModel);
    expect(forChat?.relayTransport).toBe('openai_chat_completions');
    expect(forChat?.relayAuthMode).toBe('bearer');
  });
});
