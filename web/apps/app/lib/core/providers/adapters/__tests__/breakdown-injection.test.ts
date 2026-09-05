/**
 * Regression test: the three custom parseChunk adapters (DeepSeek, Moonshot, OpenRouter)
 * and Relay must inject a UsageBreakdown into the 'usage' event. Without it the downstream
 * deriveCostFields falls back to estimateCost, which has no cache split, and the cache
 * discount is lost.
 */

import { afterEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../proxy-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../proxy-client')>();
  return { ...actual, USE_PROXY: false };
});

import * as deepseek from '../deepseek';
import * as moonshot from '../moonshot';
import * as openrouter from '../openrouter';
import type { StreamEvent } from '../types';

function buildSSE(...chunks: Record<string, unknown>[]): string {
  return chunks.map((c) => `data: ${JSON.stringify(c)}\n\n`).join('') + 'data: [DONE]\n\n';
}

async function collect(stream: ReadableStream<StreamEvent>): Promise<StreamEvent[]> {
  const reader = stream.getReader();
  const events: StreamEvent[] = [];
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      if (value) events.push(value);
    }
  } finally {
    try { reader.releaseLock(); } catch { /* noop */ }
  }
  return events;
}

function mockSSE(body: string) {
  return vi.spyOn(globalThis, 'fetch').mockResolvedValue(
    new Response(body, {
      status: 200,
      headers: { 'Content-Type': 'text/event-stream' },
    }),
  );
}

describe('DeepSeek adapter — breakdown injection', () => {
  afterEach(() => vi.restoreAllMocks());

  it('does not inject thinking parameters locally when there is no metadata profile', async () => {
    const fetchMock = mockSSE(buildSSE({ choices: [{ delta: { content: 'ok' } }] }));

    const handle = deepseek.sendMessageStream(
      'sk-test',
      'deepseek-reasoner',
      [{ role: 'user', content: 'hi' }],
      'https://api.deepseek.com/v1',
      { reasoning: 'deep' },
    );
    await collect(handle.stream);

    const init = fetchMock.mock.calls[0]?.[1] as RequestInit;
    const body = JSON.parse(String(init.body)) as { thinking?: unknown };
    expect(body.thinking).toBeUndefined();
  });

  it('the injected breakdown separates prompt_cache_hit_tokens from prompt_cache_miss_tokens', async () => {
    const body = buildSSE(
      { choices: [{ delta: { content: 'hello' } }], usage: null },
      { choices: [{ delta: {} }], usage: {
        prompt_tokens: 100,
        prompt_cache_hit_tokens: 80,
        prompt_cache_miss_tokens: 20,
        completion_tokens: 30,
      } },
    );
    mockSSE(body);

    const handle = deepseek.sendMessageStream(
      'sk-test', 'deepseek-chat', [{ role: 'user', content: 'hi' }],
      'https://api.deepseek.com/v1',
    );
    const events = await collect(handle.stream);
    const usage = events.find((e) => e.type === 'usage');
    expect(usage).toBeDefined();
    expect(usage!.usage.breakdown).toBeDefined();
    // miss maps to promptTokens, hit maps to cachedInputTokens  
    expect(usage!.usage.breakdown!.promptTokens).toBe(20);
    expect(usage!.usage.breakdown!.cachedInputTokens).toBe(80);
    expect(usage!.usage.breakdown!.completionTokens).toBe(30);
  });

  it('reasoning_content also emits a reasoning event, matching the other clients', async () => {
    const body = buildSSE(
      { choices: [{ delta: { reasoning_content: 'thinking…' } }] },
      { choices: [{ delta: { content: 'answer' } }] },
    );
    mockSSE(body);

    const handle = deepseek.sendMessageStream(
      'sk-test', 'deepseek-reasoner', [{ role: 'user', content: 'hi' }],
      'https://api.deepseek.com/v1',
    );
    const events = await collect(handle.stream);
    expect(events.some((e) => e.type === 'reasoning')).toBe(true);
    expect(events.some((e) => e.type === 'delta')).toBe(true);
  });
});

describe('Moonshot adapter — breakdown injection', () => {
  afterEach(() => vi.restoreAllMocks());

  it('the injected breakdown recognises a top-level cached_tokens (not under prompt_tokens_details)', async () => {
    const body = buildSSE(
      { choices: [{ delta: { content: 'hi' } }] },
      { choices: [{ delta: {} }], usage: {
        prompt_tokens: 200,
        completion_tokens: 50,
        cached_tokens: 150, // Moonshot   prompt_tokens_details 
      } },
    );
    mockSSE(body);

    const handle = moonshot.sendMessageStream(
      'sk-test', 'moonshot-v1-8k', [{ role: 'user', content: 'hi' }],
      'https://api.moonshot.cn/v1',
    );
    const events = await collect(handle.stream);
    const usage = events.find((e) => e.type === 'usage');
    expect(usage).toBeDefined();
    expect(usage!.usage.breakdown).toBeDefined();
    expect(usage!.usage.breakdown!.cachedInputTokens).toBe(150);
    expect(usage!.usage.breakdown!.promptTokens).toBe(50); // 200 - 150
  });
});

describe('OpenRouter adapter — breakdown injection', () => {
  afterEach(() => vi.restoreAllMocks());

  it('the injected breakdown passes the upstream cost through (OpenRouter already applies the cache discount)', async () => {
    const body = buildSSE(
      { choices: [{ delta: { content: 'hi' } }] },
      { choices: [{ delta: {} }], usage: {
        prompt_tokens: 100,
        completion_tokens: 50,
        cost: 0.000123,
        prompt_tokens_details: { cached_tokens: 30, cache_write_tokens: 10 },
      } },
    );
    mockSSE(body);

    const handle = openrouter.sendMessageStream(
      'sk-test', 'openai/gpt-4o', [{ role: 'user', content: 'hi' }],
    );
    const events = await collect(handle.stream);
    const usage = events.find((e) => e.type === 'usage');
    expect(usage).toBeDefined();
    expect(usage!.usage.breakdown).toBeDefined();
    expect(usage!.usage.breakdown!.upstreamCost).toBeCloseTo(0.000123, 8);
    expect(usage!.usage.breakdown).toMatchObject({
      promptTokens: 60,
      cachedInputTokens: 30,
      cacheCreation1hTokens: 10,
    });
  });
});
