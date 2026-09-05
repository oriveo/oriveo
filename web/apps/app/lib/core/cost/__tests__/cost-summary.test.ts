import { describe, expect, it } from 'vitest';
import type { ChatMessage, Conversation, Provider, ProviderKind } from '@oriveo/shared';
import {
  buildMonthlyCostSummary,
  buildMonthlyCostByProvider,
  type MonthlyCostSummary,
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
