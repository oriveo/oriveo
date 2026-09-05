import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { AIModel } from '@oriveo/shared';
import { estimateCost } from '../cost';

// Mock metadata-client
vi.mock('../../metadata/metadata-client', () => ({
  lookupPricing: vi.fn(() => null),
  resolveCatalogModel: vi.fn(() => null),
}));

import { lookupPricing, resolveCatalogModel } from '../../metadata/metadata-client';
const mockLookupPricing = vi.mocked(lookupPricing);
const mockResolveCatalogModel = vi.mocked(resolveCatalogModel);

const model: AIModel = {
  id: 'gpt-4', name: 'GPT-4', capabilities: ['text'],
  reasoningModeAvailable: false, isAvailable: true, isDefault: false,
  priceTier: '$$', groupKey: 'openai', groupName: 'OpenAI',
  promptPrice: 0.00003, completionPrice: 0.00006,
};

beforeEach(() => {
  mockLookupPricing.mockReset();
  mockLookupPricing.mockReturnValue(null);
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
    mockLookupPricing.mockReturnValue({
      promptPerToken: 0.000015,
      completionPerToken: 0.00006,
    });

    const cost = estimateCost(
      { prompt_tokens: 1000, completion_tokens: 500 },
      noPriceModel,
      'openAI',
    );
    expect(mockLookupPricing).toHaveBeenCalledWith('gpt-4', 'openAI');
    expect(cost).toBeCloseTo(0.000015 * 1000 + 0.00006 * 500);
  });

  it('non-token metadata pricing falls back to costPerUnit', () => {
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
    expect(mockLookupPricing).not.toHaveBeenCalled();
    expect(cost).toBe(0.04);
  });

  it('returns null (unknown price) when the model has no pricing and no providerKind', () => {
    const noPriceModel = { ...model, promptPrice: undefined, completionPrice: undefined };
    const cost = estimateCost({ prompt_tokens: 1000, completion_tokens: 500 }, noPriceModel);
    expect(cost).toBeNull();
  });

  it('returns null (unknown price) when the model has no pricing and the metadata service has no data', () => {
    const noPriceModel = { ...model, promptPrice: undefined, completionPrice: undefined };
    mockLookupPricing.mockReturnValue(null);

    const cost = estimateCost(
      { prompt_tokens: 1000, completion_tokens: 500 },
      noPriceModel,
      'anthropic',
    );
    expect(cost).toBeNull();
  });

  it('does not query the metadata service when the model has pricing (even with a providerKind)', () => {
    estimateCost({ prompt_tokens: 100, completion_tokens: 50 }, model, 'openAI');
    expect(mockLookupPricing).not.toHaveBeenCalled();
  });

  it('fuzzy match: a date-suffixed model ID finds pricing through the metadata resolveMap', () => {
    const dateModel = { ...model, id: 'gpt-4-0125-preview', promptPrice: undefined, completionPrice: undefined };
    mockLookupPricing.mockReturnValue({
      promptPerToken: 0.00001,
      completionPerToken: 0.00003,
    });

    const cost = estimateCost(
      { prompt_tokens: 1000, completion_tokens: 500 },
      dateModel,
      'openAI',
    );
    expect(mockLookupPricing).toHaveBeenCalledWith('gpt-4-0125-preview', 'openAI');
    expect(cost).toBeCloseTo(0.00001 * 1000 + 0.00003 * 500);
  });

  it('returns null for an unknown model (no own pricing and no metadata)', () => {
    const unknownModel = { ...model, id: 'custom-fine-tune-abc123', promptPrice: undefined, completionPrice: undefined };
    mockLookupPricing.mockReturnValue(null);

    const cost = estimateCost(
      { prompt_tokens: 500, completion_tokens: 200 },
      unknownModel,
      'openAI',
    );
    expect(cost).toBeNull();
  });
});
