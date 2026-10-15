import { describe, expect, it } from 'vitest';
import { buildAnthropicRequest } from '../request-builders/anthropic';
import { buildRelayAnthropicMessagesBody } from '../relay-orchestrator';
import { anthropicMessagesStrategy } from '../transport/strategies/anthropic-messages';
import type { ContentPart } from '../types';

// Anthropic allows at most 4 cache_control breakpoints per request: even with 5 images there must be at most 1.

const FIVE_IMAGES: ContentPart[] = [
  { type: 'text', text: 'Compare these.' },
  ...Array.from({ length: 5 }, (_, i): ContentPart => ({
    type: 'image_url',
    image_url: { url: `data:image/png;base64,SU1H${i}` },
  })),
];

const MESSAGES = [
  { role: 'system' as const, content: 'Be precise.' },
  { role: 'user' as const, content: 'Earlier question' },
  { role: 'assistant' as const, content: 'Earlier answer' },
  { role: 'user' as const, content: FIVE_IMAGES },
];

function cacheControlCount(body: unknown): number {
  return (JSON.stringify(body).match(/"cache_control"/g) ?? []).length;
}

type Block = Record<string, unknown>;
function lastUserBlocks(body: Record<string, unknown>): Block[] {
  const messages = body.messages as Array<{ role: string; content: Block[] }>;
  return messages.filter((m) => m.role === 'user').at(-1)!.content;
}

describe('Anthropic cache breakpoints stay within the limit', () => {
  it('official: only the top-level cache_control, no block-level breakpoints', () => {
    const request = buildAnthropicRequest(
      { providerKind: 'anthropic', apiKey: 'key', modelID: 'claude', messages: MESSAGES },
      null,
      null,
    );
    expect(cacheControlCount(request.body)).toBe(1);
    expect(request.body.cache_control).toEqual({ type: 'ephemeral' });
  });

  it('relay orchestrator: one block-level breakpoint on the last block of the last user message', () => {
    const body = buildRelayAnthropicMessagesBody('claude', MESSAGES, undefined);
    expect(cacheControlCount(body)).toBe(1);
    const blocks = lastUserBlocks(body);
    expect(blocks.filter((b) => b.type === 'image')).toHaveLength(5);
    expect(blocks.at(-1)).toMatchObject({ type: 'image', cache_control: { type: 'ephemeral' } });
  });

  it('relay transport strategy: one block-level breakpoint on the last block of the last user message', () => {
    const body = anthropicMessagesStrategy.buildRequestBody({ modelID: 'claude', messages: MESSAGES });
    expect(cacheControlCount(body)).toBe(1);
    expect(lastUserBlocks(body).at(-1)).toMatchObject({ type: 'image', cache_control: { type: 'ephemeral' } });
  });

  it('relay: a plain-text last user message is wrapped so it can carry the single breakpoint', () => {
    const body = anthropicMessagesStrategy.buildRequestBody({
      modelID: 'claude',
      messages: [{ role: 'user', content: 'Hello' }],
    });
    expect(body.messages).toEqual([
      { role: 'user', content: [{ type: 'text', text: 'Hello', cache_control: { type: 'ephemeral' } }] },
    ]);
  });
});
