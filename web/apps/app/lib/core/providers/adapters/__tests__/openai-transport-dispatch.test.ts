/**
 * OpenAI / Grok adapter transport dispatch driven by metadata.
 *
 * Verifies that:
 *   - metadata reporting openai_responses routes to /v1/responses
 *   - metadata reporting openai_chat routes to /v1/chat/completions
 *   - missing metadata falls back conservatively to openai_chat rather than guessing from the modelID
 *
 * The dispatch path is checked by capturing the URL through a fetch mock.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// Turn USE_PROXY off to force the direct path, where the adapter strategy dispatch lives
vi.mock('../../proxy-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../proxy-client')>();
  return { ...actual, USE_PROXY: false };
});

const metadataMocks = vi.hoisted(() => ({
  getModelTransport: vi.fn(),
}));

// metadata-client mock: the transport decision comes only from metadata, falling back conservatively to openai_chat.
vi.mock('../../../metadata/metadata-client', () => ({
  getProviderTransport: vi.fn().mockReturnValue(null),
  getWebSearchProfile: vi.fn().mockReturnValue(null),
  getModelTransport: metadataMocks.getModelTransport,
}));

import * as openAIService from '../openai';
import * as grokService from '../grok';

async function drain(handle: { stream: ReadableStream<unknown>; abort: () => void }): Promise<void> {
  const reader = handle.stream.getReader();
  try {
    await reader.read();
  } finally {
    handle.abort();
    try { reader.releaseLock(); } catch { /* noop */ }
  }
}

describe('OpenAI adapter — per-model transport dispatch', () => {
  let fetchMock: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    metadataMocks.getModelTransport.mockImplementation((modelID: string, providerKind: string) => {
      if (providerKind === 'openAI' && modelID === 'gpt-4o') return 'openai_responses';
      if (providerKind === 'openAI' && modelID === 'gpt-5-mini') return 'openai_responses';
      if (providerKind === 'openAI' && modelID === 'o3-mini') return 'openai_responses';
      if (providerKind === 'openAI' && modelID === 'gpt-3.5-turbo') return 'openai_chat';
      if (providerKind === 'openAI' && modelID === 'gpt-5-search-api') return 'openai_chat';
      return undefined;
    });
    fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('data: [DONE]\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }),
    );
  });

  afterEach(() => {
    vi.restoreAllMocks();
    metadataMocks.getModelTransport.mockReset();
  });

  it('metadata=openai_responses -> the /v1/responses endpoint', async () => {
    const handle = openAIService.sendMessageStream(
      'sk-test',
      'gpt-4o',
      [{ role: 'user', content: 'hi' }],
    );
    await drain(handle);

    expect(fetchMock).toHaveBeenCalled();
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.openai.com/v1/responses');
  });

  it('metadata=openai_responses routes newer models to /v1/responses as well', async () => {
    const handle = openAIService.sendMessageStream(
      'sk-test',
      'gpt-5-mini',
      [{ role: 'user', content: 'hi' }],
    );
    await drain(handle);
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.openai.com/v1/responses');
  });

  it('metadata=openai_responses routes the o family to /v1/responses as well', async () => {
    const handle = openAIService.sendMessageStream(
      'sk-test',
      'o3-mini',
      [{ role: 'user', content: 'hi' }],
    );
    await drain(handle);
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.openai.com/v1/responses');
  });

  it('metadata=openai_chat -> the /v1/chat/completions endpoint', async () => {
    const handle = openAIService.sendMessageStream(
      'sk-test',
      'gpt-3.5-turbo',
      [{ role: 'user', content: 'hi' }],
    );
    await drain(handle);
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.openai.com/v1/chat/completions');
  });

  it('metadata=openai_chat keeps search models on /v1/chat/completions', async () => {
    const handle = openAIService.sendMessageStream(
      'sk-test',
      'gpt-5-search-api',
      [{ role: 'user', content: 'hi' }],
    );
    await drain(handle);
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.openai.com/v1/chat/completions');
  });

  it('missing metadata does not guess responses from the modelID and falls back to openai_chat', async () => {
    metadataMocks.getModelTransport.mockReturnValue(undefined);

    const handle = openAIService.sendMessageStream(
      'sk-test',
      'gpt-5-mini',
      [{ role: 'user', content: 'hi' }],
    );
    await drain(handle);
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.openai.com/v1/chat/completions');
  });
});

describe('Grok adapter — per-model transport dispatch', () => {
  let fetchMock: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    metadataMocks.getModelTransport.mockImplementation((modelID: string, providerKind: string) => {
      if (providerKind === 'grok' && modelID === 'grok-4.1') return 'openai_responses';
      if (providerKind === 'grok' && modelID === 'grok-4-fast') return 'openai_responses';
      if (providerKind === 'grok' && modelID === 'grok-3') return 'openai_chat';
      return undefined;
    });
    fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('data: [DONE]\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }),
    );
  });

  afterEach(() => {
    vi.restoreAllMocks();
    metadataMocks.getModelTransport.mockReset();
  });

  it('metadata=openai_responses -> the /v1/responses endpoint', async () => {
    const handle = grokService.sendMessageStream(
      'sk-test',
      'grok-4.1',
      [{ role: 'user', content: 'hi' }],
      'https://api.x.ai',
    );
    await drain(handle);
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.x.ai/v1/responses');
  });

  it('metadata=openai_responses routes fast models to /v1/responses as well', async () => {
    const handle = grokService.sendMessageStream(
      'sk-test',
      'grok-4-fast',
      [{ role: 'user', content: 'hi' }],
      'https://api.x.ai',
    );
    await drain(handle);
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.x.ai/v1/responses');
  });

  it('metadata=openai_chat -> the /v1/chat/completions endpoint', async () => {
    const handle = grokService.sendMessageStream(
      'sk-test',
      'grok-3',
      [{ role: 'user', content: 'hi' }],
      'https://api.x.ai',
    );
    await drain(handle);
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.x.ai/v1/chat/completions');
  });

  it('missing metadata does not guess responses from a grok modelID and falls back to openai_chat', async () => {
    metadataMocks.getModelTransport.mockReturnValue(undefined);

    const handle = grokService.sendMessageStream(
      'sk-test',
      'grok-4.1',
      [{ role: 'user', content: 'hi' }],
      'https://api.x.ai',
    );
    await drain(handle);
    const [url] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://api.x.ai/v1/chat/completions');
  });
});
