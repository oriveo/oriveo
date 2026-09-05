/**
 * Unit tests for gemini_generate Strategy chunk parsing against fixtures.
 *
 * Citations come from the groundingMetadata.groundingChunks path, using the web.uri / web.title fields.
 */

import { describe, expect, it } from 'vitest';
import { detectGeminiBlockEvent, geminiGenerateStrategy } from '../strategies/gemini-generate';
import { createStreamContext } from '../transport-strategy';

function toArr(result: ReturnType<typeof geminiGenerateStrategy.parseStreamChunk>) {
  if (result == null) return [];
  return Array.isArray(result) ? result : [result];
}

describe('geminiGenerateStrategy.buildRequestBody', () => {
  it('turns a system message into systemInstruction', () => {
    const body = geminiGenerateStrategy.buildRequestBody({
      modelID: 'gemini-2.5-flash',
      messages: [
        { role: 'system', content: 'system-msg' },
        { role: 'user', content: 'hello' },
      ],
    });
    expect(body.systemInstruction).toBeDefined();
  });

  it('maps an assistant message to the model role', () => {
    const body = geminiGenerateStrategy.buildRequestBody({
      modelID: 'gemini-2.5-flash',
      messages: [{ role: 'assistant', content: 'AI reply' }],
    });
    const contents = body.contents as Array<{ role: string }>;
    expect(contents[0].role).toBe('model');
  });

  it('official provider request body does not infer thinkingLevel from model ID', () => {
    const body = geminiGenerateStrategy.buildRequestBody({
      modelID: 'gemini-3.1-flash',
      messages: [{ role: 'user', content: 'hello' }],
      options: { reasoning: 'deep' },
    });
    const generationConfig = body.generationConfig as
      | { thinkingConfig?: { thinkingLevel?: string; thinkingBudget?: number } }
      | undefined;
    expect(generationConfig?.thinkingConfig?.thinkingLevel).toBeUndefined();
    expect(generationConfig?.thinkingConfig?.thinkingBudget).toBeUndefined();
  });
});

describe('geminiGenerateStrategy.parseStreamChunk', () => {
  it('chunk 1: candidates parts text emit delta', () => {
    const ctx = createStreamContext();
    const events = toArr(
      geminiGenerateStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          candidates: [
            { content: { parts: [{ text: 'Hello' }] } },
          ],
        }),
        ctx,
        null,
      ),
    );
    expect(events.some((e) => e.type === 'delta' && e.content === 'Hello')).toBe(true);
  });

  it('chunk 2: groundingMetadata.groundingChunks emit citations event', () => {
    const ctx = createStreamContext();
    const events = toArr(
      geminiGenerateStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          candidates: [
            {
              groundingMetadata: {
                groundingChunks: [
                  { web: { uri: 'https://example.com', title: 'Ex' } },
                  { web: { uri: 'https://wiki.org', title: 'Wiki' } },
                ],
              },
            },
          ],
        }),
        ctx,
        null,
      ),
    );
    const cit = events.find((e) => e.type === 'citations');
    expect(cit).toBeDefined();
    if (cit?.type === 'citations') {
      expect(cit.citations).toHaveLength(2);
      expect(cit.citations[0].url).toBe('https://example.com');
    }
    expect(ctx.citations).toHaveLength(2);
  });

  it('chunk 3: usageMetadata emit usage', () => {
    const ctx = createStreamContext();
    const events = toArr(
      geminiGenerateStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          usageMetadata: {
            promptTokenCount: 10,
            candidatesTokenCount: 20,
            totalTokenCount: 30,
          },
        }),
        ctx,
        null,
      ),
    );
    const usage = events.find((e) => e.type === 'usage');
    expect(usage).toBeDefined();
    if (usage?.type === 'usage') {
      expect(usage.usage.prompt_tokens).toBe(10);
      expect(usage.usage.completion_tokens).toBe(20);
    }
  });
});

describe('geminiGenerateStrategy content blocking and in-stream errors', () => {
  it('turns finishReason=SAFETY into an error event and discards the parts of the same chunk', () => {
    const ctx = createStreamContext();
    const events = toArr(
      geminiGenerateStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          candidates: [
            {
              content: { parts: [{ text: 'partial output' }] },
              finishReason: 'SAFETY',
            },
          ],
          usageMetadata: { promptTokenCount: 5, candidatesTokenCount: 1 },
        }),
        ctx,
        null,
      ),
    );
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe('error');
    if (events[0].type === 'error') {
      expect(events[0].error).toContain('SAFETY');
      expect(events[0].errorKind).toBe('upstream');
    }
  });

  it('turns promptFeedback.blockReason into an error event', () => {
    const ctx = createStreamContext();
    const events = toArr(
      geminiGenerateStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          promptFeedback: { blockReason: 'PROHIBITED_CONTENT' },
        }),
        ctx,
        null,
      ),
    );
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe('error');
    if (events[0].type === 'error') {
      expect(events[0].error).toContain('PROHIBITED_CONTENT');
      expect(events[0].errorKind).toBe('upstream');
    }
  });

  it('leaves a normal finishReason=STOP alone and still emits the delta', () => {
    const ctx = createStreamContext();
    const events = toArr(
      geminiGenerateStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          candidates: [
            {
              content: { parts: [{ text: 'final text' }] },
              finishReason: 'STOP',
            },
          ],
        }),
        ctx,
        null,
      ),
    );
    expect(events.some((e) => e.type === 'error')).toBe(false);
    expect(events.some((e) => e.type === 'delta' && e.content === 'final text')).toBe(true);
  });

  it('leaves a normal finishReason=MAX_TOKENS truncation alone', () => {
    const ctx = createStreamContext();
    const events = toArr(
      geminiGenerateStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          candidates: [
            {
              content: { parts: [{ text: 'long output' }] },
              finishReason: 'MAX_TOKENS',
            },
          ],
        }),
        ctx,
        null,
      ),
    );
    expect(events.some((e) => e.type === 'error')).toBe(false);
    expect(events.some((e) => e.type === 'delta' && e.content === 'long output')).toBe(true);
  });

  it('turns a top-level error chunk mid-stream into an error event and passes the message through', () => {
    const ctx = createStreamContext();
    const events = toArr(
      geminiGenerateStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          error: { code: 500, message: 'Internal error encountered.', status: 'INTERNAL' },
        }),
        ctx,
        null,
      ),
    );
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe('error');
    if (events[0].type === 'error') {
      expect(events[0].error).toBe('Internal error encountered.');
      expect(events[0].errorKind).toBe('upstream');
    }
  });

  it('treats RECITATION/BLOCKLIST/SPII as blocked and null/undefined as not blocked', () => {
    for (const reason of ['RECITATION', 'BLOCKLIST', 'SPII']) {
      const event = detectGeminiBlockEvent({ candidates: [{ finishReason: reason }] });
      expect(event?.type).toBe('error');
      if (event?.type === 'error') {
        expect(event.error).toContain(reason);
      }
    }
    expect(detectGeminiBlockEvent({ candidates: [{ finishReason: null }] })).toBeNull();
    expect(detectGeminiBlockEvent({ candidates: [{}] })).toBeNull();
    expect(detectGeminiBlockEvent({})).toBeNull();
  });
});
