/**
 * Cost accounting: the calcCost formula plus the per-provider parseUsage counter-examples.
 */

import { describe, expect, it } from 'vitest';
import { calcCost } from '../cost';
import { emptyUsageBreakdown } from '../usage-breakdown';
import type { ModelPricing } from '../../metadata/metadata-client';
import {
  parseUsageAnthropic,
  parseUsageDeepSeek,
  parseUsageGemini,
  parseUsageGrok,
  parseUsageMoonshot,
  parseUsageOpenAI,
  parseUsageOpenRouter,
  parseUsageQwen,
} from '../../providers/transport/usage-parsers';

/* ── Formula ──────────────────────────────────────────────────────────── */

describe('calcCost - an upstream figure wins', () => {
  it('returns source=upstream directly when breakdown.upstreamCost is present', () => {
    const result = calcCost(
      { ...emptyUsageBreakdown(), upstreamCost: 0.0042, promptTokens: 999 },
      { promptPerMToken: 5, completionPerMToken: 15 },
    );
    expect(result.cost).toBe(0.0042);
    expect(result.source).toBe('upstream');
  });
});

describe('calcCost - missing pricing', () => {
  it('source=unknown when pricing is null', () => {
    const result = calcCost(
      { ...emptyUsageBreakdown(), promptTokens: 100 },
      null,
    );
    expect(result.cost).toBe(0);
    expect(result.source).toBe('unknown');
  });

  it('source=unknown when both promptPerMToken and completionPerMToken are null', () => {
    const result = calcCost(
      { ...emptyUsageBreakdown(), promptTokens: 100 },
      { promptPerMToken: null, completionPerMToken: null },
    );
    expect(result.source).toBe('unknown');
  });
});

describe('calcCost - plain local estimate for OpenAI', () => {
  it('prices cached_tokens at the cachedInput rate instead of billing them twice', () => {
    // input=$5/M, output=$15/M, cached=$0.5/M GPT-5.5  
    const pricing: ModelPricing = {
      promptPerMToken: 5,
      completionPerMToken: 15,
      cachedInputPerMToken: 0.5,
    };
    // 1000 token cached + 200 token miss + 500 output
    const result = calcCost(
      {
        ...emptyUsageBreakdown(),
        promptTokens: 200,
        cachedInputTokens: 1000,
        completionTokens: 500,
      },
      pricing,
    );
    // input: 200 × 5e-6 = 0.001; cached: 1000 × 0.5e-6 = 0.0005; output: 500 × 15e-6 = 0.0075
    expect(result.cost).toBeCloseTo(0.001 + 0.0005 + 0.0075, 8);
    expect(result.source).toBe('localEstimate');
  });

  it('falls back to input x 0.5 when cachedInput is missing', () => {
    const pricing: ModelPricing = { promptPerMToken: 5, completionPerMToken: 15 };
    const result = calcCost(
      {
        ...emptyUsageBreakdown(),
        promptTokens: 0,
        cachedInputTokens: 1000,
        completionTokens: 0,
      },
      pricing,
    );
    // 1000 × (5/1e6 × 0.5) = 0.0025
    expect(result.cost).toBeCloseTo(0.0025, 8);
  });
});

describe('calcCost - Anthropic 5m and 1h mixed', () => {
  it('prices them at x1.25 and x2.0 respectively', () => {
    // Anthropic Haiku pricing: input=$1/M, output=$5/M, cached=$0.1/M, 5m=$1.25/M, 1h=$2/M
    const pricing: ModelPricing = {
      promptPerMToken: 1,
      completionPerMToken: 5,
      cachedInputPerMToken: 0.1,
      cacheWrite5mPerMToken: 1.25,
      cacheWrite1hPerMToken: 2.0,
    };
    const result = calcCost(
      {
        ...emptyUsageBreakdown(),
        promptTokens: 100,
        cachedInputTokens: 1000,
        cacheCreation5mTokens: 400,
        cacheCreation1hTokens: 200,
        completionTokens: 50,
      },
      pricing,
    );
    // 100×1e-6 + 1000×0.1e-6 + 400×1.25e-6 + 200×2e-6 + 50×5e-6
    const expected = 0.0001 + 0.0001 + 0.0005 + 0.0004 + 0.00025;
    expect(result.cost).toBeCloseTo(expected, 8);
  });

  it('falls back to input x 1.25 and x 2.0 when cacheWrite5m/1h are missing', () => {
    const pricing: ModelPricing = {
      promptPerMToken: 1,
      completionPerMToken: 5,
    };
    const result = calcCost(
      {
        ...emptyUsageBreakdown(),
        cacheCreation5mTokens: 100,
        cacheCreation1hTokens: 100,
      },
      pricing,
    );
    // 100 × (1e-6 × 1.25) + 100 × (1e-6 × 2.0)
    expect(result.cost).toBeCloseTo(0.000125 + 0.0002, 8);
  });

  it('the older cacheCreationInputPerMToken field acts as the 5m fallback', () => {
    const pricing: ModelPricing = {
      promptPerMToken: 1,
      completionPerMToken: 5,
      cacheCreationInputPerMToken: 1.0, // older metadata only exposed this single field
    };
    const result = calcCost(
      { ...emptyUsageBreakdown(), cacheCreation5mTokens: 1000 },
      pricing,
    );
    // 1000 x 1e-6 = 0.001, not the x1.25 fallback
    expect(result.cost).toBeCloseTo(0.001, 8);
  });
});

/* ── Per-provider parseUsage counter-examples ─────────────────────────── */

describe('parseUsageGrok - unit conversion (1e10, not 1e8)', () => {
  it('37756000 ticks → 0.0037756 USD', () => {
    const breakdown = parseUsageGrok({
      prompt_tokens: 50,
      completion_tokens: 100,
      cost_in_usd_ticks: 37756000,
    });
    expect(breakdown.upstreamCost).toBeCloseTo(0.0037756, 9);
  });

  it('28093500 ticks -> 0.002809 USD (measured against grok-4.3)', () => {
    const breakdown = parseUsageGrok({
      prompt_tokens: 100,
      completion_tokens: 50,
      cost_in_usd_ticks: 28093500,
    });
    expect(breakdown.upstreamCost).toBeCloseTo(0.00280935, 8);
    // A 100x overestimate would give 0.28, which must never match
    expect(breakdown.upstreamCost).toBeLessThan(0.1);
  });

  it('upstreamCost is undefined when cost_in_usd_ticks is missing, so the local estimate is used', () => {
    const breakdown = parseUsageGrok({ prompt_tokens: 50, completion_tokens: 100 });
    expect(breakdown.upstreamCost).toBeUndefined();
  });

  it('cached_tokens is subtracted from prompt_tokens', () => {
    const breakdown = parseUsageGrok({
      prompt_tokens: 1000,
      completion_tokens: 50,
      prompt_tokens_details: { cached_tokens: 200 },
    });
    expect(breakdown.promptTokens).toBe(800);
    expect(breakdown.cachedInputTokens).toBe(200);
  });
});

describe('parseUsageOpenAI - cached_tokens are not billed twice', () => {
  it('promptTokens = prompt_tokens - cached_tokens', () => {
    const breakdown = parseUsageOpenAI({
      prompt_tokens: 1536,
      completion_tokens: 200,
      prompt_tokens_details: { cached_tokens: 1024 },
      completion_tokens_details: { reasoning_tokens: 50 },
    });
    expect(breakdown.promptTokens).toBe(512);
    expect(breakdown.cachedInputTokens).toBe(1024);
    expect(breakdown.reasoningTokens).toBe(50);
    expect(breakdown.completionTokens).toBe(200);
  });

  it('cached=0 when prompt_tokens_details is missing', () => {
    const breakdown = parseUsageOpenAI({ prompt_tokens: 100, completion_tokens: 50 });
    expect(breakdown.cachedInputTokens).toBe(0);
    expect(breakdown.promptTokens).toBe(100);
  });
});

describe('parseUsageAnthropic - splitting the nested 5m and 1h object', () => {
  it('reads the nested cache_creation fields', () => {
    const breakdown = parseUsageAnthropic({
      input_tokens: 100,
      cache_read_input_tokens: 800,
      cache_creation_input_tokens: 248, // equal to the sum of the nested fields
      cache_creation: {
        ephemeral_5m_input_tokens: 148,
        ephemeral_1h_input_tokens: 100,
      },
      output_tokens: 200,
    });
    expect(breakdown.promptTokens).toBe(100);
    expect(breakdown.cachedInputTokens).toBe(800);
    expect(breakdown.cacheCreation5mTokens).toBe(148);
    expect(breakdown.cacheCreation1hTokens).toBe(100);
    expect(breakdown.completionTokens).toBe(200);
  });

  it('a response without the nested object falls back to the outer cache_creation_input_tokens as 5m', () => {
    const breakdown = parseUsageAnthropic({
      input_tokens: 100,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 200,
      output_tokens: 50,
    });
    expect(breakdown.cacheCreation5mTokens).toBe(200);
    expect(breakdown.cacheCreation1hTokens).toBe(0);
  });
});

describe('parseUsageGemini - total = prompt + candidates + thoughts', () => {
  it('completionTokens = candidates + thoughts, as measured on gemini-2.5-flash', () => {
    const breakdown = parseUsageGemini({
      promptTokenCount: 1695,
      candidatesTokenCount: 31,
      thoughtsTokenCount: 78,
      totalTokenCount: 1804,
    });
    expect(breakdown.promptTokens).toBe(1695);
    expect(breakdown.completionTokens).toBe(31 + 78);
    expect(breakdown.reasoningTokens).toBe(78);
    // Identity: prompt + completion = total
    expect(breakdown.promptTokens + breakdown.completionTokens).toBe(1804);
  });

  it('cachedContentTokenCount is subtracted from promptTokens', () => {
    const breakdown = parseUsageGemini({
      promptTokenCount: 2000,
      cachedContentTokenCount: 1007,
      candidatesTokenCount: 50,
      thoughtsTokenCount: 0,
    });
    expect(breakdown.promptTokens).toBe(2000 - 1007);
    expect(breakdown.cachedInputTokens).toBe(1007);
  });

  it('completionTokens is just candidates when thoughtsTokenCount is missing', () => {
    const breakdown = parseUsageGemini({
      promptTokenCount: 100,
      candidatesTokenCount: 50,
    });
    expect(breakdown.completionTokens).toBe(50);
    expect(breakdown.reasoningTokens).toBe(0);
  });
});

describe('parseUsageDeepSeek - hit + miss = prompt', () => {
  it('promptTokens = prompt_cache_miss_tokens', () => {
    const breakdown = parseUsageDeepSeek({
      prompt_tokens: 1751,
      prompt_cache_hit_tokens: 1664,
      prompt_cache_miss_tokens: 87,
      completion_tokens: 50,
      completion_tokens_details: { reasoning_tokens: 30 },
    });
    expect(breakdown.promptTokens).toBe(87);
    expect(breakdown.cachedInputTokens).toBe(1664);
    expect(breakdown.reasoningTokens).toBe(30);
    // Identity check
    expect(breakdown.promptTokens + breakdown.cachedInputTokens).toBe(1751);
  });

  it('falls back to prompt_tokens when the cache miss field is missing', () => {
    const breakdown = parseUsageDeepSeek({
      prompt_tokens: 500,
      completion_tokens: 100,
    });
    expect(breakdown.promptTokens).toBe(500);
    expect(breakdown.cachedInputTokens).toBe(0);
  });
});

describe('parseUsageOpenRouter - upstreamCost is returned by default', () => {
  it('passes usage.cost through as upstreamCost', () => {
    const breakdown = parseUsageOpenRouter({
      prompt_tokens: 100,
      completion_tokens: 50,
      cost: 0.00026985,
      prompt_tokens_details: { cached_tokens: 20, cache_write_tokens: 80 },
    });
    expect(breakdown.upstreamCost).toBe(0.00026985);
    expect(breakdown.cachedInputTokens).toBe(20);
    expect(breakdown.cacheCreation1hTokens).toBe(80);
  });
});

describe('parseUsageMoonshot - cached_tokens at the top level of usage', () => {
  it('reads the top-level cached_tokens rather than prompt_tokens_details', () => {
    const breakdown = parseUsageMoonshot({
      prompt_tokens: 1700,
      completion_tokens: 100,
      cached_tokens: 1658,
    });
    expect(breakdown.cachedInputTokens).toBe(1658);
    expect(breakdown.promptTokens).toBe(1700 - 1658);
  });

  it('counter-example: applying the OpenAI template and reading prompt_tokens_details gives 0', () => {
    const breakdown = parseUsageMoonshot({
      prompt_tokens: 100,
      completion_tokens: 50,
      // Moonshot does not report cache hits here, so reading this field yields nothing.
      prompt_tokens_details: { cached_tokens: 80 },
    });
    expect(breakdown.cachedInputTokens).toBe(0); // has to be 0
  });
});

describe('parseUsageQwen - two fallbacks', () => {
  it('Singapore region: prompt_tokens_details.cached_tokens', () => {
    const breakdown = parseUsageQwen({
      input_tokens: 1000,
      output_tokens: 100,
      prompt_tokens_details: { cached_tokens: 200 },
    });
    expect(breakdown.cachedInputTokens).toBe(200);
    expect(breakdown.promptTokens).toBe(800);
  });

  it('Beijing region qwen3-vl-plus: top-level cached_tokens', () => {
    const breakdown = parseUsageQwen({
      input_tokens: 1000,
      output_tokens: 100,
      cached_tokens: 200,
    });
    expect(breakdown.cachedInputTokens).toBe(200);
    expect(breakdown.promptTokens).toBe(800);
  });

  it('DashScope native naming: input_tokens / output_tokens', () => {
    const breakdown = parseUsageQwen({ input_tokens: 500, output_tokens: 200 });
    expect(breakdown.promptTokens).toBe(500);
    expect(breakdown.completionTokens).toBe(200);
  });
});
