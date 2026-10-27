import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  parseUsageAnthropic,
  parseUsageDeepSeek,
  parseUsageGemini,
  parseUsageGrok,
  parseUsageMoonshot,
  parseUsageOpenAI,
  parseUsageOpenAICompatible,
  parseUsageOpenRouter,
  parseUsageQwen,
  parseUsageTogether,
} from './usage-parsers';

/**
 * Field-path contract of the parser functions themselves: given a usage payload of a certain
 * shape, what do they compute.
 *
 * This file deliberately does not claim to cover all 15 providers. Which parser each provider
 * actually routes to is a routing question, pinned down in
 * `__tests__/usage-parser-routing.test.ts`, which feeds real wire payloads for the full
 * `PROVIDER_KINDS` set.
 *
 * A test whose name overstates its coverage is worse than no test, because it makes people
 * believe the ground is already covered.
 */
describe('UsageBreakdown parser field paths', () => {
  it('pins the cache-read field path per provider and keeps an explicit 0 distinct from a missing field', () => {
    const distinct = [
      // The OpenAI-compatible template (Groq / Together / Fireworks / MiniMax / Z.ai / Mistral /
      // SiliconFlow share this implementation; which provider routes where is the job of the
      // usage-parser-routing gate).
      ['OpenAICompatible', parseUsageOpenAICompatible({ prompt_tokens: 10, completion_tokens: 2, prompt_tokens_details: { cached_tokens: 0 } }), parseUsageOpenAICompatible({ prompt_tokens: 10 })],
      ['OpenAI', parseUsageOpenAI({ prompt_tokens: 10, prompt_tokens_details: { cached_tokens: 0 } }), parseUsageOpenAI({ prompt_tokens: 10 })],
      ['Anthropic', parseUsageAnthropic({ input_tokens: 10, cache_read_input_tokens: 0 }), parseUsageAnthropic({ input_tokens: 10 })],
      ['Gemini', parseUsageGemini({ promptTokenCount: 10, cachedContentTokenCount: 0 }), parseUsageGemini({ promptTokenCount: 10 })],
      ['DeepSeek', parseUsageDeepSeek({ prompt_tokens: 10, prompt_cache_hit_tokens: 0 }), parseUsageDeepSeek({ prompt_tokens: 10 })],
      ['OpenRouter', parseUsageOpenRouter({ prompt_tokens: 10, prompt_tokens_details: { cached_tokens: 0 } }), parseUsageOpenRouter({ prompt_tokens: 10 })],
      ['Grok', parseUsageGrok({ prompt_tokens: 10, prompt_tokens_details: { cached_tokens: 0 } }), parseUsageGrok({ prompt_tokens: 10 })],
      ['Qwen', parseUsageQwen({ input_tokens: 10, cached_tokens: 0 }), parseUsageQwen({ input_tokens: 10 })],
      ['Kimi', parseUsageMoonshot({ prompt_tokens: 10, cached_tokens: 0 }), parseUsageMoonshot({ prompt_tokens: 10 })],
    ] as const;
    for (const [provider, observed, missing] of distinct) {
      expect(observed.cacheReadObserved, provider).toBe(true);
      expect(observed.cachedInputTokens, provider).toBe(0);
      expect(missing.cacheReadObserved, provider).toBe(false);
    }
  });

  it('declares cache writes observable only when the upstream actually returns the write breakdown', () => {
    const anthropic = parseUsageAnthropic({
      input_tokens: 10,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
    });
    expect(anthropic.cacheWriteObserved).toBe(true);
    expect(anthropic.cacheCreation5mTokens).toBe(0);

    const openRouter = parseUsageOpenRouter({
      prompt_tokens: 10,
      prompt_tokens_details: { cached_tokens: 0, cache_write_tokens: 0 },
    });
    expect(openRouter.cacheWriteObserved).toBe(true);
    expect(openRouter.cacheCreation1hTokens).toBe(0);

    expect(parseUsageDeepSeek({ prompt_tokens: 10, prompt_cache_hit_tokens: 0 }).cacheWriteObserved)
      .not.toBe(true);
    expect(parseUsageAnthropic({ input_tokens: 10 }).cacheWriteObserved).toBe(false);
  });
});

/** Walk up from cwd to find a repo-root-relative path. */
function root(relative: string) { let current = process.cwd(); while (true) { const candidate = path.join(current, relative); if (existsSync(candidate)) return candidate; const next = path.dirname(current); if (next === current) throw new Error(relative); current = next; } }

interface TogetherUsageFixture {
  cases: Array<{ id: string; usage: Record<string, unknown>; expect: Record<string, number | boolean> }>;
}

describe('Together usage shapes (shared fixture)', () => {
  const fixture = JSON.parse(
    readFileSync(root('shared/test-fixtures/provider-usage/together-usage-shapes.v1.json'), 'utf8'),
  ) as TogetherUsageFixture;

  it('all 4 Together usage fixture cases pass', () => {
    expect(fixture.cases.map((c) => c.id)).toEqual([
      'reasoning-model-nested',
      'non-reasoning-flat-cached',
      'flat-cached-zero-is-observed',
      'no-cache-field',
    ]);
    fixture.cases.forEach((c) => {
      expect(parseUsageTogether(c.usage), c.id).toMatchObject(c.expect);
    });
  });
});
