/**
 * Usage normalization for the Relay `responses` shape.
 *
 * The contract calls out this case by name: `input_tokens` in the `responses` shape includes cache
 * reads, exactly like `prompt_tokens` in chat-completions, so using it directly as `promptTokens`
 * drops the whole cache breakdown. The user then sees "cache read: not available" even though the
 * relay did return `input_tokens_details.cached_tokens`.
 *
 * The assertions run against StreamEvents produced by `sendRelayStream`, the real browser
 * production path (relay is excluded from the proxy by the `kind !== 'relay'` check in service.ts
 * and goes through relay-orchestrator), not against objects synthesised by calling the parser directly.
 */
import { describe, expect, it } from 'vitest';
import { sendRelayStream, type RelayOrchestratorDeps } from '../relay-orchestrator';
import type { StreamEvent, StreamOptions } from '../types';
import type { UpstreamTransport } from '../../ports';

const RESPONSES_OPTIONS: StreamOptions = {
  relayTransport: 'openai_responses',
  relayAuthMode: 'bearer',
};

function sseWithUsage(usage: Record<string, unknown>): string {
  return (
    'event: response.output_text.delta\ndata: {"delta":"hi"}\n\n' +
    `event: response.completed\ndata: ${JSON.stringify({ response: { usage } })}\n\n` +
    'data: [DONE]\n\n'
  );
}

function relayDeps(usage: Record<string, unknown>): RelayOrchestratorDeps {
  const transport: UpstreamTransport = {
    fetch: async () =>
      new Response(sseWithUsage(usage), {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }),
  };
  return {
    transport,
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
}

async function usageEvent(usage: Record<string, unknown>) {
  const handle = sendRelayStream(
    'sk-test',
    'gpt-5.6-sol',
    [{ role: 'user', content: 'hello' }],
    'https://relay.example/v1',
    RESPONSES_OPTIONS,
    relayDeps(usage),
  );
  const events: StreamEvent[] = [];
  const reader = handle.stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    events.push(value);
  }
  const event = events.find((e) => e.type === 'usage');
  if (!event || event.type !== 'usage') throw new Error('the relay stream produced no usage event');
  return event.usage;
}

describe('relay responses usage normalization', () => {
  it('keeps the cache read when the relay returns input_tokens_details.cached_tokens', async () => {
    const usage = await usageEvent({
      input_tokens: 1000,
      output_tokens: 120,
      total_tokens: 1120,
      input_tokens_details: { cached_tokens: 900 },
      output_tokens_details: { reasoning_tokens: 64 },
    });

    expect(usage.breakdown).toMatchObject({
      // promptTokens is the newly billed input with the cache subtracted; the upstream input_tokens includes the cache read.
      promptTokens: 100,
      cachedInputTokens: 900,
      completionTokens: 120,
      reasoningTokens: 64,
      cacheReadObserved: true,
    });
    // The displayed total input stays at 1000 including the cache, matching the inputTokens semantics of the cost contract.
    expect(usage.prompt_tokens).toBe(1000);
  });

  it('records an explicit 0 as observed, while a missing field means unobserved', async () => {
    const explicitZero = await usageEvent({
      input_tokens: 500,
      output_tokens: 10,
      input_tokens_details: { cached_tokens: 0 },
    });
    expect(explicitZero.breakdown).toMatchObject({ cachedInputTokens: 0, cacheReadObserved: true });

    const absent = await usageEvent({ input_tokens: 500, output_tokens: 10 });
    expect(absent.breakdown?.cacheReadObserved).toBe(false);
    expect(absent.breakdown).toMatchObject({ promptTokens: 500, completionTokens: 10 });
  });
});
