/**
 * Shared fixture region-pricing.v1.json: select the region price by the connection's effective region.
 *
 * Fixture models are decoded into ResolvedModelMetadata through the production metadata-client, and official connections go through the whole
 * production path of deriveCostFields (region -> price -> estimate -> currency). Relay connections do not consult the official catalog on Web,
 * so that case asserts "no region price selected" at the price-selection layer and then estimates with the selected price.
 */
import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { calcCostFromResolved } from '../../chat/cost';
import { deriveCostFields, generatedImageUnits } from '../../chat/cost-fields';
import { emptyUsageBreakdown } from '../../chat/usage-breakdown';
import {
  __resetMetadataClientForTest,
  __seedMetadataCacheForTest,
  initMetadata,
  resolveCatalogModel,
} from '../../metadata/metadata-client';
import { resolveRegionLookupCatalog } from '../../../../app/providers/new/provider-config-catalog';
import { connectionRegionId, effectiveRegionId, pricingRegionCatalog, selectRegionPricing } from '../region-pricing';

// The pricing instant is passed explicitly: a fixed instant, never the wall clock.
const PRICED_AT = () => new Date('2026-10-19T12:00:00Z');

const ROOT = resolve(__dirname, '../../../../../../..');
const PROVIDER = 'moonshot';

type JsonRecord = Record<string, unknown>;

interface RegionPricingCase {
  id: string;
  modelRef: 'model' | 'cnOnlyModel';
  connectionRegion: string | null;
  connectionBaseURL?: string;
  connectionKind?: 'relay';
  regionOptions?: Array<{ id: string; baseURL: string }>;
  entryOverride?: JsonRecord;
  entryExtraKeys?: JsonRecord;
  usage: { inputTokens?: number; outputTokens?: number; images?: number };
  expect: { status: 'estimated' | 'unavailable'; amount?: number; currencyCode?: string };
}

const fixture = JSON.parse(readFileSync(
  resolve(ROOT, 'shared/test-fixtures/provider-pricing/region-pricing.v1.json'), 'utf8',
)) as { model: JsonRecord; cnOnlyModel: JsonRecord; cases: RegionPricingCase[] };

function modelJsonOf(entry: RegionPricingCase): JsonRecord {
  const model = structuredClone(fixture[entry.modelRef]);
  const regions = model.regionPricing as JsonRecord[];
  if (entry.entryOverride) regions[0] = structuredClone(entry.entryOverride);
  if (entry.entryExtraKeys) Object.assign(regions[0]!, entry.entryExtraKeys);
  return { ...model, canonicalModelId: model.id, capabilities: ['text'] };
}

/** Cases without regionOptions reuse the fixture's region options for the same provider (moonshot: intl / cn). */
const DEFAULT_REGION_OPTIONS = fixture.cases.find((entry) => entry.regionOptions)!.regionOptions!;

/**
 * Seed the catalog. The effective region reads only the frozen identity region table, not the delivered providerConfigs;
 * the delivered region options here may deliberately omit cn to prove region selection is unaffected.
 */
async function seed(model: JsonRecord, regionOptions: Array<{ id: string; baseURL: string }>): Promise<void> {
  const data = {
    version: 1,
    contractVersion: 1,
    updatedAt: '2026-10-20T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    providers: { [PROVIDER]: { models: { [model.id as string]: model } } },
    providerConfigs: regionOptions.length === 0 ? [] : [{
      kind: PROVIDER,
      displayName: 'Moonshot',
      defaultBaseURL: regionOptions[0]!.baseURL,
      regionOptions: regionOptions.map((option) => ({ ...option, label: option.id })),
      trustedHosts: regionOptions.map((option) => new URL(option.baseURL).hostname),
    }],
  };
  await __seedMetadataCacheForTest({ data: JSON.parse(JSON.stringify(data)), timestamp: Date.now() });
  await initMetadata();
}

function connectionOf(entry: RegionPricingCase): Pick<Provider, 'kind' | 'baseURLText' | 'endpointSource'> {
  return {
    kind: entry.connectionKind ?? PROVIDER,
    ...(entry.connectionRegion ? { endpointSource: `region:${entry.connectionRegion}` as const } : {}),
    ...(entry.connectionBaseURL ? { baseURLText: entry.connectionBaseURL } : {}),
  };
}

function breakdownOf(usage: RegionPricingCase['usage']) {
  return {
    ...emptyUsageBreakdown(),
    promptTokens: usage.inputTokens ?? 0,
    completionTokens: usage.outputTokens ?? 0,
  };
}

/** Normalize an estimate result to the fixture shape: status + amount + currency (empty = USD). */
function outcome(cost: number, costSource: string, currency: string | undefined) {
  return costSource === 'unknown'
    ? { status: 'unavailable' as const }
    : { status: 'estimated' as const, amount: cost, currencyCode: currency ?? 'USD' };
}

/** The record from deriveCostFields (USD part + nullable nonUsdCost) -> fixture shape; a single estimate lands in only one part. */
function outcomeOfFields(fields: ReturnType<typeof deriveCostFields>) {
  return fields.nonUsdCost
    ? outcome(fields.nonUsdCost.amount, fields.nonUsdCost.costSource, fields.nonUsdCost.currencyCode)
    : outcome(fields.cost, fields.costSource, undefined);
}

/** n image attachments produced this turn: the unit count goes through production generatedImageUnits. */
function producedImages(count: number) {
  return Array.from({ length: count }, (_, index) => ({
    id: `img-${index}`, kind: 'image' as const, fileName: `${index}.png`, mimeType: 'image/png', localImageID: `l${index}`,
  }));
}

afterEach(() => {
  __resetMetadataClientForTest();
});

describe('region-pricing.v1 cases', () => {
  for (const entry of fixture.cases) {
    it(`REGION-PRICING-${entry.id}`, async () => {
      const model = modelJsonOf(entry);
      const modelId = model.id as string;
      const regionOptions = entry.regionOptions ?? DEFAULT_REGION_OPTIONS;
      await seed(model, regionOptions);
      const connection = connectionOf(entry);
      const catalog = resolveRegionLookupCatalog();
      // The frozen identity region table used by production selection matches the fixture, so baseURL lookup / falling back to the first option really feeds the production path.
      expect(catalog.configsByKind.moonshot.regionOptions.map(({ id, baseURL }) => ({ id, baseURL })))
        .toEqual(regionOptions);
      const aiModel = { id: modelId, name: modelId } as unknown as AIModel;

      let actual: ReturnType<typeof outcome>;
      if (entry.connectionKind === 'relay') {
        expect(effectiveRegionId(connection, catalog)).toBeNull();
        const resolved = resolveCatalogModel(modelId, PROVIDER)!;
        const selected = selectRegionPricing(resolved, effectiveRegionId(connection, catalog));
        const result = calcCostFromResolved(breakdownOf(entry.usage), selected);
        actual = outcome(result.cost, result.source, selected.currencyCode);
      } else if (entry.usage.images !== undefined) {
        // Per-unit pricing estimates the whole message once from the produced unit count (a missing count is unknown); the count comes from the production counter.
        const units = generatedImageUnits(producedImages(entry.usage.images));
        const fields = deriveCostFields({ prompt_tokens: 0, completion_tokens: 0 }, aiModel, connection, PRICED_AT, units);
        actual = outcomeOfFields(fields);
      } else {
        const fields = deriveCostFields({ breakdown: breakdownOf(entry.usage) }, aiModel, connection, PRICED_AT, undefined);
        actual = outcomeOfFields(fields);
      }

      if (entry.expect.status === 'unavailable') {
        expect(actual).toEqual({ status: 'unavailable' });
        return;
      }
      expect(actual.status).toBe('estimated');
      if (actual.status !== 'estimated') return;
      expect(actual.currencyCode).toBe(entry.expect.currencyCode);
      expect(actual.amount).toBeCloseTo(entry.expect.amount!, 10);
    });
  }
});

describe('the effective region does not depend on region options delivered by metadata', () => {
  const cnCase = fixture.cases.find((entry) => entry.id === 'cn_connection_uses_cny_entry')!;
  const cases: Array<[string, Array<{ id: string; baseURL: string }>]> = [
    ['providerConfigs not delivered', []],
    ['providerConfigs only has intl', DEFAULT_REGION_OPTIONS.filter((option) => option.id !== 'cn')],
  ];
  for (const [label, regionOptions] of cases) {
    it(`${label}: a moonshot cn connection still takes the cn region price and records CNY`, async () => {
      const model = modelJsonOf(cnCase);
      await seed(model, regionOptions);
      const connection = connectionOf(cnCase);
      expect(effectiveRegionId(connection, resolveRegionLookupCatalog())).toBe('cn');
      const aiModel = { id: model.id, name: model.id } as unknown as AIModel;
      const fields = deriveCostFields({ breakdown: breakdownOf(cnCase.usage) }, aiModel, connection, PRICED_AT, undefined);
      expect(fields.costSource).toBe('unknown');
      expect(fields.cost).toBe(0);
      expect(fields.nonUsdCost?.currencyCode).toBe('CNY');
      expect(fields.nonUsdCost?.costSource).toBe('localEstimate');
      expect(fields.nonUsdCost?.amount).toBeCloseTo(cnCase.expect.amount!, 10);
    });
  }
});

describe('delivered region options merge into region selection (the frozen table fills unlisted ids)', () => {
  const QWEN_MODEL = 'qwen-region-merge-test';
  const DE = { id: 'de', baseURL: 'https://dashscope-de.aliyuncs.com' };

  async function seedQwen(): Promise<void> {
    const data = {
      version: 1,
      contractVersion: 1,
      updatedAt: '2026-10-20T00:00:00Z',
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: {
        qwen: {
          models: {
            [QWEN_MODEL]: {
              canonicalModelId: QWEN_MODEL,
              capabilities: ['text'],
              currencyCode: 'USD',
              pricingStatus: 'priced',
              pricingUnit: 'per_token',
              pricing: { promptPerMToken: 0.5, completionPerMToken: 1 },
              regionPricing: [{
                regionScope: 'de',
                currencyCode: 'EUR',
                pricingStatus: 'priced',
                pricingUnit: 'per_token',
                pricing: { promptPerMToken: 1, completionPerMToken: 2 },
              }],
            },
          },
        },
      },
      providerConfigs: [{
        kind: 'qwen',
        displayName: 'Qwen',
        defaultBaseURL: DE.baseURL,
        regionOptions: [{ ...DE, label: DE.id }],
        trustedHosts: [new URL(DE.baseURL).hostname],
      }],
    };
    await __seedMetadataCacheForTest({ data: JSON.parse(JSON.stringify(data)), timestamp: Date.now() });
    await initMetadata();
  }

  it('qwen de region outside the frozen table: once delivered the connection selects de and records the EUR region price', async () => {
    await seedQwen();
    const connection = { kind: 'qwen', endpointSource: 'region:de' as const, baseURLText: DE.baseURL };
    expect(connectionRegionId(connection)).toBe('de');
    const aiModel = { id: QWEN_MODEL, name: QWEN_MODEL } as unknown as AIModel;
    const fields = deriveCostFields(
      { breakdown: breakdownOf({ inputTokens: 1_000_000, outputTokens: 500_000 }) },
      aiModel,
      connection,
      PRICED_AT,
      undefined,
    );
    expect(fields.cost).toBe(0);
    expect(fields.costSource).toBe('unknown');
    expect(fields.nonUsdCost?.currencyCode).toBe('EUR');
    expect(fields.nonUsdCost?.amount).toBeCloseTo(2, 10);
  });

  it('when only de is delivered, bj from the frozen table still matches by address', async () => {
    await seedQwen();
    expect(connectionRegionId({ kind: 'qwen', baseURLText: 'https://dashscope.aliyuncs.com' })).toBe('bj');
    expect(connectionRegionId({ kind: 'qwen', endpointSource: 'region:bj' })).toBe('bj');
  });

  it('metadata not loaded: only the frozen table is used, de outside it is not recognized and falls back to the first option', () => {
    expect(connectionRegionId({ kind: 'qwen', endpointSource: 'region:de', baseURLText: DE.baseURL })).toBe('sg');
  });

  it('the region catalog is cached by metadata revision: not rebuilt for the same revision, replaced after redelivery and recognizes the new region', async () => {
    const frozen = pricingRegionCatalog();
    expect(pricingRegionCatalog()).toBe(frozen);
    expect(frozen.configsByKind.qwen.regionOptions.some((option) => option.id === 'de')).toBe(false);

    await seedQwen();
    const merged = pricingRegionCatalog();
    expect(merged).not.toBe(frozen);
    expect(pricingRegionCatalog()).toBe(merged);
    expect(merged.configsByKind.qwen.regionOptions.map((option) => option.id)).toContain('de');

    // The revision restarts after the client resets: a redelivered catalog of the same shape is a different set of objects and must not reuse the old cache.
    __resetMetadataClientForTest();
    expect(pricingRegionCatalog()).toBe(frozen);
    await seedQwen();
    expect(pricingRegionCatalog()).not.toBe(merged);
  });
});
