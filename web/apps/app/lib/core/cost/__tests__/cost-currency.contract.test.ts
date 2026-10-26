/**
 * Shared fixture cost-currency.v1.json (cost result currency).
 *
 * - recordCases: estimatedCost holds only the USD part, the single non-USD part goes to nonUsdCost, no conversion;
 *   a second non-USD currency -> {first currency, 0, unknown}. Supersedes cost-result.v1 currencyCases.
 * - displayCases: multi-currency segmented display; USD keeps formatCost, other currencies use the standard symbol of the UI language
 *   and pick digits from their own amount tier; parts with an unavailable amount show no amount (notAvailableParts).
 * - totalCases: conversation totals are summed per currency (recalculateConversationCostTotals); zero-amount currencies are not written
 *   and parts with an unavailable amount are skipped.
 * - Message append merge (addMessageCost / mergeNonUsdCost): USD adds; non-USD of the same currency adds, different currencies -> {first currency, 0, unknown}.
 * - relayPricingCases: when a Relay matches an official entry it uses the same estimate entry as official messages (deriveCostFields) and the currency comes from the matched entry;
 *   a match never falls back to the model's own price (a v2 that cannot estimate records unknown); with no match the model's own price goes through the legacy single tier; with neither it is unknown;
 *   an upstream that reports no usage records unknown; an official connection with v2 unavailable also does not fall back; the pricing instant is injected from the fixture's at.
 * migrationCases are covered elsewhere.
 */
import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import type { AIModel, ChatMessage } from '@oriveo/shared';
import { recalculateConversationCostTotals } from '../../chat/usage-tracking';
import { costResultOfEstimate, deriveCostFields, generatedImageUnits, sumLegCostFields } from '../../chat/cost-fields';
import {
  __resetMetadataClientForTest,
  __seedMetadataCacheForTest,
  initMetadata,
} from '../../metadata/metadata-client';
import type { PricingV2Estimate } from '../../pricing/pricing-v2-estimate';
import { costFractionDigits } from '../../../utils/format-utils';
import { anthropicMessagesStrategy } from '../../providers/transport/strategies/anthropic-messages';
import { mergeToolLoopUsage } from '@oriveo/core/tools/tool-call-loop';
import { createStreamContext } from '../../providers/transport/transport-strategy';
import { createProxyChunkParser } from '@oriveo/core/providers/proxy-chunk-parser';
import type { StreamEvent } from '@oriveo/core/providers/types';
import {
  addMessageCost,
  formatCostParts,
  formatCostTotals,
  mergeNonUsdCost,
  nonUsdCostTotalsEqual,
  notAvailableCostParts,
  type NonUsdCost,
} from '../cost-currency';

const ROOT = resolve(__dirname, '../../../../../../..');

/** The fixture's costSource 'estimated' is Web's 'localEstimate'. */
type FixtureCostSource = 'estimated' | 'unknown';
interface FixtureNonUsd { currencyCode: string; amount: number; costSource: FixtureCostSource }
interface FixtureMessage { estimatedCost: number; costSource: FixtureCostSource; nonUsdCost: FixtureNonUsd | null }

interface RecordCase {
  id: string;
  estimate?: PricingV2Estimate;
  estimates?: PricingV2Estimate[];
  expect: FixtureMessage | { recorded: false };
}

interface TotalCase {
  id: string;
  messages: FixtureMessage[];
  expect: { parts: Array<{ currencyCode: string; amount: number }> };
}

interface IncompleteThreadMessage extends FixtureMessage { id: string }
interface FixtureTotals { estimatedCost: number; nonUsdCostTotals: Record<string, number> | null }
interface IncompleteThreadCase {
  id: string;
  remoteTotals: FixtureTotals;
  localMessages: IncompleteThreadMessage[];
  isComplete: boolean;
  change:
    | { kind: 'add' | 'delete' | 'costChange'; before: IncompleteThreadMessage | null; after: IncompleteThreadMessage | null }
    | { kind: 'remoteWindowMerged'; messages: IncompleteThreadMessage[] };
  expectTotals: FixtureTotals;
  rejectTotals?: FixtureTotals[];
}

interface RelayPricingCase {
  id: string;
  /** The Relay model's own id; default = catalogMatch.canonicalModelId (literal id match). */
  relayModelId?: string;
  /** Default 'relay'; 'official' = the same record goes through the connection of the official provider that owns the matched entry. */
  connection?: 'relay' | 'official';
  /** pricingStatus defaults to 'priced'; pricingV2 null = the matched entry has no price at all. */
  catalogMatch: {
    canonicalModelId: string;
    pricingStatus?: string;
    /** Per-unit pricing: default = per_token. */
    pricingUnit?: string;
    perUnitPrice?: number;
    pricingV2: ({ currencyCode: string } & Record<string, unknown>) | null;
  } | null;
  /** Unit count for per-unit pricing; default = not estimated per unit. */
  units?: number;
  localPrice: { inputPerMToken: number; outputPerMToken: number } | null;
  /** The upstream's actual cost is always USD (no currency field). */
  upstreamCost: { amount: number } | null;
  /** null = the upstream reported no usage. */
  usage: {
    uncachedInputTokens: number;
    cacheReadTokens: number;
    cacheWrite5mTokens: number;
    cacheWrite1hTokens: number;
    outputTokens: number;
  } | null;
  at: string;
  expect: { estimatedCost: number; costSource: FixtureCostSource | 'upstream'; nonUsdCost: FixtureNonUsd | null };
}

interface FixtureUsage {
  uncachedInputTokens: number;
  cacheReadTokens: number;
  cacheWrite5mTokens: number;
  cacheWrite1hTokens: number;
  outputTokens: number;
}

interface MultiLegCostCase extends Omit<MultiLegCostCaseBase, 'expect'> {
  expect: Omit<FixtureMessage, 'costSource'> & { costSource: FixtureCostSource | 'subscription' | 'upstream' };
}

interface MultiLegCostCaseBase {
  id: string;
  /** null = each leg carries its own pricingV2. */
  pricingV2: ({ currencyCode: string } & Record<string, unknown>) | null;
  /** 'subscription' = a subscription connection (the whole message is recorded as subscription); 'relay' = Relay (upstream actual cost is not adopted); default = an official connection that reports actual upstream cost (OpenRouter). */
  connection?: 'subscription' | 'relay';
  /** Units produced this turn in per-unit cases: counted once for the whole message. */
  units?: number;
  at: string;
  /** usage null = the upstream of this leg reported no usage; pricingV2 overrides the case's pricingV2. */
  legs: Array<{
    pricingV2?: { currencyCode: string } & Record<string, unknown>;
    usage: FixtureUsage | null;
    upstreamCost: { amount: number } | null;
  }>;
  expect: FixtureMessage;
}

interface DisplayCase {
  id: string;
  locale: string;
  message?: FixtureMessage;
  parts: Array<{ currencyCode: string; amount: number; fractionDigits: number }>;
  notAvailableParts?: string[];
  expect: string;
}

const fixture = JSON.parse(readFileSync(
  resolve(ROOT, 'shared/test-fixtures/provider-pricing/cost-currency.v1.json'), 'utf8',
)) as {
  recordCases: RecordCase[];
  totalCases: TotalCase[];
  displayCases: DisplayCase[];
  totalsIncompleteThreadCases: IncompleteThreadCase[];
  relayPricingCases: RelayPricingCase[];
  multiLegCostCases: MultiLegCostCase[];
};

function webSource(source: FixtureCostSource) {
  return source === 'estimated' ? 'localEstimate' : 'unknown';
}

function webNonUsd(part: FixtureNonUsd | null): NonUsdCost | null {
  return part ? { ...part, costSource: webSource(part.costSource) } : null;
}

describe('cost-currency.v1 recordCases', () => {
  for (const entry of fixture.recordCases) {
    it(`COST-CURRENCY-${entry.id}`, () => {
      const result = costResultOfEstimate(entry.estimates ?? entry.estimate!);
      if ('recorded' in entry.expect) {
        expect(result).toEqual({ cost: 0, source: 'unknown' });
        return;
      }
      // Without a non-USD part the nonUsdCost key is not written (= null).
      expect({ cost: result.cost, source: result.source, nonUsdCost: result.nonUsdCost ?? null }).toEqual({
        cost: entry.expect.estimatedCost,
        source: webSource(entry.expect.costSource),
        nonUsdCost: webNonUsd(entry.expect.nonUsdCost),
      });
      if (!entry.expect.nonUsdCost) expect('nonUsdCost' in result).toBe(false);
    });
  }
});

describe('cost-currency.v1 displayCases', () => {
  for (const entry of fixture.displayCases) {
    it(`COST-CURRENCY-${entry.id}`, () => {
      for (const part of entry.parts) {
        expect(costFractionDigits(part.amount)).toBe(part.fractionDigits);
      }
      const usd = entry.message?.estimatedCost
        ?? entry.parts.find((part) => part.currencyCode === 'USD')?.amount ?? 0;
      const nonUsdPart = entry.parts.find((part) => part.currencyCode !== 'USD');
      const nonUsd = entry.message
        ? webNonUsd(entry.message.nonUsdCost)
        : nonUsdPart
          ? { currencyCode: nonUsdPart.currencyCode, amount: nonUsdPart.amount, costSource: 'localEstimate' as const }
          : null;
      expect(formatCostParts(usd, nonUsd, entry.locale)).toBe(entry.expect);
      expect(notAvailableCostParts(nonUsd)).toEqual(entry.notAvailableParts ?? []);
    });
  }
});

describe('cost-currency.v1 totalCases', () => {
  for (const entry of fixture.totalCases) {
    it(`COST-CURRENCY-${entry.id}`, () => {
      const messages = entry.messages.map((message, index) => ({
        id: `m-${index}`,
        role: 'assistant',
        text: '',
        providerKind: 'deepseek',
        providerName: 'DeepSeek',
        modelName: 'deepseek-chat',
        state: 'delivered',
        estimatedCost: message.estimatedCost,
        costSource: webSource(message.costSource),
        ...(message.nonUsdCost ? { nonUsdCost: webNonUsd(message.nonUsdCost)! } : {}),
      }) as ChatMessage);
      const totals = recalculateConversationCostTotals(messages, null);
      // Part order: USD first, then other currency codes ascending; zero amounts are not written.
      const parts = [
        ...(totals.estimatedCost > 0 ? [{ currencyCode: 'USD', amount: totals.estimatedCost }] : []),
        ...Object.keys(totals.nonUsdCostTotals ?? {}).sort()
          .map((code) => ({ currencyCode: code, amount: totals.nonUsdCostTotals![code] })),
      ];
      expect(parts.map((part) => part.currencyCode)).toEqual(entry.expect.parts.map((part) => part.currencyCode));
      parts.forEach((part, index) => expect(part.amount).toBeCloseTo(entry.expect.parts[index].amount, 10));
      // Without a non-USD total the nonUsdCostTotals key is not written.
      if (!entry.expect.parts.some((part) => part.currencyCode !== 'USD')) {
        expect('nonUsdCostTotals' in totals).toBe(false);
      }
    });
  }
});

function threadMessage(message: IncompleteThreadMessage): ChatMessage {
  return {
    id: message.id,
    role: 'assistant',
    text: '',
    providerKind: 'deepseek',
    providerName: 'DeepSeek',
    modelName: 'deepseek-chat',
    state: 'delivered',
    estimatedCost: message.estimatedCost,
    costSource: (message.costSource as string) === 'upstream' ? 'upstream' : webSource(message.costSource),
    ...(message.nonUsdCost ? { nonUsdCost: webNonUsd(message.nonUsdCost)! } : {}),
  } as ChatMessage;
}

function expectTotalsClose(
  actual: { estimatedCost: number; nonUsdCostTotals?: Record<string, number> },
  expected: FixtureTotals,
) {
  expect(actual.estimatedCost).toBeCloseTo(expected.estimatedCost, 9);
  const expectedCodes = Object.keys(expected.nonUsdCostTotals ?? {}).sort();
  // An empty map is written as null: on the Web conversation object the nonUsdCostTotals key is simply not written.
  if (expectedCodes.length === 0) expect('nonUsdCostTotals' in actual).toBe(false);
  expect(Object.keys(actual.nonUsdCostTotals ?? {}).sort()).toEqual(expectedCodes);
  for (const code of expectedCodes) {
    expect(actual.nonUsdCostTotals![code]).toBeCloseTo(expected.nonUsdCostTotals![code], 9);
  }
}

function totalsMatch(
  actual: { estimatedCost: number; nonUsdCostTotals?: Record<string, number> },
  expected: FixtureTotals,
): boolean {
  if (Math.abs(actual.estimatedCost - expected.estimatedCost) > 1e-9) return false;
  return nonUsdCostTotalsEqual(actual.nonUsdCostTotals, expected.nonUsdCostTotals);
}

// Conversation totals and the local "thread complete" flag: through the single production totals function recalculateConversationCostTotals,
// the conversation-side input = remote totals + localThreadComplete, and the before / after messages are built from change.
describe('cost-currency.v1 totalsIncompleteThreadCases', () => {
  for (const entry of fixture.totalsIncompleteThreadCases) {
    it(`COST-CURRENCY-${entry.id}`, () => {
      const local = entry.localMessages.map(threadMessage);
      let previousMessages = local;
      let nextMessages: ChatMessage[];
      const change = entry.change;
      if (change.kind === 'remoteWindowMerged') {
        // A window merged in from the cloud is already counted in the remote totals; both the before and after messages contain it, so it produces no delta.
        previousMessages = [...local, ...change.messages.map(threadMessage)];
        nextMessages = previousMessages;
      } else if (change.kind === 'add') {
        nextMessages = [...local, threadMessage(change.after!)];
      } else if (change.kind === 'delete') {
        nextMessages = local.filter((message) => message.id !== change.before!.id);
      } else {
        const after = threadMessage(change.after!);
        nextMessages = local.map((message) => (message.id === after.id ? after : message));
      }
      const conversation = {
        estimatedCost: entry.remoteTotals.estimatedCost,
        ...(entry.remoteTotals.nonUsdCostTotals ? { nonUsdCostTotals: entry.remoteTotals.nonUsdCostTotals } : {}),
        localThreadComplete: entry.isComplete,
      };
      const totals = recalculateConversationCostTotals(nextMessages, { conversation, previousMessages });
      expectTotalsClose(totals, entry.expectTotals);
      for (const rejected of entry.rejectTotals ?? []) {
        expect(totalsMatch(totals, rejected)).toBe(false);
      }
    });
  }

  it('legacy data without the flag is treated as incomplete: no full recompute', () => {
    const local = [threadMessage({ id: 'm1', estimatedCost: 1, costSource: 'estimated', nonUsdCost: null })];
    const totals = recalculateConversationCostTotals(local, {
      conversation: { estimatedCost: 10 },
      previousMessages: local,
    });
    expect(totals).toEqual({ estimatedCost: 10 });
  });
});

describe('message cost append merge', () => {
  const cny = (amount: number): NonUsdCost => ({ currencyCode: 'CNY', amount, costSource: 'localEstimate' });

  it('USD adds; non-USD of the same currency adds, costSource taken from the first', () => {
    const merged = addMessageCost({ estimatedCost: 0.25, nonUsdCost: cny(0.1) }, { estimatedCost: 0.5, nonUsdCost: cny(0.02) });
    expect(merged.estimatedCost).toBeCloseTo(0.75, 10);
    expect(merged.nonUsdCost?.currencyCode).toBe('CNY');
    expect(merged.nonUsdCost?.costSource).toBe('localEstimate');
    expect(merged.nonUsdCost?.amount).toBeCloseTo(0.12, 10);
  });

  it('when one side lacks a non-USD part take the other; both missing -> nonUsdCost undefined', () => {
    expect(addMessageCost(undefined, { estimatedCost: 0.1, nonUsdCost: cny(2) })).toEqual({ estimatedCost: 0.1, nonUsdCost: cny(2) });
    expect(addMessageCost({ estimatedCost: 0, nonUsdCost: cny(2) }, { estimatedCost: 0.022 })).toEqual({ estimatedCost: 0.022, nonUsdCost: cny(2) });
    expect(addMessageCost({ estimatedCost: 0.1 }, { estimatedCost: 0.2 }).nonUsdCost).toBeUndefined();
  });

  it('different currencies -> {first currency, 0, unknown}, and later same-currency parts are no longer added', () => {
    const mixed = mergeNonUsdCost(cny(1), { currencyCode: 'EUR', amount: 2, costSource: 'localEstimate' });
    expect(mixed).toEqual({ currencyCode: 'CNY', amount: 0, costSource: 'unknown' });
    expect(mergeNonUsdCost(mixed, cny(3))).toEqual({ currencyCode: 'CNY', amount: 0, costSource: 'unknown' });
  });
});

describe('nonUsdCostTotalsEqual (the single comparison point for conversation totals)', () => {
  it('missing, an empty object and zero-amount currencies are equivalent', () => {
    expect(nonUsdCostTotalsEqual(undefined, {})).toBe(true);
    expect(nonUsdCostTotalsEqual({ CNY: 0 }, {})).toBe(true);
    expect(nonUsdCostTotalsEqual({ CNY: 0 }, undefined)).toBe(true);
  });

  it('differences within COST_EPSILON count as equal; beyond it or with a different currency they differ', () => {
    expect(nonUsdCostTotalsEqual({ CNY: 0.12 }, { CNY: 0.12 + 1e-7 })).toBe(true);
    expect(nonUsdCostTotalsEqual({ CNY: 0.12 }, { CNY: 0.13 })).toBe(false);
    expect(nonUsdCostTotalsEqual({ CNY: 0.12 }, { EUR: 0.12 })).toBe(false);
  });

  it('conversation recompute skips zero amounts and unavailable parts, consistent with the comparison rule', () => {
    const totals = recalculateConversationCostTotals([
      { state: 'delivered', estimatedCost: 0, nonUsdCost: { currencyCode: 'CNY', amount: 0, costSource: 'localEstimate' } },
      { state: 'delivered', estimatedCost: 0, nonUsdCost: { currencyCode: 'EUR', amount: 1, costSource: 'unknown' } },
    ] as unknown as ChatMessage[], null);
    expect(totals).toEqual({ estimatedCost: 0 });
    expect(nonUsdCostTotalsEqual(totals.nonUsdCostTotals, {})).toBe(true);
  });
});

describe('non-USD formatter is cached by locale|currency|digits', () => {
  it('repeated formatting with the same parameters is stable, and different locales / digits are not mixed up', () => {
    const first = formatCostTotals(0, { EUR: 1.5 }, 'de');
    expect(formatCostTotals(0, { EUR: 1.5 }, 'de')).toBe(first);
    expect(first).toBe(new Intl.NumberFormat('de', { style: 'currency', currency: 'EUR', minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(1.5));
    expect(formatCostTotals(0, { EUR: 1.5 }, 'en')).toBe(
      new Intl.NumberFormat('en', { style: 'currency', currency: 'EUR', minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(1.5),
    );
    expect(formatCostTotals(0, { EUR: 0.005 }, 'de')).toBe(
      new Intl.NumberFormat('de', { style: 'currency', currency: 'EUR', minimumFractionDigits: 4, maximumFractionDigits: 4 }).format(0.005),
    );
  });
});

describe('cost-currency.v1 relayPricingCases', () => {
  const RELAY = { kind: 'relay', baseURLText: 'https://relay.example.com/v1' } as const;
  // connection: 'official' -> the official connection of the provider that owns the matched entry (seeded under openAI).
  const OFFICIAL = { kind: 'openAI' } as const;
  // Relay model id for unmatched cases: not in the seeded official catalog.
  const UNMATCHED_ID = 'relay-private-model';

  afterEach(() => {
    __resetMetadataClientForTest();
  });

  // The matched entry enters the catalog through the production metadata-client decoder (default under openAI; cross-provider matching hits by id).
  async function seedOfficial(match: RelayPricingCase['catalogMatch'], providerKey = 'openAI') {
    const models = match
      ? {
          [match.canonicalModelId]: match.pricingV2
            ? {
                canonicalModelId: match.canonicalModelId,
                capabilities: ['text'],
                currencyCode: match.pricingV2.currencyCode,
                pricingStatus: match.pricingStatus ?? 'priced',
                pricingUnit: match.pricingUnit ?? 'per_token',
                ...(match.perUnitPrice != null ? { perUnitPrice: match.perUnitPrice } : {}),
                pricingV2: match.pricingV2,
              }
            : {
                canonicalModelId: match.canonicalModelId,
                capabilities: ['text'],
                pricingStatus: match.pricingStatus ?? 'unknown',
              },
        }
      : { 'official-other': { canonicalModelId: 'official-other', capabilities: ['text'] } };
    const data = {
      version: 1,
      contractVersion: 1,
      updatedAt: '2026-10-19T00:00:00Z',
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: { [providerKey]: { models } },
      providerConfigs: [],
    };
    await __seedMetadataCacheForTest({ data: JSON.parse(JSON.stringify(data)), timestamp: Date.now() });
    await initMetadata();
  }

  // The production Anthropic Messages parser consumes a stream where neither message_start nor message_delta carries usage,
  // and returns the last usage event it emitted (undefined if none).
  function usageParsedFromStreamWithoutUsage() {
    const ctx = createStreamContext();
    const chunks: Array<[string, Record<string, unknown>]> = [
      ['message_start', { type: 'message_start', message: { id: 'msg_1' } }],
      ['content_block_delta', { type: 'content_block_delta', delta: { type: 'text_delta', text: 'hi' } }],
      ['message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn' } }],
      ['message_stop', { type: 'message_stop' }],
    ];
    let usage: Parameters<typeof deriveCostFields>[0];
    for (const [eventType, chunk] of chunks) {
      const out = anthropicMessagesStrategy.parseStreamChunk(eventType, JSON.stringify(chunk), ctx, null);
      for (const event of out == null ? [] : Array.isArray(out) ? out : [out]) {
        if (event.type === 'usage') usage = event.usage;
      }
    }
    return usage;
  }

  // n image attachments produced this turn (the count goes through production generatedImageUnits).
  function producedImages(count: number) {
    return Array.from({ length: count }, (_, index) => ({
      id: `img-${index}`, kind: 'image' as const, fileName: `${index}.png`, mimeType: 'image/png', localImageID: `l${index}`,
    }));
  }

  // The upstream reported only the actual cost and no tokens (usage null + upstreamCost): take what the production proxy parser emits for a usage frame that carries only cost.
  function usageParsedFromCostOnlyFrame(amount: number) {
    const raw = { prompt_tokens: 0, completion_tokens: 0, cost: amount };
    const parsed = createProxyChunkParser('openRouter')(null, JSON.stringify({ choices: [{ delta: {} }], usage: raw }));
    const events = (Array.isArray(parsed) ? parsed : [parsed]) as StreamEvent[];
    const event = events.find((item) => item?.type === 'usage');
    if (event?.type !== 'usage') throw new Error('production parser emitted no usage');
    return event.usage;
  }

  function webExpectSource(source: RelayPricingCase['expect']['costSource']) {
    return source === 'upstream' ? 'upstream' : webSource(source);
  }

  for (const entry of fixture.relayPricingCases) {
    it(`COST_CURRENCY_${entry.id}`, async () => {
      await seedOfficial(entry.catalogMatch);
      const canonicalId = entry.catalogMatch?.canonicalModelId;
      const model = {
        id: entry.relayModelId ?? canonicalId ?? UNMATCHED_ID,
        ...(entry.relayModelId && canonicalId ? { canonicalModelId: canonicalId } : {}),
        name: 'Relay Model',
        ...(entry.localPrice
          ? {
              promptPrice: entry.localPrice.inputPerMToken / 1_000_000,
              completionPrice: entry.localPrice.outputPerMToken / 1_000_000,
            }
          : {}),
      } as unknown as AIModel;
      const u = entry.usage;
      // usage null = the upstream reported no usage: take what the production parser actually emits for a stream without usage, never synthesized in the test.
      const usage = u
        ? {
            prompt_tokens: u.uncachedInputTokens + u.cacheReadTokens + u.cacheWrite5mTokens + u.cacheWrite1hTokens,
            completion_tokens: u.outputTokens,
            breakdown: {
              promptTokens: u.uncachedInputTokens,
              cachedInputTokens: u.cacheReadTokens,
              cacheCreation5mTokens: u.cacheWrite5mTokens,
              cacheCreation1hTokens: u.cacheWrite1hTokens,
              completionTokens: u.outputTokens,
              reasoningTokens: 0,
              cacheReadObserved: true,
              cacheWriteObserved: true,
              ...(entry.upstreamCost ? { upstreamCost: entry.upstreamCost.amount } : {}),
            },
          }
        : entry.upstreamCost
          ? usageParsedFromCostOnlyFrame(entry.upstreamCost.amount)
          : usageParsedFromStreamWithoutUsage();
      // The pricing instant comes from the fixture's at, never the wall clock; the unit count comes from the production counter (image attachments produced this turn) and is not handed to the estimate entry directly.
      const fields = deriveCostFields(
        usage,
        model,
        entry.connection === 'official' ? OFFICIAL : RELAY,
        () => new Date(entry.at),
        entry.units == null ? undefined : generatedImageUnits(producedImages(entry.units)),
      );
      expect(fields.cost).toBeCloseTo(entry.expect.estimatedCost, 10);
      expect(fields.costSource).toBe(webExpectSource(entry.expect.costSource));
      const nonUsd = webNonUsd(entry.expect.nonUsdCost);
      if (nonUsd) {
        expect(fields.nonUsdCost?.currencyCode).toBe(nonUsd.currencyCode);
        expect(fields.nonUsdCost?.costSource).toBe(nonUsd.costSource);
        expect(fields.nonUsdCost?.amount).toBeCloseTo(nonUsd.amount, 10);
      } else {
        expect('nonUsdCost' in fields).toBe(false);
      }
    });
  }

  // Multi-leg messages: each leg goes through the production multi-leg merge entry (mergeToolLoopUsage, shared by tool loop / tail leg)
  // and the merged usage is handed to the same estimate entry deriveCostFields; the first leg takes its usage directly (same as the tool loop).
  // Legs with different prices (legs on different entries): each leg is estimated through the same entry with its own entry, then handed to production per-currency summing sumLegCostFields.
  // Subscription connection: the delivery layer decides the whole-message subscription once from the connection's authMode.
  // Leg usage is produced by the production leg parser: Relay does not adopt actual upstream cost, so these run on an official connection that reports usage.cost (OpenRouter),
  // and each leg's usage is an OpenRouter raw usage frame run through the production proxy parser.
  describe('multiLegCostCases', () => {
    const OPEN_ROUTER = { kind: 'openRouter' } as const;

    function legUsageParsed(usage: FixtureUsage, upstreamCost: { amount: number } | null) {
      // OpenRouter only distinguishes cache reads and 1h writes (cache_write_tokens); the fixture's multi-leg cases have no 5m writes.
      expect(usage.cacheWrite5mTokens).toBe(0);
      const raw = {
        prompt_tokens: usage.uncachedInputTokens + usage.cacheReadTokens + usage.cacheWrite1hTokens,
        completion_tokens: usage.outputTokens,
        prompt_tokens_details: { cached_tokens: usage.cacheReadTokens, cache_write_tokens: usage.cacheWrite1hTokens },
        ...(upstreamCost ? { cost: upstreamCost.amount } : {}),
      };
      const parsed = createProxyChunkParser('openRouter')(null, JSON.stringify({ choices: [{ delta: {} }], usage: raw }));
      const events = (Array.isArray(parsed) ? parsed : [parsed]) as StreamEvent[];
      const event = events.find((item) => item?.type === 'usage');
      if (event?.type !== 'usage') throw new Error('production parser emitted no usage');
      return event.usage;
    }

    for (const entry of fixture.multiLegCostCases) {
      it(`COST_CURRENCY_${entry.id}`, async () => {
        const canonicalModelId = 'multi-leg-model';
        const connection = entry.connection === 'subscription'
          ? { ...OPEN_ROUTER, authMode: 'subscription' as const }
          : entry.connection === 'relay' ? RELAY : OPEN_ROUTER;
        // Relay is priced by the matched official entry (seeded under openAI like relayPricingCases); the rest are seeded under OpenRouter.
        const catalogProvider = entry.connection === 'relay' ? 'openAI' : 'openRouter';
        const model = { id: canonicalModelId, name: 'Multi-leg Model' } as unknown as AIModel;
        // usage null but an actual upstream cost was reported (per-unit case): take what the production parser emits for a usage frame carrying only cost.
        const legs = entry.legs.map((leg) => {
          if (leg.usage) return legUsageParsed(leg.usage, leg.upstreamCost);
          return leg.upstreamCost ? usageParsedFromCostOnlyFrame(leg.upstreamCost.amount) : undefined;
        });
        const merged = legs.slice(1).reduce((acc, leg) => mergeToolLoopUsage(acc, leg), legs[0]);
        const at = () => new Date(entry.at);
        // Per-unit pricing is counted once for the whole message: the unit count comes from the production counter and goes to the whole-message estimate entry, not per leg.
        const units = entry.units == null ? undefined : generatedImageUnits(producedImages(entry.units));
        let fields;
        if (entry.legs.some((leg) => leg.pricingV2)) {
          const records = [];
          for (const [index, leg] of entry.legs.entries()) {
            __resetMetadataClientForTest();
            await seedOfficial({ canonicalModelId, pricingV2: leg.pricingV2 ?? entry.pricingV2 }, 'openRouter');
            records.push(deriveCostFields(legs[index], model, connection, at, undefined));
          }
          fields = sumLegCostFields(deriveCostFields(merged, model, connection, at, undefined), records);
        } else {
          await seedOfficial({ canonicalModelId, pricingV2: entry.pricingV2 }, catalogProvider);
          fields = deriveCostFields(merged, model, connection, at, units);
        }
        expect(fields.cost).toBeCloseTo(entry.expect.estimatedCost, 10);
        expect(fields.costSource).toBe(entry.expect.costSource === 'subscription' || entry.expect.costSource === 'upstream'
          ? entry.expect.costSource
          : webSource(entry.expect.costSource));
        const nonUsd = webNonUsd(entry.expect.nonUsdCost);
        if (nonUsd) {
          expect(fields.nonUsdCost).toEqual(nonUsd);
        } else {
          expect('nonUsdCost' in fields).toBe(false);
        }
      });
    }
  });
});
