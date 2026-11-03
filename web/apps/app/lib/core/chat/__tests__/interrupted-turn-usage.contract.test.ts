import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { AIModel } from '@oriveo/shared';
import type { StreamUsage } from '@oriveo/core/providers/types';
import { mergeToolLoopUsage } from '@oriveo/core/tools/tool-call-loop';
import { accumulatedSettlementTokens, interruptedTurnUsage } from '../interrupted-turn-usage';
import { deriveCostFields, mergeMessageUsageFields } from '../cost-fields';
import { textAfter } from '../operations-send';
import { managedSettlementTokenFields } from '../../managed/chat-stream';

/**
 * Shared fixture interrupted-turn.v1: non-managed paths (byok / trial) go through the
 * production leg split, estimate and cost derivation; managed cases go through the production settlement mapping
 * and the production accumulation onto the message's existing tokens.
 */

interface FixtureCase {
  id: string;
  path: 'byok' | 'trial' | 'managed';
  input: {
    estimatedInput?: number | null;
    rhoHi?: number;
    visibleText?: string;
    reasoningText?: string;
    skillManifestTokens?: number | null;
    finishedLegs?: Array<{ inputTokens: number; outputTokens: number; usageReported: boolean }>;
    shownBefore?: string;
    existing?: { inputTokens?: number; outputTokens?: number };
    settlement?: {
      status: string;
      normal_input_tokens?: number;
      cache_read_input_tokens?: number;
      cache_creation_input_tokens?: number;
      output_tokens?: number;
      usage_source?: string;
    };
  };
  expect: {
    recorded: boolean;
    inputTokens: number | null;
    outputTokens: number | null;
    costSource?: string;
    skillManifestTokens?: number | null;
    cachedInputTokens?: number | null;
    cacheCreationInputTokens?: number | null;
  };
}

const fixture = JSON.parse(readFileSync(
  resolve(__dirname, '../../../../../../../../\u5171\u4eab/test-fixtures/provider-usage/interrupted-turn.v1.json'),
  'utf8',
)) as { cases: FixtureCase[] };

const PRICED_AT = () => new Date('2026-11-02T12:00:00Z');
const PRICED_MODEL = {
  id: 'priced-model',
  name: 'Priced Model',
  promptPrice: 0.000_001,
  completionPrice: 0.000_002,
} as unknown as AIModel;

function finishedLegsUsage(legs: FixtureCase['input']['finishedLegs']): StreamUsage | undefined {
  let merged: StreamUsage | undefined;
  for (const leg of legs ?? []) {
    const usage: StreamUsage = {
      prompt_tokens: leg.inputTokens,
      completion_tokens: leg.outputTokens,
      total_tokens: leg.inputTokens + leg.outputTokens,
    };
    merged = merged ? mergeToolLoopUsage(merged, usage) : usage;
  }
  return merged;
}

const caseName = (id: string) => `interrupted_turn_${id.replace(/-/g, '_')}`;

function runManagedCase(fixtureCase: FixtureCase): void {
  const { input, expect: want } = fixtureCase;
  const raw = input.settlement;
  // A pending cancel status carries no settlement object.
  const settlement = raw && raw.status === 'completed'
    ? {
        normalInputTokens: raw.normal_input_tokens,
        cacheReadInputTokens: raw.cache_read_input_tokens,
        cacheCreationInputTokens: raw.cache_creation_input_tokens,
        outputTokens: raw.output_tokens,
        usageSource: raw.usage_source,
      }
    : undefined;
  const existing = { ...(input.existing ?? {}) };
  const written = accumulatedSettlementTokens(existing, managedSettlementTokenFields(settlement));
  expect(written !== undefined).toBe(want.recorded);
  const fields: Record<string, number | undefined> = { ...existing, ...written };
  expect(fields.inputTokens ?? null).toBe(want.inputTokens);
  expect(fields.outputTokens ?? null).toBe(want.outputTokens);
  expect(fields.cachedInputTokens ?? null).toBe(want.cachedInputTokens ?? null);
  expect(fields.cacheCreationInputTokens ?? null).toBe(want.cacheCreationInputTokens ?? null);
  if (written) {
    // The same settlement is applied once: a completed message takes no second write.
    const settled = { ...fields, managedSettlementStatus: 'completed' as const };
    expect(accumulatedSettlementTokens(settled, managedSettlementTokenFields(settlement))).toBeUndefined();
  }
}

function runEstimatedCase(fixtureCase: FixtureCase): void {
  const { input, expect: want } = fixtureCase;
  const usage = interruptedTurnUsage({
    estimatedInput: input.estimatedInput,
    rhoHi: input.rhoHi ?? 0,
    visibleText: textAfter(input.visibleText ?? '', input.shownBefore),
    reasoningText: input.reasoningText ?? '',
    finishedLegs: finishedLegsUsage(input.finishedLegs),
  });
  expect(usage !== undefined).toBe(want.recorded);
  const cost = deriveCostFields(usage, PRICED_MODEL, { kind: 'relay' }, PRICED_AT, undefined);
  const manifest = usage ? input.skillManifestTokens ?? undefined : undefined;
  const fields = mergeMessageUsageFields({}, cost, manifest);
  expect(fields.inputTokens ?? null).toBe(want.inputTokens);
  expect(fields.outputTokens ?? null).toBe(want.outputTokens);
  expect(cost.costSource).toBe(want.costSource);
  expect(fields.skillManifestTokens ?? null).toBe(want.skillManifestTokens ?? null);
}

describe('InterruptedTurnUsageContract', () => {
  const cases = fixture.cases;

  it('covers the fixture cases', () => {
    expect(cases.map((c) => c.id)).toEqual(expect.arrayContaining([
      'stopped-with-text', 'stopped-before-output', 'stopped-before-output-after-reported-leg', 'trial-stopped-with-text',
      'stopped-without-input-estimate-after-reported-leg', 'stopped-after-leg-separator', 'managed-stopped-settled',
      'managed-stopped-pending', 'managed-stopped-settled-upstream-cache', 'managed-stopped-settled-continue',
    ]));
  });

  for (const fixtureCase of cases) {
    it(caseName(fixtureCase.id), () => {
      if (fixtureCase.path === 'managed') runManagedCase(fixtureCase);
      else runEstimatedCase(fixtureCase);
    });
  }
});
