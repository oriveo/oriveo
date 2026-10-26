/**
 * Per-million price label follows the connection region (fixture shared/test-fixtures/provider-pricing/region-pricing.v1.json).
 *
 * Fixture models are decoded into the catalog by the production metadata-client; the connection picks its price
 * through the same entry point as cost accounting (connectionRegionId + selectRegionPricing), and the label goes
 * through the production formatter.
 * moonshot cn connection -> CNY; intl connection -> USD; no connection context -> the stored model-level price.
 */
import 'fake-indexeddb/auto';
import React from 'react';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { act, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import {
  __resetMetadataClientForTest,
  __seedMetadataCacheForTest,
  initMetadata,
} from '../../lib/core/metadata/metadata-client';
import { buildCatalogModel } from '../../lib/core/providers/catalog-model';
import { connectionModelPricing } from './model-price-tier-label';
import { ModelCommercialMetaInline, ModelMetaInline } from './ModelMetaInline';

vi.mock('next-intl', () => ({
  useLocale: () => 'en',
  useTranslations: () => (key: string, values?: Record<string, unknown>) =>
    values?.count != null ? `${key} ${String(values.count)}` : key,
}));

const ROOT = resolve(__dirname, '../../../../..');
const PROVIDER = 'moonshot';
type JsonRecord = Record<string, unknown>;

const fixture = JSON.parse(readFileSync(
  resolve(ROOT, 'shared/test-fixtures/provider-pricing/region-pricing.v1.json'), 'utf8',
)) as { model: JsonRecord; cnOnlyModel: JsonRecord; cases: Array<{ regionOptions?: Array<{ id: string; baseURL: string }> }> };
const REGION_OPTIONS = fixture.cases.find((entry) => entry.regionOptions)!.regionOptions!;
const MODEL_ID = fixture.model.id as string;
const CN_ONLY_ID = fixture.cnOnlyModel.id as string;
/** Official model priced in CNY at the model level (the fixture's cn region entry lifted to the model level): a Relay selects no region, the label still follows the model-level currency. */
const CNY_MODEL_ID = 'kimi-cny-example';
const cnyModel: JsonRecord = (() => {
  const { regionPricing, ...rest } = structuredClone(fixture.model) as JsonRecord & { regionPricing: JsonRecord[] };
  const cnEntry = regionPricing[0]!;
  return { ...rest, ...cnEntry, id: CNY_MODEL_ID };
})();

async function seedCatalog(): Promise<void> {
  const asModel = (model: JsonRecord) => ({ ...model, canonicalModelId: model.id, capabilities: ['text'] });
  const data = {
    version: 1,
    contractVersion: 1,
    updatedAt: '2026-10-20T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    providers: {
      [PROVIDER]: { models: { [MODEL_ID]: asModel(fixture.model), [CN_ONLY_ID]: asModel(fixture.cnOnlyModel), [CNY_MODEL_ID]: asModel(cnyModel) } },
    },
    providerConfigs: [{
      kind: PROVIDER,
      displayName: 'Moonshot',
      defaultBaseURL: REGION_OPTIONS[0]!.baseURL,
      regionOptions: REGION_OPTIONS.map((option) => ({ ...option, label: option.id })),
      trustedHosts: REGION_OPTIONS.map((option) => new URL(option.baseURL).hostname),
    }],
  };
  await __seedMetadataCacheForTest({ data: JSON.parse(JSON.stringify(data)), timestamp: Date.now() });
  await initMetadata();
}

function connection(region: 'cn' | 'intl'): Provider {
  return { id: `moonshot-${region}`, name: 'Moonshot', kind: PROVIDER, endpointSource: `region:${region}`, models: [] } as unknown as Provider;
}

function relayConnection(): Provider {
  return { id: 'relay-1', name: 'Relay', kind: 'relay', baseURLText: 'https://api.moonshot.cn/v1', models: [] } as unknown as Provider;
}

/** The stored model (production buildCatalogModel, model-level price). */
function storedModel(id = MODEL_ID): AIModel {
  return buildCatalogModel({ providerKind: PROVIDER, runtimeModelId: id, fallbackName: id });
}

beforeEach(async () => {
  await seedCatalog();
});

afterEach(() => {
  __resetMetadataClientForTest();
});

describe('per-million price label follows the connection region', () => {
  it('moonshot cn connection shows the CNY region price', () => {
    const pricing = connectionModelPricing({ id: MODEL_ID }, connection('cn'), 'en');
    expect(pricing?.currencyCode).toBe('CNY');
    expect(pricing?.priceTier).toBe('CN¥4/M');

    render(
      <ModelMetaInline model={storedModel()} provider={connection('cn')} containerClassName="meta" priceClassName="price" />,
    );
    expect(document.querySelector('.price')?.textContent).toBe('CN¥4/M');
  });

  it('moonshot cn connection shows CNY input / output unit prices in the model meta', () => {
    render(
      <ModelCommercialMetaInline model={storedModel()} provider={connection('cn')} containerClassName="specs" itemClassName="spec" />,
    );
    const items = Array.from(document.querySelectorAll('.spec')).map((node) => node.textContent ?? '');
    const input = items.find((item) => item.startsWith('input'))!;
    const output = items.find((item) => item.startsWith('output'))!;
    expect(input).toBe('input CN¥4/M');
    expect(output).toBe('output CN¥16/M');
  });

  it('moonshot intl connection shows the USD model-level price', () => {
    const pricing = connectionModelPricing({ id: MODEL_ID }, connection('intl'), 'en');
    expect(pricing?.currencyCode).toBe('USD');
    expect(pricing?.priceTier).toBe('$0.6/M');

    render(
      <ModelMetaInline model={storedModel()} provider={connection('intl')} containerClassName="meta" priceClassName="price" />,
    );
    expect(screen.getByText('$0.6/M')).toBeTruthy();
  });

  it('no connection context keeps the stored model-level price', () => {
    const model = storedModel();
    expect(model.priceTier).toBe('$0.6/M');
    expect(connectionModelPricing({ id: MODEL_ID }, undefined, 'en')).toBeNull();
    // A Relay matched to an official model priced in USD at the model level selects no region (even if the address looks like cn) and keeps the stored $ price.
    expect(connectionModelPricing({ id: MODEL_ID }, relayConnection(), 'en')).toBeNull();

    render(<ModelMetaInline model={model} containerClassName="meta" priceClassName="price" />);
    expect(screen.getByText('$0.6/M')).toBeTruthy();
  });

  it('no connection with a catalog kind labels the model-level CNY price in CNY', () => {
    const pricing = connectionModelPricing({ id: CNY_MODEL_ID }, undefined, 'en', PROVIDER);
    expect(pricing?.currencyCode).toBe('CNY');
    expect(pricing?.priceTier).toBe('CN¥4/M');

    const stored = storedModel(CNY_MODEL_ID);
    expect(stored.priceTier).toContain('$');
    render(<ModelMetaInline model={stored} providerKind={PROVIDER} containerClassName="meta" priceClassName="price" />);
    expect(document.querySelector('.price')?.textContent).toBe('CN¥4/M');
  });

  it('no connection with a catalog miss keeps the stored price string', () => {
    const userPriced = { ...storedModel(), id: 'user-entered-model', priceTier: '$9/$9' } as AIModel;
    expect(connectionModelPricing({ id: userPriced.id }, undefined, 'en', PROVIDER)).toBeNull();

    render(<ModelMetaInline model={userPriced} providerKind={PROVIDER} containerClassName="meta" priceClassName="price" />);
    expect(document.querySelector('.price')?.textContent).toBe('$9/$9');
  });

  it('no connection: metadata arriving after the first render recomputes the label', async () => {
    const stored = storedModel(CNY_MODEL_ID);
    __resetMetadataClientForTest();
    render(<ModelMetaInline model={stored} providerKind={PROVIDER} containerClassName="meta" priceClassName="price" />);
    expect(document.querySelector('.price')?.textContent).toBe(stored.priceTier);

    await act(async () => {
      await seedCatalog();
    });
    expect(document.querySelector('.price')?.textContent).toBe('CN¥4/M');
  });

  it('cn-only model under an intl connection shows no price instead of $0', () => {
    const pricing = connectionModelPricing({ id: CN_ONLY_ID }, connection('intl'), 'en');
    expect(pricing?.promptPrice).toBeUndefined();
    expect(pricing?.completionPrice).toBeUndefined();

    render(
      <ModelMetaInline model={storedModel(CN_ONLY_ID)} provider={connection('intl')} containerClassName="meta" priceClassName="price" />,
    );
    const label = document.querySelector('.price')?.textContent ?? '';
    expect(label).toBe('unknown');
    expect(label).not.toContain('$0');
  });

  it('relay matched to an official CNY model labels the model-level price in CNY', () => {
    const pricing = connectionModelPricing({ id: CNY_MODEL_ID }, relayConnection(), 'en');
    expect(pricing?.currencyCode).toBe('CNY');
    expect(pricing?.priceTier).toBe('CN¥4/M');

    // The stored value (production enrich path) is still written in $: the label is rewritten at render time by the model-level currency.
    const stored = { ...storedModel(CNY_MODEL_ID), id: CNY_MODEL_ID };
    expect(stored.priceTier).toContain('$');
    render(<ModelMetaInline model={stored} provider={relayConnection()} containerClassName="meta" priceClassName="price" />);
    expect(document.querySelector('.price')?.textContent).toBe('CN¥4/M');
  });

  it('relay model with a different id labels the price matched via its canonicalModelId', () => {
    const pricing = connectionModelPricing({ id: 'my-relay-alias', canonicalModelId: CNY_MODEL_ID }, relayConnection(), 'en');
    expect(pricing?.currencyCode).toBe('CNY');
    expect(pricing?.priceTier).toBe('CN¥4/M');
  });

  it('metadata arriving after the first render recomputes the label (cold start)', async () => {
    const stored = storedModel();
    __resetMetadataClientForTest();
    render(<ModelMetaInline model={stored} provider={connection('cn')} containerClassName="meta" priceClassName="price" />);
    // Catalog not arrived yet: no connection-selected price, keep the stored model-level price.
    expect(document.querySelector('.price')?.textContent).toBe('$0.6/M');

    await act(async () => {
      await seedCatalog();
    });
    expect(document.querySelector('.price')?.textContent).toBe('CN¥4/M');
  });
});
