import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it } from 'vitest';
import type { AIModel } from '@oriveo/shared';
import { parseUsageGrok } from '@oriveo/core/providers/transport/usage-parsers';
import { deriveCostFields, mergeMessageUsageFields, roundCostOf } from './cost-fields';
import {
  __resetMetadataClientForTest,
  __seedMetadataCacheForTest,
  initMetadata,
  resolveCatalogModel,
} from '../metadata/metadata-client';

// The pricing instant is passed explicitly: a fixed instant, never the wall clock.
const PRICED_AT = () => new Date('2026-10-19T12:00:00Z');

/**
 * Relay models match no official catalog entry (an empty metadata cache can never match one),
 * so the only prices are the local ones enriched from the user's own catalog: $1/M input
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
    }, RELAY_MODEL, { kind: 'relay' }, PRICED_AT, undefined);

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
    }, RELAY_MODEL, { kind: 'relay' }, PRICED_AT, undefined);

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
    }, { id: 'relay-nopricing', name: 'No Pricing' } as unknown as AIModel, { kind: 'relay' }, PRICED_AT, undefined);

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
    }, undefined, { kind: 'anthropic' }, PRICED_AT, undefined);

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
    }, undefined, { kind: 'openAI' }, PRICED_AT, undefined)).toMatchObject({
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
    }, undefined, { kind: 'deepseek' }, PRICED_AT, undefined)).toMatchObject({
      cachedInputTokens: 0,
    });
    expect(deriveCostFields({
      messageUsage: {
        inputTokens: 12,
        outputTokens: 4,
        cachedInputTokens: 0,
        cacheCreationInputTokens: 0,
      },
    }, undefined, { kind: 'openAI' }, PRICED_AT, undefined)).toMatchObject({
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
      { kind: 'grok', authMode: 'subscription' },
      PRICED_AT, undefined,
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
      { kind: 'grok' },
      PRICED_AT, undefined,
    );
    expect(fields.cost).toBeGreaterThan(0);
    expect(fields.costSource).not.toBe('subscription');
  });
});

describe('pricingV2 estimation', () => {
  const MODEL_ID = 'claude-v2-test';
  const CATALOG_MODEL = { id: MODEL_ID, name: MODEL_ID } as unknown as AIModel;
  // Legacy pricing: $3/M input, $15/M output; v2 carries a different price so the result shows which path was taken.
  const LEGACY_PRICING = '{"promptPerMToken":3,"completionPerMToken":15}';
  const V2_WITH_WINDOW = `{
    "currencyCode": "USD",
    "unit": "per_token",
    "base": { "inputPerMToken": 2, "outputPerMToken": 8 },
    "cache": { "readPerMToken": 0.5, "writes": [{ "ttl": "5m", "perMToken": 2.5 }, { "ttl": "1h", "perMToken": 4 }] },
    "timeWindows": [{ "timezone": "UTC", "start": "00:00", "end": "06:00", "multiplier": 0.5 }]
  }`;
  const BREAKDOWN = {
    promptTokens: 1000,
    cachedInputTokens: 2000,
    cacheCreation5mTokens: 300,
    cacheCreation1hTokens: 400,
    completionTokens: 500,
    reasoningTokens: 0,
    cacheReadObserved: true,
    cacheWriteObserved: true,
  };
  const NOON = () => new Date('2026-10-19T12:00:00Z');
  const OFF_PEAK = () => new Date('2026-10-19T03:00:00Z');

  // Real JSON text goes through the production decoder in metadata-client into ResolvedModelMetadata.
  async function seed(pricingV2Json: string | null, pricingStatus = 'priced') {
    const modelJson = `{
      "canonicalModelId": "${MODEL_ID}",
      "pricingUnit": "per_token",
      "pricingStatus": "${pricingStatus}",
      "capabilities": ["text"],
      "pricing": ${LEGACY_PRICING}${pricingV2Json === null ? '' : `,
      "pricingV2": ${pricingV2Json}`}
    }`;
    const data = JSON.parse(`{
      "version": 1,
      "contractVersion": 1,
      "updatedAt": "2026-10-19T00:00:00Z",
      "profiles": { "reasoning": {}, "webSearch": {}, "imageGen": {} },
      "providers": { "anthropic": { "models": { "${MODEL_ID}": ${modelJson} } } },
      "providerConfigs": []
    }`);
    await __seedMetadataCacheForTest({ data, timestamp: Date.now() });
    await initMetadata();
  }

  afterEach(() => {
    __resetMetadataClientForTest();
  });

  it('a decoded pricingV2 goes through deriveCostFields on the v2 path: base price + cache price', async () => {
    await seed(V2_WITH_WINDOW);
    expect(resolveCatalogModel(MODEL_ID, 'anthropic')?.pricingV2?.unit).toBe('per_token');
    const fields = deriveCostFields({ breakdown: BREAKDOWN }, CATALOG_MODEL, { kind: 'anthropic' }, NOON, undefined);
    // 1000×2 + 2000×0.5 + 300×2.5 + 400×4 + 500×8 = 9350 → /1e6
    expect(fields.cost).toBeCloseTo(0.00935, 12);
    expect(fields.costSource).toBe('localEstimate');
  });

  it('the time window applies according to the injected pricing instant', async () => {
    await seed(V2_WITH_WINDOW);
    const fields = deriveCostFields({ breakdown: BREAKDOWN }, CATALOG_MODEL, { kind: 'anthropic' }, OFF_PEAK, undefined);
    expect(fields.cost).toBeCloseTo(0.004675, 12);
    expect(fields.costSource).toBe('localEstimate');
  });

  it('actual upstream cost takes precedence over v2', async () => {
    await seed(V2_WITH_WINDOW);
    const fields = deriveCostFields(
      { breakdown: { ...BREAKDOWN, upstreamCost: 0.42 } }, CATALOG_MODEL, { kind: 'anthropic' }, NOON, undefined,
    );
    expect(fields.cost).toBe(0.42);
    expect(fields.costSource).toBe('upstream');
  });

  it('unavailable -> costSource unknown, neither the legacy price nor an invented 0 amount', async () => {
    await seed('{"currencyCode":"USD","unit":"per_token","base":{"inputPerMToken":2,"outputPerMToken":null}}');
    const fields = deriveCostFields({ breakdown: BREAKDOWN }, CATALOG_MODEL, { kind: 'anthropic' }, NOON, undefined);
    expect(fields.costSource).toBe('unknown');
  });

  it('legacy pricingStatus unknown: pricingV2 is not read and costSource is unknown', async () => {
    await seed(V2_WITH_WINDOW, 'unknown');
    expect(resolveCatalogModel(MODEL_ID, 'anthropic')?.pricingV2?.unit).toBe('per_token');
    const fields = deriveCostFields({ breakdown: BREAKDOWN }, CATALOG_MODEL, { kind: 'anthropic' }, NOON, undefined);
    expect(fields.costSource).toBe('unknown');
    expect(fields.cost).not.toBeCloseTo(0.00935, 6);
  });

  it('legacy pricingStatus free with v2 0/0: a true 0, estimated rather than unknown', async () => {
    await seed('{"currencyCode":"USD","unit":"per_token","base":{"inputPerMToken":0,"outputPerMToken":0}}', 'free');
    const fields = deriveCostFields({ breakdown: BREAKDOWN }, CATALOG_MODEL, { kind: 'anthropic' }, NOON, undefined);
    expect(fields.costSource).toBe('localEstimate');
    expect(fields.cost).toBe(0);
  });

  it('no pricingV2 / malformed shape / not per_token: the legacy result is unchanged', async () => {
    await seed(null);
    const legacy = deriveCostFields({ breakdown: BREAKDOWN }, CATALOG_MODEL, { kind: 'anthropic' }, NOON, undefined);
    expect(resolveCatalogModel(MODEL_ID, 'anthropic')?.pricingV2).toBeUndefined();
    expect(legacy.costSource).toBe('localEstimate');
    expect(legacy.cost).not.toBeCloseTo(0.00935, 6);

    for (const v2 of [
      '{"unit":"per_token","base":{"inputPerMToken":"2","outputPerMToken":8}}',
      '{"currencyCode":"USD","unit":"per_image","perUnit":0.04}',
    ]) {
      __resetMetadataClientForTest();
      await seed(v2);
      const fields = deriveCostFields({ breakdown: BREAKDOWN }, CATALOG_MODEL, { kind: 'anthropic' }, NOON, undefined);
      expect(fields).toEqual(legacy);
    }
  });
});

describe('tail estimation without a breakdown follows the selected price and currency (no USD fallback)', () => {
  const MODEL_ID = 'cny-fallback-test';
  const CATALOG_MODEL = { id: MODEL_ID, name: MODEL_ID } as unknown as AIModel;
  // No breakdown: only the two legacy token counts.
  const USAGE = { prompt_tokens: 1_000_000, completion_tokens: 500_000 };

  async function seed(model: Record<string, unknown>) {
    const data = {
      version: 1,
      contractVersion: 1,
      updatedAt: '2026-10-20T00:00:00Z',
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: {
        deepseek: {
          models: {
            [MODEL_ID]: { canonicalModelId: MODEL_ID, capabilities: ['text'], pricingStatus: 'priced', ...model },
          },
        },
      },
      providerConfigs: [],
    };
    await __seedMetadataCacheForTest({ data: JSON.parse(JSON.stringify(data)), timestamp: Date.now() });
    await initMetadata();
  }

  afterEach(() => {
    __resetMetadataClientForTest();
  });

  it('catalog price is CNY: the original-currency amount goes to nonUsdCost, the USD part is 0 + unknown, never treated as USD', async () => {
    await seed({
      currencyCode: 'CNY',
      pricingUnit: 'per_token',
      pricing: { promptPerMToken: 4, completionPerMToken: 16 },
    });
    const fields = deriveCostFields(USAGE, CATALOG_MODEL, { kind: 'deepseek' }, PRICED_AT, undefined);
    expect(fields.costSource).toBe('unknown');
    expect(fields.cost).toBe(0);
    expect(fields.nonUsdCost?.currencyCode).toBe('CNY');
    expect(fields.nonUsdCost?.costSource).toBe('localEstimate');
    expect(fields.nonUsdCost?.amount).toBeCloseTo(12, 10);
  });

  it('per-unit pricing without a unit count is recorded as unknown, not estimated as 1 unit', async () => {
    await seed({ currencyCode: 'cny', pricingUnit: 'per_image', pricing: { costPerUnit: 0.025 } });
    const fields = deriveCostFields(USAGE, CATALOG_MODEL, { kind: 'deepseek' }, PRICED_AT, undefined);
    expect(fields).toMatchObject({ cost: 0, costSource: 'unknown' });
    expect(fields.nonUsdCost).toBeUndefined();
  });

  it('CNY per-unit pricing is estimated by unit count, with the original-currency amount in nonUsdCost', async () => {
    await seed({
      currencyCode: 'CNY',
      pricingUnit: 'per_image',
      pricingV2: { currencyCode: 'CNY', unit: 'per_image', perUnit: 0.3 },
    });
    const fields = deriveCostFields(USAGE, CATALOG_MODEL, { kind: 'deepseek' }, PRICED_AT, 2);
    expect(fields.cost).toBe(0);
    expect(fields.costSource).toBe('unknown');
    expect(fields.nonUsdCost?.currencyCode).toBe('CNY');
    expect(fields.nonUsdCost?.amount).toBeCloseTo(0.6, 10);
    expect(fields.nonUsdCost?.costSource).toBe('localEstimate');
  });

  it('unrecognized currency: recorded as unknown, no USD fallback', async () => {
    await seed({
      currencyCode: 'yuan',
      pricingUnit: 'per_token',
      pricing: { promptPerMToken: 4, completionPerMToken: 16 },
    });
    const fields = deriveCostFields(USAGE, CATALOG_MODEL, { kind: 'deepseek' }, PRICED_AT, undefined);
    expect(fields.costSource).toBe('unknown');
    expect(fields.cost).toBe(0);
    expect(fields.nonUsdCost).toBeUndefined();
  });

  it('a USD catalog price or a missing currency is still recorded in USD, without nonUsdCost', async () => {
    for (const currency of [{ currencyCode: 'USD' }, {}]) {
      __resetMetadataClientForTest();
      await seed({ ...currency, pricingUnit: 'per_token', pricing: { promptPerMToken: 0.6, completionPerMToken: 2.5 } });
      const fields = deriveCostFields(USAGE, CATALOG_MODEL, { kind: 'deepseek' }, PRICED_AT, undefined);
      expect(fields.costSource).toBe('localEstimate');
      expect(fields.cost).toBeCloseTo(1.85, 10);
      expect('nonUsdCost' in fields).toBe(false);
    }
  });
});

describe('official providers do not use the model-bundled price as a USD fallback (only Relay / custom endpoints do)', () => {
  const MODEL_ID = 'kimi-local-price-test';
  // The model in the store carries an intl USD price (per token): $0.6/M input, $2.5/M output.
  const STORE_MODEL = {
    id: MODEL_ID,
    name: MODEL_ID,
    promptPrice: 0.000_000_6,
    completionPrice: 0.000_002_5,
  } as unknown as AIModel;
  const CN_CONNECTION = {
    kind: 'moonshot',
    endpointSource: 'region:cn',
    baseURLText: 'https://api.moonshot.cn/v1',
  } as const;
  const INTL_CONNECTION = {
    kind: 'moonshot',
    endpointSource: 'region:intl',
    baseURLText: 'https://api.moonshot.ai/v1',
  } as const;
  const BREAKDOWN = {
    promptTokens: 1_000_000,
    cachedInputTokens: 0,
    cacheCreation5mTokens: 0,
    cacheCreation1hTokens: 0,
    completionTokens: 500_000,
    reasoningTokens: 0,
  };
  const TOKENS = { prompt_tokens: 1_000_000, completion_tokens: 500_000 };

  afterEach(() => {
    __resetMetadataClientForTest();
  });

  it('moonshot cn connection + empty metadata cache: unknown with or without a breakdown, never the model-bundled USD price', () => {
    __resetMetadataClientForTest();
    expect(resolveCatalogModel(MODEL_ID, 'moonshot')).toBeNull();
    for (const usage of [{ ...TOKENS, breakdown: BREAKDOWN }, TOKENS]) {
      const fields = deriveCostFields(usage, STORE_MODEL, CN_CONNECTION, PRICED_AT, undefined);
      expect(fields.cost).toBe(0);
      expect(fields.costSource).toBe('unknown');
      expect(fields.nonUsdCost).toBeUndefined();
    }
  });

  it('model-level price is CNY + intl connection: recorded in CNY under nonUsdCost with or without a breakdown, CNY is never taken as USD', async () => {
    const data = {
      version: 1,
      contractVersion: 1,
      updatedAt: '2026-10-20T00:00:00Z',
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: {
        moonshot: {
          models: {
            [MODEL_ID]: {
              canonicalModelId: MODEL_ID,
              capabilities: ['text'],
              currencyCode: 'CNY',
              pricingStatus: 'priced',
              pricingUnit: 'per_token',
              pricing: { promptPerMToken: 4, completionPerMToken: 16 },
            },
          },
        },
      },
      providerConfigs: [],
    };
    await __seedMetadataCacheForTest({ data: JSON.parse(JSON.stringify(data)), timestamp: Date.now() });
    await initMetadata();
    // The store model carries the same numbers (the CNY unit prices were synced into promptPrice).
    const cnyNumbersModel = { ...STORE_MODEL, promptPrice: 0.000_004, completionPrice: 0.000_016 } as AIModel;
    for (const usage of [{ ...TOKENS, breakdown: BREAKDOWN }, TOKENS]) {
      const fields = deriveCostFields(usage, cnyNumbersModel, INTL_CONNECTION, PRICED_AT, undefined);
      expect(fields.cost).toBe(0);
      expect(fields.costSource).toBe('unknown');
      expect(fields.nonUsdCost?.currencyCode).toBe('CNY');
      expect(fields.nonUsdCost?.costSource).toBe('localEstimate');
      expect(fields.nonUsdCost?.amount).toBeCloseTo(12, 10);
    }
  });

  it('a Relay matched to an official CNY model: recorded at the matched entry CNY price under nonUsdCost, not at the model-bundled price in USD', async () => {
    const data = {
      version: 1,
      contractVersion: 1,
      updatedAt: '2026-10-20T00:00:00Z',
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: {
        moonshot: {
          models: {
            [MODEL_ID]: {
              canonicalModelId: MODEL_ID,
              capabilities: ['text'],
              currencyCode: 'CNY',
              pricingStatus: 'priced',
              pricingUnit: 'per_token',
              pricing: { promptPerMToken: 4, completionPerMToken: 16 },
            },
          },
        },
      },
      providerConfigs: [],
    };
    await __seedMetadataCacheForTest({ data: JSON.parse(JSON.stringify(data)), timestamp: Date.now() });
    await initMetadata();
    const relay = { kind: 'relay', baseURLText: 'https://relay.example.com/v1' } as const;
    // An enriched Relay model: the official CNY unit price numbers ended up in promptPrice / completionPrice.
    const enriched = { ...STORE_MODEL, promptPrice: 0.000_004, completionPrice: 0.000_016 } as AIModel;
    for (const usage of [{ ...TOKENS, breakdown: BREAKDOWN }, TOKENS]) {
      const fields = deriveCostFields(usage, enriched, relay, PRICED_AT, undefined);
      expect(fields.cost).toBe(0);
      expect(fields.costSource).toBe('unknown');
      expect(fields.nonUsdCost?.currencyCode).toBe('CNY');
      expect(fields.nonUsdCost?.costSource).toBe('localEstimate');
      expect(fields.nonUsdCost?.amount).toBeCloseTo(12, 10);
    }
    // Under the same metadata, a Relay model that matches no official model is still recorded at its bundled price (USD).
    const unmatched = deriveCostFields({ ...TOKENS, breakdown: BREAKDOWN }, RELAY_MODEL, relay, PRICED_AT, undefined);
    expect(unmatched.costSource).toBe('localEstimate');
    expect(unmatched.cost).toBeCloseTo(1 + 1, 10);
  });

  it('an official provider on a custom endpoint still falls back to the model-bundled price', () => {
    __resetMetadataClientForTest();
    const fields = deriveCostFields(
      { ...TOKENS, breakdown: BREAKDOWN },
      STORE_MODEL,
      { kind: 'moonshot', endpointSource: 'custom', baseURLText: 'https://proxy.example.com/v1' },
      PRICED_AT, undefined,
    );
    expect(fields.costSource).toBe('localEstimate');
    expect(fields.cost).toBeCloseTo(0.6 + 1.25, 10);
  });
});

describe('roundCostOf: a round merges retrieval cost, and the USD costSource follows the merged result', () => {
  it('mixed_cny_generation_usd_retrieval: CNY generation cost + USD retrieval cost -> USD part is localEstimate', () => {
    const round = roundCostOf(
      { cost: 0, costSource: 'unknown', nonUsdCost: { currencyCode: 'CNY', amount: 0.12, costSource: 'localEstimate' } },
      0.25,
    );
    expect(round).toEqual({
      estimatedCost: 0.25,
      costSource: 'localEstimate',
      nonUsdCost: { currencyCode: 'CNY', amount: 0.12, costSource: 'localEstimate' },
    });
  });

  it('no retrieval cost: keeps the generation cost source (unknown stays unknown)', () => {
    expect(roundCostOf({ cost: 0, costSource: 'unknown' }, 0).costSource).toBe('unknown');
    expect(roundCostOf({ cost: 0.3, costSource: 'upstream' }, 0.1)).toMatchObject({
      estimatedCost: 0.4,
      costSource: 'upstream',
    });
  });
});

describe('fall back to the model-bundled price only when the selected currency can be determined as USD (same rule as Android)', () => {
  const STORE_MODEL = {
    id: 'vendor/not-in-catalog',
    name: 'Not In Catalog',
    promptPrice: 0.000_001,
    completionPrice: 0.000_002,
  } as unknown as AIModel;
  const BREAKDOWN = {
    promptTokens: 1_000_000,
    cachedInputTokens: 0,
    cacheCreation5mTokens: 0,
    cacheCreation1hTokens: 0,
    completionTokens: 500_000,
    reasoningTokens: 0,
  };
  const TOKENS = { prompt_tokens: 1_000_000, completion_tokens: 500_000 };

  afterEach(() => {
    __resetMetadataClientForTest();
  });

  async function seedOpenRouterUsdOnly() {
    const data = {
      version: 1,
      contractVersion: 1,
      updatedAt: '2026-10-20T00:00:00Z',
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: {
        openRouter: {
          models: {
            'vendor/listed': {
              canonicalModelId: 'vendor/listed',
              capabilities: ['text'],
              currencyCode: 'USD',
              pricingStatus: 'priced',
              pricingUnit: 'per_token',
              pricing: { promptPerMToken: 3, completionPerMToken: 6 },
            },
          },
        },
      },
      providerConfigs: [],
    };
    await __seedMetadataCacheForTest({ data: JSON.parse(JSON.stringify(data)), timestamp: Date.now() });
    await initMetadata();
  }

  it('OpenRouter (catalog all USD) catalog miss + no upstream cost: recorded at the model-bundled USD price', async () => {
    await seedOpenRouterUsdOnly();
    expect(resolveCatalogModel(STORE_MODEL.id, 'openRouter')).toBeNull();
    for (const usage of [{ ...TOKENS, breakdown: BREAKDOWN }, TOKENS]) {
      const fields = deriveCostFields(usage, STORE_MODEL, { kind: 'openRouter' }, PRICED_AT, undefined);
      expect(fields.costSource).toBe('localEstimate');
      expect(fields.cost).toBeCloseTo(1 + 1, 10);
      expect(fields.nonUsdCost).toBeUndefined();
    }
  });

  it('with empty metadata OpenRouter cannot determine the currency either: recorded as unknown', () => {
    __resetMetadataClientForTest();
    const fields = deriveCostFields({ ...TOKENS, breakdown: BREAKDOWN }, STORE_MODEL, { kind: 'openRouter' }, PRICED_AT, undefined);
    expect(fields.costSource).toBe('unknown');
    expect(fields.cost).toBe(0);
  });
});
