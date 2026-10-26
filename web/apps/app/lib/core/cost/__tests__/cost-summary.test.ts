import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { ChatMessage, Conversation, Provider, ProviderKind } from '@oriveo/shared';
import {
  buildDailyNonUsdCostsLast7DaysByProvider,
  buildMonthlyBilledMessageCountByProvider,
  buildMonthlyCostSummary,
  buildMonthlyCostByProvider,
  buildMonthlyNonUsdCostByProvider,
} from '../cost-summary';

function message(overrides: Partial<ChatMessage>): ChatMessage {
  return {
    id: overrides.id ?? crypto.randomUUID(),
    role: overrides.role ?? 'assistant',
    text: overrides.text ?? 'reply',
    providerID: overrides.providerID,
    providerKind: overrides.providerKind ?? 'openAI',
    providerName: overrides.providerName ?? 'OpenAI',
    modelName: overrides.modelName ?? 'gpt-4o',
    estimatedCost: overrides.estimatedCost ?? 0,
    state: overrides.state ?? 'delivered',
    createdAt: overrides.createdAt ?? '2026-03-01T00:00:00Z',
  };
}

function conversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: overrides.id ?? crypto.randomUUID(),
    title: overrides.title ?? 'Test',
    hasCustomTitle: overrides.hasCustomTitle ?? false,
    providerID: overrides.providerID ?? 'provider-1',
    modelID: overrides.modelID ?? 'gpt-4o',
    previewText: overrides.previewText ?? '',
    estimatedCost: overrides.estimatedCost ?? 0,
    isDraft: overrides.isDraft ?? false,
    messages: overrides.messages ?? [],
    draftText: overrides.draftText ?? '',
    updatedAt: overrides.updatedAt ?? '2026-03-01T00:00:00Z',
    createdAt: overrides.createdAt ?? '2026-03-01T00:00:00Z',
  };
}

function makeProvider(id: string, kind: ProviderKind, customName?: string, baseURLText?: string): Provider {
  return {
    id,
    kind,
    customName,
    baseURLText: baseURLText ?? null,
    apiKey: '',
    apiKeyPreview: '',
    models: [],
    catalogModels: [],
    status: { kind: 'connected' } as Provider['status'],
  } as Provider;
}

describe('buildMonthlyCostSummary', () => {
  it('counts a message into the month by its own timestamp, not by the conversation creation time', () => {
    const providers = [makeProvider('provider-1', 'openAI')];
    const summary = buildMonthlyCostSummary(
      [
        conversation({
          createdAt: '2026-02-15T09:00:00Z',
          updatedAt: '2026-03-03T08:05:00Z',
          messages: [
            message({
              estimatedCost: 1.2,
              createdAt: '2026-03-03T08:00:00Z',
            }),
            message({
              estimatedCost: 0.8,
              createdAt: '2026-02-27T08:00:00Z',
            }),
          ],
        }),
      ],
      providers,
      new Date('2026-03-26T10:00:00Z'),
    );

    expect(summary.totalCost).toBeCloseTo(1.2);
    expect(summary.providers).toHaveLength(1);
    expect(summary.providers[0]).toMatchObject({
      providerKind: 'openAI',
      providerID: 'provider-1',
      displayName: 'OpenAI',
      cost: 1.2,
    });
  });

  it('gives each relay its own row keyed by providerID instead of merging by providerKind', () => {
    const providers = [
      makeProvider('relay-a', 'relay', 'My Relay'),
      makeProvider('relay-b', 'relay', undefined, 'https://api.proxy.example.com/v1'),
      makeProvider('provider-c', 'anthropic'),
    ];
    const summary = buildMonthlyCostSummary(
      [
        conversation({
          providerID: 'relay-a',
          messages: [message({ providerID: 'relay-a', providerKind: 'relay', estimatedCost: 1.0, createdAt: '2026-03-04T08:00:00Z' })],
        }),
        conversation({
          providerID: 'relay-b',
          messages: [message({ providerID: 'relay-b', providerKind: 'relay', estimatedCost: 2.5, createdAt: '2026-03-05T08:00:00Z' })],
        }),
        conversation({
          providerID: 'provider-c',
          messages: [message({ providerID: 'provider-c', providerKind: 'anthropic', estimatedCost: 0.9, createdAt: '2026-03-06T08:00:00Z' })],
        }),
      ],
      providers,
      new Date('2026-03-26T10:00:00Z'),
    );

    expect(summary.totalCost).toBeCloseTo(4.4);
    expect(summary.providers).toHaveLength(3);
    // Sorted by cost, descending
    expect(summary.providers[0]).toMatchObject({ providerKind: 'relay', providerID: 'relay-b', cost: 2.5 });
    // Without a customName, fall back to the baseURL host to tell connections apart
    expect(summary.providers[0].displayName).toContain('api.proxy.example.com');
    expect(summary.providers[1]).toMatchObject({ providerKind: 'relay', providerID: 'relay-a', displayName: 'My Relay', cost: 1.0 });
    expect(summary.providers[2]).toMatchObject({ providerKind: 'anthropic', providerID: 'provider-c', cost: 0.9 });
  });

  it('excludes draft conversations entirely', () => {
    const summary = buildMonthlyCostSummary(
      [
        conversation({
          isDraft: true,
          messages: [message({ estimatedCost: 3.2, createdAt: '2026-03-04T08:00:00Z' })],
        }),
        conversation({
          providerID: 'provider-b',
          messages: [message({ providerKind: 'anthropic', estimatedCost: 0.9, createdAt: '2026-03-05T08:00:00Z' })],
        }),
      ],
      [makeProvider('provider-b', 'anthropic')],
      new Date('2026-03-26T10:00:00Z'),
    );

    expect(summary.totalCost).toBeCloseTo(0.9);
    expect(summary.providers).toHaveLength(1);
    expect(summary.providers[0]).toMatchObject({ providerKind: 'anthropic', cost: 0.9 });
  });

  it('uses UTC month boundaries', () => {
    const summary = buildMonthlyCostSummary(
      [
        conversation({
          messages: [
            message({ estimatedCost: 0.4, createdAt: '2026-02-28T23:59:59Z' }),
            message({ estimatedCost: 0.6, createdAt: '2026-03-01T00:00:00Z' }),
          ],
        }),
      ],
      [makeProvider('provider-1', 'openAI')],
      new Date('2026-03-26T10:00:00Z'),
    );

    expect(summary.totalCost).toBeCloseTo(0.6);
    expect(summary.providers).toHaveLength(1);
    expect(summary.providers[0].cost).toBeCloseTo(0.6);
  });

});

describe('buildMonthlyCostByProvider', () => {
  it('aggregates independently by providerID', () => {
    const costs = buildMonthlyCostByProvider(
      [
        conversation({
          providerID: 'provider-a',
          messages: [
            message({ estimatedCost: 1.0, createdAt: '2026-03-04T08:00:00Z' }),
            message({ estimatedCost: 2.0, createdAt: '2026-03-05T08:00:00Z' }),
          ],
        }),
        conversation({
          providerID: 'provider-b',
          messages: [
            message({ providerKind: 'anthropic', estimatedCost: 0.5, createdAt: '2026-03-06T08:00:00Z' }),
          ],
        }),
      ],
      new Date('2026-03-26T10:00:00Z'),
    );

    expect(costs.size).toBe(2);
    expect(costs.get('provider-a')).toBeCloseTo(3.0);
    expect(costs.get('provider-b')).toBeCloseTo(0.5);
  });

  it('excludes messages outside the current month window', () => {
    const costs = buildMonthlyCostByProvider(
      [
        conversation({
          providerID: 'provider-a',
          messages: [
            message({ estimatedCost: 0.4, createdAt: '2026-02-28T23:59:59Z' }),
            message({ estimatedCost: 0.6, createdAt: '2026-03-01T00:00:00Z' }),
          ],
        }),
      ],
      new Date('2026-03-26T10:00:00Z'),
    );

    expect(costs.size).toBe(1);
    expect(costs.get('provider-a')).toBeCloseTo(0.6);
  });

  it('excludes provider cost from draft conversations', () => {
    const costs = buildMonthlyCostByProvider(
      [
        conversation({
          providerID: 'provider-a',
          isDraft: true,
          messages: [
            message({ estimatedCost: 1.2, createdAt: '2026-03-04T08:00:00Z' }),
          ],
        }),
        conversation({
          providerID: 'provider-b',
          messages: [
            message({ providerKind: 'anthropic', estimatedCost: 0.6, createdAt: '2026-03-05T08:00:00Z' }),
          ],
        }),
      ],
      new Date('2026-03-26T10:00:00Z'),
    );

    expect(costs.size).toBe(1);
    expect(costs.get('provider-a')).toBeUndefined();
    expect(costs.get('provider-b')).toBeCloseTo(0.6);
  });

  it('returns an empty Map when there is no cost data', () => {
    const costs = buildMonthlyCostByProvider(
      [
        conversation({
          messages: [message({ role: 'user', estimatedCost: 0 })],
        }),
      ],
      new Date('2026-03-26T10:00:00Z'),
    );

    expect(costs.size).toBe(0);
  });
});

/* -- cost-currency.v1 totalCases: monthly / provider / daily totals split by currency -- */

interface FixtureNonUsd { currencyCode: string; amount: number; costSource: 'estimated' | 'unknown' }
interface TotalCase {
  id: string;
  messages: Array<{ estimatedCost: number; nonUsdCost: FixtureNonUsd | null }>;
  expect: { parts: Array<{ currencyCode: string; amount: number }> };
}

const ROOT = resolve(__dirname, '../../../../../../..');
const totalCases = (JSON.parse(readFileSync(
  resolve(ROOT, 'shared/test-fixtures/provider-pricing/cost-currency.v1.json'), 'utf8',
)) as { totalCases: TotalCase[] }).totalCases;

function fixtureMessage(entry: TotalCase['messages'][number], createdAt: string): ChatMessage {
  const part = entry.nonUsdCost;
  return {
    ...message({ providerID: 'provider-1', estimatedCost: entry.estimatedCost, createdAt }),
    ...(part
      ? { nonUsdCost: { ...part, costSource: part.costSource === 'estimated' ? 'localEstimate' as const : 'unknown' as const } }
      : {}),
  };
}

function partsOf(usd: number, nonUsd: Record<string, number> | undefined) {
  const parts = usd > 0 ? [{ currencyCode: 'USD', amount: usd }] : [];
  for (const code of Object.keys(nonUsd ?? {}).sort()) parts.push({ currencyCode: code, amount: nonUsd![code] });
  return parts.map((part) => ({ currencyCode: part.currencyCode, amount: Number(part.amount.toFixed(10)) }));
}

describe('cost-currency.v1 totalCases (monthly / provider / daily totals)', () => {
  const now = new Date('2026-03-15T12:00:00Z');
  const providers = [makeProvider('provider-1', 'openAI')];

  for (const entry of totalCases) {
    it(`COST-SUMMARY-${entry.id}`, () => {
      const conversations = [conversation({ messages: entry.messages.map((m) => fixtureMessage(m, '2026-03-15T08:00:00Z')) })];

      const summary = buildMonthlyCostSummary(conversations, providers, now);
      expect(partsOf(summary.totalCost, summary.nonUsdTotals)).toEqual(entry.expect.parts);
      if (summary.providers[0]) {
        expect(partsOf(summary.providers[0].cost, summary.providers[0].nonUsdTotals)).toEqual(entry.expect.parts);
      }
      expect(summary.isVisible).toBe(entry.expect.parts.length > 0);
      if (!entry.expect.parts.some((part) => part.currencyCode !== 'USD')) {
        expect('nonUsdTotals' in summary).toBe(false);
      }

      const usdByProvider = buildMonthlyCostByProvider(conversations, now).get('provider-1') ?? 0;
      const nonUsdByProvider = buildMonthlyNonUsdCostByProvider(conversations, now).get('provider-1');
      expect(partsOf(usdByProvider, nonUsdByProvider)).toEqual(entry.expect.parts);

      const daily = buildDailyNonUsdCostsLast7DaysByProvider(conversations, now).get('provider-1');
      expect(partsOf(0, daily?.[6])).toEqual(entry.expect.parts.filter((part) => part.currencyCode !== 'USD'));
    });
  }

  it('daily non-USD buckets land by UTC calendar day with the last slot being today; messages outside the window are not counted', () => {
    const cny = (amount: number, createdAt: string): ChatMessage => fixtureMessage(
      { estimatedCost: 0, nonUsdCost: { currencyCode: 'CNY', amount, costSource: 'estimated' } }, createdAt,
    );
    const conversations = [conversation({ messages: [
      cny(1, '2026-03-15T01:00:00Z'),
      cny(2, '2026-03-13T23:59:00Z'),
      cny(4, '2026-03-08T12:00:00Z'),
    ] })];
    const buckets = buildDailyNonUsdCostsLast7DaysByProvider(conversations, new Date('2026-03-15T12:00:00Z')).get('provider-1');
    expect(buckets).toEqual([undefined, undefined, undefined, undefined, { CNY: 2 }, undefined, { CNY: 1 }]);
  });
});

describe('buildMonthlyBilledMessageCountByProvider', () => {
  it('a missing costSource with amount > 0 counts as a local estimate; unknown / zero amounts do not count; a non-USD-only message is judged by nonUsdCost', () => {
    const now = new Date('2026-03-20T00:00:00Z');
    const legacy = { ...message({ providerID: 'provider-1', estimatedCost: 0.2 }) };
    delete (legacy as Partial<ChatMessage>).costSource;
    const counts = buildMonthlyBilledMessageCountByProvider([
      conversation({
        messages: [
          legacy,
          { ...message({ providerID: 'provider-1', estimatedCost: 0 }), costSource: 'localEstimate' },
          { ...message({ providerID: 'provider-2', estimatedCost: 0.3 }), costSource: 'unknown' },
          {
            ...message({ providerID: 'provider-2', estimatedCost: 0 }),
            costSource: 'unknown',
            nonUsdCost: { currencyCode: 'CNY', amount: 0.5, costSource: 'upstream' },
          },
        ],
      }),
    ], now);
    expect(Object.fromEntries(counts)).toEqual({ 'provider-1': 1, 'provider-2': 1 });
  });
});
