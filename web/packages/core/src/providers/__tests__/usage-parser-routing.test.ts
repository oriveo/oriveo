/**
 * Drift gate for how usage parsing is **routed** across the 15 official providers.
 *
 * Division of labour with `transport/usage-parsers.test.ts`: that file tests the parser functions
 * themselves (given these fields, what do they compute), this one tests the **production route**,
 * that is whether a given providerKind actually reaches the parser it is supposed to reach at the
 * real decode entry point `createProxyChunkParser`.
 *
 * Why the two have to be tested separately: green parser unit tests do not prove the parser is used
 * in production. Qwen is the live example. `parseUsageQwen` has a nested-first, top-level-fallback
 * pair and its unit assertions pass, but `pickProxyUsageParser` had no qwen branch, so it fell
 * through to default and used the OpenAI template, and the top-level `cached_tokens` of the Beijing
 * region qwen3-vl-plus was dropped all the way through production while the tests stayed green.
 *
 * Two hard constraints:
 *  1. The key set of the contract table must be **exactly equal** to the 15 official providers in
 *     `PROVIDER_KINDS`. Adding one without declaring its shape here turns red instead of silently
 *     falling through to the default OpenAI template.
 *  2. Every assertion target comes from the StreamEvent that `createProxyChunkParser` produces when
 *     fed a real wire frame, not from calling a parser directly and synthesizing the event.
 */
import { describe, expect, it } from 'vitest';
import { PROVIDER_KINDS, isAggregatedProvider, type ProviderKind } from '@oriveo/shared';
import { createProxyChunkParser, pickProxyUsageParser } from '../proxy-chunk-parser';
import type { StreamEvent } from '../types';
import type { UsageBreakdown } from '../../chat/usage-breakdown';
import {
  parseUsageDeepSeek,
  parseUsageGrok,
  parseUsageMoonshot,
  parseUsageOpenAI,
  parseUsageOpenAICompatible,
  parseUsageOpenRouter,
  parseUsageQwen,
} from '../transport/usage-parsers';

/** One wire frame: an `eventType` of null means the OpenAI-compatible top-level chunk branch. */
interface WireFrame {
  eventType: string | null;
  chunk: Record<string, unknown>;
}

interface ProviderUsageContract {
  /**
   * How this provider's usage is routed to a parser:
   * - `pickProxyUsageParser`: decided by providerKind, and the assertions below check the identity
   *   of the function it returns;
   * - `dedicated-chunk-branch`: decided by the chunk shape (Anthropic's message_delta, Gemini's
   *   usageMetadata), **independent of providerKind**, so a providerKind routing assertion would be
   *   vacuous for them. Labelled honestly rather than pretending to cover it.
   */
  routedVia: 'pickProxyUsageParser' | 'dedicated-chunk-branch';
  /** With routedVia = pickProxyUsageParser, the parser function this kind must resolve to. */
  expectedParser?: (usage: Record<string, unknown>) => UsageBreakdown;
  /** Path of the cache read field in this provider's wire frame, kept here as readable documentation. */
  cacheReadPath: string;
  /** Frame sequence where the upstream **explicitly reports** a cache read of 0. */
  observedZero: WireFrame[];
  /** Frame sequence with the same shape but the cache field missing entirely. */
  cacheFieldAbsent: WireFrame[];
  /** Expected breakdown on a positive cache hit (only the fields of interest are asserted). */
  positive: { frames: WireFrame[]; expect: Record<string, number | boolean> };
}

/** OpenAI Chat Completions compatible shape, shared by the six B-tier providers plus Mistral. */
function openAICompatible(cached: number | undefined): WireFrame[] {
  const usage: Record<string, unknown> = { prompt_tokens: 1000, completion_tokens: 120 };
  if (cached !== undefined) usage.prompt_tokens_details = { cached_tokens: cached };
  return [{ eventType: null, chunk: { choices: [], usage } }];
}

const OPENAI_COMPATIBLE: ProviderUsageContract = {
  routedVia: 'pickProxyUsageParser',
  expectedParser: parseUsageOpenAICompatible,
  cacheReadPath: 'usage.prompt_tokens_details.cached_tokens',
  observedZero: openAICompatible(0),
  cacheFieldAbsent: openAICompatible(undefined),
  positive: {
    frames: openAICompatible(900),
    expect: { promptTokens: 100, cachedInputTokens: 900, completionTokens: 120, cacheReadObserved: true },
  },
};

/** Anthropic splits usage across two frames: message_start carries input/cache, message_delta carries output. */
function anthropic(cacheRead: number | undefined): WireFrame[] {
  const usage: Record<string, unknown> = { input_tokens: 100 };
  if (cacheRead !== undefined) usage.cache_read_input_tokens = cacheRead;
  return [
    { eventType: 'message_start', chunk: { type: 'message_start', message: { usage } } },
    { eventType: 'message_delta', chunk: { type: 'message_delta', usage: { output_tokens: 120 } } },
  ];
}

function gemini(cached: number | undefined): WireFrame[] {
  const usageMetadata: Record<string, unknown> = {
    promptTokenCount: 1000,
    candidatesTokenCount: 100,
    thoughtsTokenCount: 20,
  };
  if (cached !== undefined) usageMetadata.cachedContentTokenCount = cached;
  return [{ eventType: null, chunk: { usageMetadata } }];
}

function deepseek(hit: number | undefined): WireFrame[] {
  const usage: Record<string, unknown> = { prompt_tokens: 1000, completion_tokens: 120 };
  if (hit !== undefined) {
    usage.prompt_cache_hit_tokens = hit;
    usage.prompt_cache_miss_tokens = 1000 - hit;
  }
  return [{ eventType: null, chunk: { choices: [], usage } }];
}

function moonshot(cached: number | undefined): WireFrame[] {
  const usage: Record<string, unknown> = { prompt_tokens: 1000, completion_tokens: 120 };
  if (cached !== undefined) usage.cached_tokens = cached;
  return [{ eventType: null, chunk: { choices: [], usage } }];
}

/** Qwen Beijing region: `cached_tokens` sits at the **top level** of usage, not under prompt_tokens_details. */
function qwenBeijing(cached: number | undefined): WireFrame[] {
  const usage: Record<string, unknown> = { input_tokens: 1000, output_tokens: 120 };
  if (cached !== undefined) usage.cached_tokens = cached;
  return [{ eventType: null, chunk: { choices: [], usage } }];
}

function openRouter(cached: number | undefined): WireFrame[] {
  const usage: Record<string, unknown> = { prompt_tokens: 1000, completion_tokens: 120, cost: 0.0042 };
  if (cached !== undefined) usage.prompt_tokens_details = { cached_tokens: cached };
  return [{ eventType: null, chunk: { choices: [], usage } }];
}

function grok(cached: number | undefined): WireFrame[] {
  const usage: Record<string, unknown> = {
    prompt_tokens: 1000,
    completion_tokens: 120,
    cost_in_usd_ticks: 37_756_000,
  };
  if (cached !== undefined) usage.prompt_tokens_details = { cached_tokens: cached };
  return [{ eventType: null, chunk: { choices: [], usage } }];
}

/**
 * Production wire shape contract for the 15 official providers. **A new provider must be added
 * here**: the first it below reconciles against PROVIDER_KINDS and turns red on an omission.
 */
const CONTRACTS: Record<string, ProviderUsageContract> = {
  openAI: { ...OPENAI_COMPATIBLE, expectedParser: parseUsageOpenAI },
  anthropic: {
    routedVia: 'dedicated-chunk-branch',
    cacheReadPath: 'usage.cache_read_input_tokens',
    observedZero: anthropic(0),
    cacheFieldAbsent: anthropic(undefined),
    positive: {
      frames: anthropic(900),
      // Anthropic's input_tokens already **excludes** cache, so promptTokens is exactly 100.
      expect: { promptTokens: 100, cachedInputTokens: 900, completionTokens: 120, cacheReadObserved: true },
    },
  },
  gemini: {
    routedVia: 'dedicated-chunk-branch',
    cacheReadPath: 'usageMetadata.cachedContentTokenCount',
    observedZero: gemini(0),
    cacheFieldAbsent: gemini(undefined),
    positive: {
      frames: gemini(900),
      // completionTokens = candidates + thoughts (observed 2026-05-17), reasoning is thoughts.
      expect: { promptTokens: 100, cachedInputTokens: 900, completionTokens: 120, reasoningTokens: 20, cacheReadObserved: true },
    },
  },
  openRouter: {
    routedVia: 'pickProxyUsageParser',
    expectedParser: parseUsageOpenRouter,
    cacheReadPath: 'usage.prompt_tokens_details.cached_tokens',
    observedZero: openRouter(0),
    cacheFieldAbsent: openRouter(undefined),
    positive: {
      frames: openRouter(900),
      // upstreamCost is the only field that tells parseUsageOpenRouter apart from the default
      // OpenAI template: the three token counts come out identical under both, so asserting them alone tests nothing about routing.
      expect: { promptTokens: 100, cachedInputTokens: 900, completionTokens: 120, cacheReadObserved: true, upstreamCost: 0.0042 },
    },
  },
  deepseek: {
    routedVia: 'pickProxyUsageParser',
    expectedParser: parseUsageDeepSeek,
    cacheReadPath: 'usage.prompt_cache_hit_tokens',
    observedZero: deepseek(0),
    cacheFieldAbsent: deepseek(undefined),
    positive: {
      frames: deepseek(900),
      // hit + miss is prompt_tokens, and promptTokens takes miss.
      expect: { promptTokens: 100, cachedInputTokens: 900, completionTokens: 120, cacheReadObserved: true },
    },
  },
  grok: {
    routedVia: 'pickProxyUsageParser',
    expectedParser: parseUsageGrok,
    cacheReadPath: 'usage.prompt_tokens_details.cached_tokens',
    observedZero: grok(0),
    cacheFieldAbsent: grok(undefined),
    positive: {
      frames: grok(900),
      expect: { promptTokens: 100, cachedInputTokens: 900, completionTokens: 120, cacheReadObserved: true },
    },
  },
  mistral: OPENAI_COMPATIBLE,
  groq: OPENAI_COMPATIBLE,
  togetherAI: OPENAI_COMPATIBLE,
  fireworksAI: OPENAI_COMPATIBLE,
  miniMax: OPENAI_COMPATIBLE,
  zhipu: OPENAI_COMPATIBLE,
  qwen: {
    routedVia: 'pickProxyUsageParser',
    expectedParser: parseUsageQwen,
    cacheReadPath: 'usage.prompt_tokens_details.cached_tokens ?? usage.cached_tokens (Beijing region, top level)',
    observedZero: qwenBeijing(0),
    cacheFieldAbsent: qwenBeijing(undefined),
    positive: {
      frames: qwenBeijing(900),
      expect: { promptTokens: 100, cachedInputTokens: 900, completionTokens: 120, cacheReadObserved: true },
    },
  },
  moonshot: {
    routedVia: 'pickProxyUsageParser',
    expectedParser: parseUsageMoonshot,
    cacheReadPath: 'usage.cached_tokens (top level, not under prompt_tokens_details)',
    observedZero: moonshot(0),
    cacheFieldAbsent: moonshot(undefined),
    positive: {
      frames: moonshot(900),
      expect: { promptTokens: 100, cachedInputTokens: 900, completionTokens: 120, cacheReadObserved: true },
    },
  },
  siliconFlow: OPENAI_COMPATIBLE,
};

const OFFICIAL_KINDS = PROVIDER_KINDS.filter(isAggregatedProvider);

/** Feed real wire frames into the production decode entry point and take the breakdown of the last usage event it emits. */
function decodeBreakdown(kind: ProviderKind, frames: WireFrame[]): UsageBreakdown {
  const parser = createProxyChunkParser(kind);
  let last: Extract<StreamEvent, { type: 'usage' }> | undefined;
  for (const frame of frames) {
    const out = parser(frame.eventType, JSON.stringify(frame.chunk));
    const events = out == null ? [] : Array.isArray(out) ? out : [out];
    for (const event of events) {
      if (event.type === 'usage') last = event;
    }
  }
  if (!last) throw new Error(`${kind}: the production decode entry point emitted no usage event`);
  // A missing breakdown is itself the defect (deriveCostFields falls back to an estimate and the
  // cache discount is lost), so fail here instead of letting the assertion degrade to an undefined comparison.
  if (!last.usage.breakdown) throw new Error(`${kind}: the usage event carries no breakdown`);
  return last.usage.breakdown;
}

describe('usage routing drift gate for the 15 official providers', () => {
  it('the contract table covers exactly the official providers in PROVIDER_KINDS', () => {
    // Derived from PROVIDER_KINDS rather than copying the list of 15 into the test: with a copy,
    // adding a provider would be missed on both sides and the gate would not exist.
    expect(Object.keys(CONTRACTS).sort()).toEqual([...OFFICIAL_KINDS].sort());
    // relay uses a user-defined envelope, not a first-party usage parser
    expect(PROVIDER_KINDS.length - OFFICIAL_KINDS.length).toBe(1);
  });

  // Asserting breakdown values alone does not exercise the routing: for most providers the fixture
  // yields identical token counts under the default OpenAI template (openRouter is exactly like
  // that). So for the kinds routed by providerKind, assert the **identity** of the function
  // pickProxyUsageParser returns.
  it.each(OFFICIAL_KINDS.filter((kind) => CONTRACTS[kind].routedVia === 'pickProxyUsageParser'))(
    '%s: pickProxyUsageParser resolves to the agreed parser',
    (kind) => {
      expect(pickProxyUsageParser(kind)).toBe(CONTRACTS[kind].expectedParser);
    },
  );

  it('Anthropic / Gemini are handled by the chunk shape branch and never routed by providerKind', () => {
    const byChunkShape = OFFICIAL_KINDS.filter((k) => CONTRACTS[k].routedVia === 'dedicated-chunk-branch');
    expect([...byChunkShape].sort()).toEqual(['anthropic', 'gemini']);
    // Falling through to the pickProxyUsageParser default is harmless for them, since production
    // never reaches that return value, but this assertion pins the harmlessness down: it turns red
    // the day someone adds a case for them while the branch is still there.
    byChunkShape.forEach((kind) => {
      expect(pickProxyUsageParser(kind)).toBe(parseUsageOpenAICompatible);
    });
  });

  it.each(OFFICIAL_KINDS)('%s: the cache portion enters the breakdown and is not double counted in promptTokens', (kind) => {
    const contract = CONTRACTS[kind];
    expect(decodeBreakdown(kind, contract.positive.frames)).toMatchObject(contract.positive.expect);
  });

  it.each(OFFICIAL_KINDS)('%s: an explicitly reported 0 counts as observed, only a missing field is unobserved', (kind) => {
    const contract = CONTRACTS[kind];

    const observed = decodeBreakdown(kind, contract.observedZero);
    expect(observed.cachedInputTokens, `${kind} @ ${contract.cacheReadPath}`).toBe(0);
    expect(observed.cacheReadObserved, `${kind} @ ${contract.cacheReadPath}`).toBe(true);

    const absent = decodeBreakdown(kind, contract.cacheFieldAbsent);
    expect(absent.cacheReadObserved, `${kind} @ ${contract.cacheReadPath}`).toBe(false);
  });
});
