import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { AIModel } from '@oriveo/shared';
import { estimateCost } from '../cost';

// Mock metadata-client
vi.mock('../../metadata/metadata-client', async (importOriginal) => (await import('../../../__tests__/mocks/metadata-client')).metadataClientMock(importOriginal, {
  resolveCatalogModel: vi.fn(() => null),
}));

import { resolveCatalogModel } from '../../metadata/metadata-client';
const mockResolveCatalogModel = vi.mocked(resolveCatalogModel);

const model: AIModel = {
  id: 'gpt-4', name: 'GPT-4', capabilities: ['text'],
  reasoningModeAvailable: false, isAvailable: true, isDefault: false,
  priceTier: '$$', groupKey: 'openai', groupName: 'OpenAI',
  promptPrice: 0.00003, completionPrice: 0.00006,
};

/** Catalog USD per-token price (estimateCost reads it through resolveCatalogModel). */
function perTokenCatalog(promptPerToken: number, completionPerToken: number) {
  return {
    pricingStatus: 'priced',
    pricingUnit: 'per_token',
    pricing: { promptPerToken, completionPerToken },
  } as never;
}

beforeEach(() => {
  mockResolveCatalogModel.mockReset();
  mockResolveCatalogModel.mockReturnValue(null);
});

describe('estimateCost', () => {
  it('computes prompt + completion cost normally (model carries its own pricing)', () => {
    const cost = estimateCost({ prompt_tokens: 100, completion_tokens: 50 }, model);
    expect(cost).toBeCloseTo(0.00003 * 100 + 0.00006 * 50);
  });

  it('returns 0 when usage is undefined', () => {
    expect(estimateCost(undefined, model)).toBe(0);
  });

  it('returns 0 when the model is undefined', () => {
    expect(estimateCost({ prompt_tokens: 100 }, undefined)).toBe(0);
  });

  it('returns 0 when the price is 0', () => {
    const freeModel = { ...model, promptPrice: 0, completionPrice: 0 };
    expect(estimateCost({ prompt_tokens: 1000, completion_tokens: 500 }, freeModel)).toBe(0);
  });

  it('looks the metadata service up by providerKind when the model has no pricing', () => {
    const noPriceModel = { ...model, promptPrice: undefined, completionPrice: undefined };
    mockResolveCatalogModel.mockReturnValue(perTokenCatalog(0.000015, 0.00006));

    const cost = estimateCost(
      { prompt_tokens: 1000, completion_tokens: 500 },
      noPriceModel,
      'openAI',
    );
    expect(mockResolveCatalogModel).toHaveBeenCalledWith('gpt-4', 'openAI');
    expect(cost).toBeCloseTo(0.000015 * 1000 + 0.00006 * 500);
  });

  it('returns null for per-unit metadata pricing when the unit count is unavailable (unknown, never estimated as one unit)', () => {
    const noPriceModel = { ...model, id: 'gpt-image-1', promptPrice: undefined, completionPrice: undefined };
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'gpt-image-1',
      pricingStatus: 'priced',
      pricingUnit: 'per_image',
      pricing: {
        costPerUnit: 0.04,
      },
      capabilities: [],
    } as never);

    const cost = estimateCost(
      { prompt_tokens: 0, completion_tokens: 0 },
      noPriceModel,
      'openAI',
    );

    expect(mockResolveCatalogModel).toHaveBeenCalledWith('gpt-image-1', 'openAI');
    expect(cost).toBeNull();
  });

  it('treats metadata without a pricingUnit as per_token', () => {
    const noPriceModel = { ...model, promptPrice: undefined, completionPrice: undefined };
    mockResolveCatalogModel.mockReturnValue({
      pricingStatus: 'priced',
      pricing: { promptPerToken: 0.000002, completionPerToken: 0.000008, costPerUnit: 0.04 },
    } as never);

    const cost = estimateCost({ prompt_tokens: 1000, completion_tokens: 500 }, noPriceModel, 'openAI');

    expect(cost).toBeCloseTo(0.000002 * 1000 + 0.000008 * 500, 12);
  });

  it('returns null (unknown price) when the model has no pricing and no providerKind', () => {
    const noPriceModel = { ...model, promptPrice: undefined, completionPrice: undefined };
    const cost = estimateCost({ prompt_tokens: 1000, completion_tokens: 500 }, noPriceModel);
    expect(cost).toBeNull();
  });

  it('returns null (unknown price) when the model has no pricing and the metadata service has no data', () => {
    const noPriceModel = { ...model, promptPrice: undefined, completionPrice: undefined };
    mockResolveCatalogModel.mockReturnValue(null);

    const cost = estimateCost(
      { prompt_tokens: 1000, completion_tokens: 500 },
      noPriceModel,
      'anthropic',
    );
    expect(cost).toBeNull();
  });

  it("uses the model's own price when it has one (even if the catalog also has a price)", () => {
    mockResolveCatalogModel.mockReturnValue(perTokenCatalog(1, 1));
    const cost = estimateCost({ prompt_tokens: 100, completion_tokens: 50 }, model, 'openAI');
    expect(cost).toBeCloseTo(0.00003 * 100 + 0.00006 * 50);
  });

  it('fuzzy match: a date-suffixed model ID finds pricing through the metadata resolveMap', () => {
    const dateModel = { ...model, id: 'gpt-4-0125-preview', promptPrice: undefined, completionPrice: undefined };
    mockResolveCatalogModel.mockReturnValue(perTokenCatalog(0.00001, 0.00003));

    const cost = estimateCost(
      { prompt_tokens: 1000, completion_tokens: 500 },
      dateModel,
      'openAI',
    );
    expect(mockResolveCatalogModel).toHaveBeenCalledWith('gpt-4-0125-preview', 'openAI');
    expect(cost).toBeCloseTo(0.00001 * 1000 + 0.00003 * 500);
  });

  it('returns null for an unknown model (no own pricing and no metadata)', () => {
    const unknownModel = { ...model, id: 'custom-fine-tune-abc123', promptPrice: undefined, completionPrice: undefined };
    mockResolveCatalogModel.mockReturnValue(null);

    const cost = estimateCost(
      { prompt_tokens: 500, completion_tokens: 200 },
      unknownModel,
      'openAI',
    );
    expect(cost).toBeNull();
  });
});
