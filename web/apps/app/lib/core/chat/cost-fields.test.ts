import { describe, expect, it } from 'vitest';
import type { AIModel } from '@oriveo/shared';
import { parseUsageGrok } from '@oriveo/core/providers/transport/usage-parsers';
import { deriveCostFields, mergeMessageUsageFields } from './cost-fields';

/**
 * Relay models are not in the catalog (resolveCatalogModel('relay') never finds an official
 * entry), so the only prices are the local ones enriched from the user's own catalog: $1/M input
 * and $2/M output, expressed per token.
 */
const RELAY_MODEL = {
  id: 'relay-model',
  name: 'Relay Model',
  promptPrice: 0.000_001,
  completionPrice: 0.000_002,
} as unknown as AIModel;

describe('cost fallback for a relay with no metadata pricing', () => {
  // Contract: the fallback must bucket the same way, and cache prices reuse the same fallback
  // ratios as the main path (read x0.5, 5m write x1.25, 1h write x2.0), so both paths agree.
  it('charges a cache read at the x0.5 discount rather than full price on the total input', () => {
    const fields = deriveCostFields({
      prompt_tokens: 10_000,
      completion_tokens: 100,
      breakdown: {
        promptTokens: 1000,
        cachedInputTokens: 9000,
        cacheCreation5mTokens: 0,
        cacheCreation1hTokens: 0,
        completionTokens: 100,
        reasoningTokens: 0,
        cacheReadObserved: true,
      },
    }, RELAY_MODEL, 'relay');

    // Bucketed: 1000x1e-6 + 9000x(1e-6x0.5) + 100x2e-6 = 0.001 + 0.0045 + 0.0002
    expect(fields.cost).toBeCloseTo(0.0057, 10);
    expect(fields.costSource).toBe('localEstimate');

    // The wrong algorithm (charging the full price on the whole input including cache) gives
    // 10000x1e-6 + 100x2e-6 = 0.0102, nearly double for a request that is almost all cache hits.
    // This assertion exists to keep it from being changed back.
    const fullPriceOnTotalInput = 10_000 * 0.000_001 + 100 * 0.000_002;
    expect(fullPriceOnTotalInput).toBeCloseTo(0.0102, 10);
    expect(fields.cost).toBeLessThan(fullPriceOnTotalInput);
  });

  it('charges 5m and 1h writes at x1.25 and x2.0 respectively', () => {
    const fields = deriveCostFields({
      prompt_tokens: 3000,
      completion_tokens: 0,
      breakdown: {
        promptTokens: 1000,
        cachedInputTokens: 0,
        cacheCreation5mTokens: 1000,
        cacheCreation1hTokens: 1000,
        completionTokens: 0,
        reasoningTokens: 0,
        cacheWriteObserved: true,
      },
    }, RELAY_MODEL, 'relay');

    // 1000x1e-6 + 1000x1.25e-6 + 1000x2e-6 = 0.00425
    expect(fields.cost).toBeCloseTo(0.00425, 10);
    expect(fields.costSource).toBe('localEstimate');
  });

  it('reports unknown honestly when the model has no local price either, instead of inventing a 0', () => {
    const fields = deriveCostFields({
      prompt_tokens: 1000,
      completion_tokens: 100,
      breakdown: {
        promptTokens: 1000,
        cachedInputTokens: 0,
        cacheCreation5mTokens: 0,
        cacheCreation1hTokens: 0,
        completionTokens: 100,
        reasoningTokens: 0,
      },
    }, { id: 'relay-nopricing', name: 'No Pricing' } as unknown as AIModel, 'relay');

    expect(fields.costSource).toBe('unknown');
    expect(fields.cost).toBe(0);
  });
});

describe('message token usage fields', () => {
  it('derives inclusive input while preserving cache read/write as subsets', () => {
    const fields = deriveCostFields({
      prompt_tokens: 210,
      completion_tokens: 30,
      total_tokens: 240,
      breakdown: {
        promptTokens: 120,
        cachedInputTokens: 80,
        cacheCreation5mTokens: 10,
        cacheCreation1hTokens: 0,
        completionTokens: 30,
        reasoningTokens: 0,
      },
    }, undefined, 'anthropic');

    expect(fields).toMatchObject({
      inputTokens: 210,
      outputTokens: 30,
      cachedInputTokens: 80,
      cacheCreationInputTokens: 10,
    });
  });

  it('preserves defined zero and sums continuation usage', () => {
    expect(mergeMessageUsageFields(
      { inputTokens: 100, outputTokens: 20, cachedInputTokens: 0 },
      { inputTokens: 50, outputTokens: 10, cachedInputTokens: 25, cacheCreationInputTokens: 0 },
    )).toEqual({
      inputTokens: 150,
      outputTokens: 30,
      cachedInputTokens: 25,
      cacheCreationInputTokens: 0,
    });
  });

  it('does not turn normalized fallback zero into a claimed cache measurement', () => {
    expect(deriveCostFields({
      prompt_tokens: 12,
      completion_tokens: 4,
      breakdown: {
        promptTokens: 12,
        cachedInputTokens: 0,
        cacheCreation5mTokens: 0,
        cacheCreation1hTokens: 0,
        completionTokens: 4,
        reasoningTokens: 0,
      },
    }, undefined, 'openAI')).toMatchObject({
      inputTokens: 12,
      outputTokens: 4,
    });
    expect(deriveCostFields({
      prompt_tokens: 12,
      completion_tokens: 4,
      breakdown: {
        promptTokens: 12,
        cachedInputTokens: 0,
        cacheCreation5mTokens: 0,
        cacheCreation1hTokens: 0,
        completionTokens: 4,
        reasoningTokens: 0,
        cacheReadObserved: true,
      },
    }, undefined, 'deepseek')).toMatchObject({
      cachedInputTokens: 0,
    });
    expect(deriveCostFields({
      messageUsage: {
        inputTokens: 12,
        outputTokens: 4,
        cachedInputTokens: 0,
        cacheCreationInputTokens: 0,
      },
    }, undefined, 'openAI')).toMatchObject({
      cachedInputTokens: 0,
      cacheCreationInputTokens: 0,
    });
  });
});

describe('Grok subscription mode shows no cost', () => {
  // Producer-side evidence: the breakdown comes from the production Grok usage parser fed a
  // realistically shaped upstream usage object, not from a hand-built test fixture.
  // `cost_in_usd_ticks` is the field subscription mode most easily misses: calcCost prefers
  // `upstreamCost`, so without short-circuiting before the price lookup it would report an amount
  // the user never spent.
  const grokUsage = parseUsageGrok({
    prompt_tokens: 1200,
    completion_tokens: 340,
    prompt_tokens_details: { cached_tokens: 200 },
    completion_tokens_details: { reasoning_tokens: 40 },
    cost_in_usd_ticks: 123_456_789,
  });

  const GROK_MODEL = {
    id: 'grok-4.6',
    name: 'grok-4.6',
    promptPrice: 0.000_003,
    completionPrice: 0.000_015,
  } as unknown as AIModel;

  it('confirms the production parser really produces upstreamCost, without which the next assertion tests nothing', () => {
    expect(grokUsage.upstreamCost).toBeGreaterThan(0);
  });

  it('reports cost 0 with source subscription when authMode=subscription, while token counts stay', () => {
    const fields = deriveCostFields(
      { prompt_tokens: 1200, completion_tokens: 340, breakdown: grokUsage },
      GROK_MODEL,
      'grok',
      'subscription',
    );
    expect(fields.cost).toBe(0);
    expect(fields.costSource).toBe('subscription');
    expect(fields.inputTokens).toBe(1200);
    expect(fields.outputTokens).toBe(340);
  });

  it('still prices the same usage normally in API key mode, so the short circuit applies only to subscriptions', () => {
    const fields = deriveCostFields(
      { prompt_tokens: 1200, completion_tokens: 340, breakdown: grokUsage },
      GROK_MODEL,
      'grok',
    );
    expect(fields.cost).toBeGreaterThan(0);
    expect(fields.costSource).not.toBe('subscription');
  });
});
