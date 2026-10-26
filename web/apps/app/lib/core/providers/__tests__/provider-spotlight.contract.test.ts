// Replays the providers-page spotlight fixture case by case (shared/test-fixtures/provider-catalog/provider-spotlight.v1.json).
// Messages go through the production monthly summaries (buildMonthlyBilledMessageCountByProvider / buildMonthlyCostByProvider),
// and selection goes through the production selectSpotlightProvider, the same chain as ProviderList.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { ChatMessage, Conversation, Provider, ProviderKind } from '@oriveo/shared';
import {
  buildMonthlyBilledMessageCountByProvider,
  buildMonthlyCostByProvider,
} from '../../cost/cost-summary';
import type { NonUsdCost } from '../../cost/cost-currency';
import { selectSpotlightProvider } from '../provider-spotlight';

type FixtureMessage = {
  providerId: string;
  costSource: NonNullable<ChatMessage['costSource']>;
  estimatedCost: number;
  nonUsdCost?: NonUsdCost;
};
type FixtureCase = {
  id: string;
  providers: Array<{ id: string; kind: ProviderKind; status: 'connected' | 'syncing' | 'issue' }>;
  messages: FixtureMessage[];
  expect: { spotlightProviderIds: string[] };
};

const repositoryRoot = resolve(process.cwd(), '../../..');
const fixture = JSON.parse(readFileSync(
  resolve(repositoryRoot, 'shared/test-fixtures/provider-catalog/provider-spotlight.v1.json'),
  'utf8',
)) as { spotlightCount: { web: number }; cases: FixtureCase[] };

const now = new Date('2026-10-20T12:00:00Z');
const inMonth = '2026-10-10T08:00:00Z';

function provider(entry: FixtureCase['providers'][number]): Provider {
  return {
    id: entry.id,
    kind: entry.kind,
    baseURLText: null,
    apiKey: 'sk-test',
    apiKeyPreview: '',
    models: [],
    catalogModels: [],
    status: { kind: entry.status } as Provider['status'],
  } as Provider;
}

function conversationOf(messages: FixtureMessage[]): Conversation {
  return {
    id: 'conversation-1',
    title: 'Spotlight',
    hasCustomTitle: false,
    providerID: '',
    modelID: 'model',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    draftText: '',
    createdAt: inMonth,
    updatedAt: inMonth,
    messages: messages.map((m, index): ChatMessage => ({
      id: `message-${index}`,
      role: 'assistant',
      text: 'reply',
      providerID: m.providerId,
      providerKind: 'openAI',
      providerName: 'Provider',
      modelName: 'model',
      estimatedCost: m.estimatedCost,
      costSource: m.costSource,
      ...(m.nonUsdCost ? { nonUsdCost: m.nonUsdCost } : {}),
      state: 'delivered',
      createdAt: inMonth,
    })),
  } as Conversation;
}

describe('provider-spotlight.v1 contract', () => {
  it('Web shows only 1 card', () => {
    expect(fixture.spotlightCount.web).toBe(1);
  });

  for (const entry of fixture.cases) {
    it(`PROVIDER-SPOTLIGHT-${entry.id}`, () => {
      const conversations = [conversationOf(entry.messages)];
      const selected = selectSpotlightProvider(
        entry.providers.map(provider),
        buildMonthlyBilledMessageCountByProvider(conversations, now),
        buildMonthlyCostByProvider(conversations, now),
      );
      const ids = selected ? [selected.id] : [];
      expect(ids).toEqual(entry.expect.spotlightProviderIds.slice(0, fixture.spotlightCount.web));
    });
  }
});
