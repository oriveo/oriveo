/**
 * Unit tests for chunk fixture parsing in the openai_chat strategy.
 *
 * Covers default annotation parsing, the Zhipu path override, and the override fallback.
 */

import { describe, expect, it } from 'vitest';
import { openAIChatStrategy } from '../strategies/openai-chat';
import { createStreamContext } from '../transport-strategy';

function toArr(result: ReturnType<typeof openAIChatStrategy.parseStreamChunk>) {
  if (result == null) return [];
  return Array.isArray(result) ? result : [result];
}

describe('openAIChatStrategy.buildRequestBody', () => {
  it('injects stream_options.include_usage', () => {
    const body = openAIChatStrategy.buildRequestBody({
      modelID: 'gpt-4o',
      messages: [{ role: 'user', content: 'hi' }],
    });
    expect(body.stream).toBe(true);
    expect((body.stream_options as { include_usage: boolean }).include_usage).toBe(true);
  });

  // The local level mapping is gated on `input.providerKind === 'relay'`: reasoning for an official
  // provider is always injected from params[level] of the metadata profile, and the local mapping is
  // a Relay-only exception because a user-defined endpoint has no catalog to consult. The earlier assertion passed no providerKind and used the official model id `o1`, asserting exactly the behavior that rule forbids.
  it('relay maps reasoning=deep to reasoning_effort=high (the local mapping is Relay only)', () => {
    const body = openAIChatStrategy.buildRequestBody({
      modelID: 'gpt-4o',
      providerKind: 'relay',
      messages: [{ role: 'user', content: 'hi' }],
      options: { reasoning: 'deep' },
    });
    expect(body.reasoning_effort).toBe('high');
  });

  it('an official provider does no local level mapping', () => {
    const body = openAIChatStrategy.buildRequestBody({
      modelID: 'o1',
      providerKind: 'openAI',
      messages: [{ role: 'user', content: 'hi' }],
      options: { reasoning: 'deep' },
    });
    expect(body.reasoning_effort).toBeUndefined();
  });

  it('mergeParams deep merges', () => {
    const body = openAIChatStrategy.buildRequestBody({
      modelID: 'gpt-4o',
      messages: [{ role: 'user', content: 'hi' }],
      mergeParams: { tools: [{ type: 'web_search_preview' }] },
    });
    expect(Array.isArray(body.tools)).toBe(true);
  });
});

describe('openAIChatStrategy.parseStreamChunk citations', () => {
  it('chunk 1: the default inline annotations url_citation shape', () => {
    const ctx = createStreamContext();
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          choices: [
            {
              delta: {
                content: 'partial',
                annotations: [
                  {
                    type: 'url_citation',
                    url_citation: { url: 'https://openai.com', title: 'OpenAI' },
                  },
                ],
              },
            },
          ],
        }),
        ctx,
        null,
      ),
    );
    expect(events.some((e) => e.type === 'delta')).toBe(true);
    const cit = events.find((e) => e.type === 'citations');
    expect(cit).toBeDefined();
    if (cit?.type === 'citations') {
      expect(cit.citations[0].url).toBe('https://openai.com');
    }
  });

  it('chunk 2: streamShape.citationsArrayPath override (Zhipu link field)', () => {
    const ctx = createStreamContext();
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          choices: [
            {
              delta: {
                tool_calls: [
                  {
                    web_search: {
                      search_result: [{ link: 'https://zhipu.cn', media: 'Zhipu' }],
                    },
                  },
                ],
              },
            },
          ],
        }),
        ctx,
        {
          citationsArrayPath: 'choices.0.delta.tool_calls.0.web_search.search_result',
          citationUrlField: 'link',
          citationTitleField: 'media',
        },
      ),
    );
    const cit = events.find((e) => e.type === 'citations');
    expect(cit).toBeDefined();
    if (cit?.type === 'citations') {
      expect(cit.citations[0].url).toBe('https://zhipu.cn');
      expect(cit.citations[0].title).toBe('Zhipu');
    }
  });

  it('chunk 3: an override path that exists but is empty in this chunk falls back to the default annotations', () => {
    const ctx = createStreamContext();
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          choices: [
            {
              delta: {
                annotations: [
                  {
                    type: 'url_citation',
                    url_citation: { url: 'https://fallback.com' },
                  },
                ],
              },
            },
          ],
        }),
        ctx,
        {
          citationsArrayPath: 'choices.0.delta.tool_calls.0.web_search.search_result',
        },
      ),
    );
    const cit = events.find((e) => e.type === 'citations');
    // An empty override path must not block the annotations path
    expect(cit).toBeDefined();
    if (cit?.type === 'citations') {
      expect(cit.citations[0].url).toBe('https://fallback.com');
    }
  });

  it('chunk 4: usage chunk', () => {
    const ctx = createStreamContext();
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          usage: { prompt_tokens: 10, completion_tokens: 20, total_tokens: 30 },
          choices: [],
        }),
        ctx,
        null,
      ),
    );
    const usage = events.find((e) => e.type === 'usage');
    expect(usage).toBeDefined();
    if (usage?.type === 'usage') {
      expect(usage.usage.prompt_tokens).toBe(10);
    }
  });
});

describe('openAIChatStrategy.parseStreamChunk MiniMax think tags', () => {
  it('turns a single think section in MiniMax content into reasoning and keeps only the text outside the tag in the body', () => {
    const ctx = createStreamContext('miniMax');
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({ choices: [{ delta: { content: 'A<think>reason</think>B' } }] }),
        ctx,
        null,
      ),
    );

    expect(events).toEqual([
      { type: 'delta', content: 'A' },
      { type: 'reasoning', content: 'reason' },
      { type: 'delta', content: 'B' },
    ]);
  });

  it('supports multiple MiniMax think sections and merges them into the reasoning event stream', () => {
    const ctx = createStreamContext('miniMax');
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({ choices: [{ delta: { content: '<think>a</think>x<think>b</think>y' } }] }),
        ctx,
        null,
      ),
    );

    expect(events).toEqual([
      { type: 'reasoning', content: 'a' },
      { type: 'delta', content: 'x' },
      { type: 'reasoning', content: 'b' },
      { type: 'delta', content: 'y' },
    ]);
  });

  it('supports a MiniMax think tag split across chunks', () => {
    const ctx = createStreamContext('miniMax');
    const first = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({ choices: [{ delta: { content: '<th' } }] }),
        ctx,
        null,
      ),
    );
    const second = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({ choices: [{ delta: { content: 'ink>a</thi' } }] }),
        ctx,
        null,
      ),
    );
    const third = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({ choices: [{ delta: { content: 'nk>b' } }] }),
        ctx,
        null,
      ),
    );

    expect(first).toEqual([]);
    expect(second).toEqual([{ type: 'reasoning', content: 'a' }]);
    expect(third).toEqual([{ type: 'delta', content: 'b' }]);
  });

  it('keeps an unclosed MiniMax think as reasoning when the stream ends', () => {
    const ctx = createStreamContext('miniMax');
    const first = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({ choices: [{ delta: { content: 'A<think>unfinished' } }] }),
        ctx,
        null,
      ),
    );
    const flushed = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({ choices: [{ delta: {} }] }),
        ctx,
        null,
      ),
    );

    expect(first).toEqual([
      { type: 'delta', content: 'A' },
      { type: 'reasoning', content: 'unfinished' },
    ]);
    expect(flushed).toEqual([]);
  });

  it('does not parse think tags in content for a non-MiniMax provider', () => {
    const ctx = createStreamContext('relay');
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({ choices: [{ delta: { content: 'A<think>literal</think>B' } }] }),
        ctx,
        null,
      ),
    );

    expect(events).toEqual([{ type: 'delta', content: 'A<think>literal</think>B' }]);
  });

  it('a content block array does not fall into the MiniMax think tag parsing path', () => {
    const ctx = createStreamContext('miniMax');
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          choices: [{ delta: { content: [{ type: 'text', text: '<think>literal</think>' }] } }],
        }),
        ctx,
        null,
      ),
    );
    // Block arrays go through the shared content-block-parser, and text passes straight through as a delta
    expect(events).toEqual([{ type: 'delta', content: '<think>literal</think>' }]);
  });

  it('a MiniMax think tag inside a code fence stays part of the body', () => {
    const ctx = createStreamContext('miniMax');
    const content = '```xml\n<think>literal</think>\n```\nOK';
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({ choices: [{ delta: { content } }] }),
        ctx,
        null,
      ),
    );

    expect(events).toEqual([{ type: 'delta', content }]);
  });
});

describe('openAIChatStrategy.parseStreamChunk content block arrays (Mistral Magistral thinking protocol, observed against the live endpoint 2026-07-21)', () => {
  it('a role frame with empty string content produces no event', () => {
    const ctx = createStreamContext('mistral');
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({ choices: [{ delta: { role: 'assistant', content: '' } }] }),
        ctx,
        null,
      ),
    );
    expect(events).toEqual([]);
  });

  it('a thinking block emits reasoning increments token by token', () => {
    const ctx = createStreamContext('mistral');
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        // The observed frames carry a non-standard "p" field that has to be ignored
        JSON.stringify({
          p: 'abcdefg',
          choices: [
            {
              delta: {
                content: [{ type: 'thinking', thinking: [{ type: 'text', text: ' token' }] }],
              },
            },
          ],
        }),
        ctx,
        null,
      ),
    );
    expect(events).toEqual([{ type: 'reasoning', content: ' token' }]);
  });

  it('the thinking close marker (an empty thinking array) produces no event', () => {
    const ctx = createStreamContext('mistral');
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({ choices: [{ delta: { content: [{ type: 'thinking', thinking: [] }] } }] }),
        ctx,
        null,
      ),
    );
    expect(events).toEqual([]);
  });

  it('body text falling back to a plain string delta after thinking produces a delta event', () => {
    const ctx = createStreamContext('mistral');
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({ choices: [{ delta: { content: ' ' } }] }),
        ctx,
        null,
      ),
    );
    expect(events).toEqual([{ type: 'delta', content: ' ' }]);
  });

  it('a finish chunk with usage puts prompt_tokens_details.cached_tokens into the breakdown', () => {
    const ctx = createStreamContext('mistral');
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          choices: [{ delta: { content: '' }, finish_reason: 'stop' }],
          usage: {
            prompt_tokens: 100,
            completion_tokens: 40,
            total_tokens: 140,
            prompt_tokens_details: { cached_tokens: 25 },
          },
        }),
        ctx,
        null,
      ),
    );
    const usage = events.find((e) => e.type === 'usage');
    expect(usage).toBeDefined();
    if (usage?.type === 'usage') {
      expect(usage.usage.prompt_tokens).toBe(100);
      expect(usage.usage.breakdown).toMatchObject({
        promptTokens: 75,
        cachedInputTokens: 25,
        completionTokens: 40,
      });
    }
  });

  it('block array parsing is provider agnostic: a relay pointing at the same protocol endpoint also receives thinking', () => {
    const ctx = createStreamContext('relay');
    const events = toArr(
      openAIChatStrategy.parseStreamChunk(
        null,
        JSON.stringify({
          choices: [
            {
              delta: {
                content: [
                  { type: 'thinking', thinking: [{ type: 'text', text: 'r' }] },
                  { type: 'text', text: 'body' },
                ],
              },
            },
          ],
        }),
        ctx,
        null,
      ),
    );
    expect(events).toEqual([
      { type: 'reasoning', content: 'r' },
      { type: 'delta', content: 'body' },
    ]);
  });
});
