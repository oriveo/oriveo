// @vitest-environment jsdom
//
// Relay reasoning tiers (fixture shared/test-fixtures/relay/reasoning-tier.v1.json).
// The three fixture sections go case by case (effort / classify / fallback), with test names like RELAY-TIER-<section>-<caseId>.
// There is also RELAY-TIER-in-send-retry: on the production send path (rejection loop -> sendRelayStream) the tier is snapped and resent within the same send.

import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { sendRelayStream, type RelayOrchestratorDeps } from '@oriveo/core/providers/relay-orchestrator';
import type { StreamEvent, StreamOptions } from '../../providers/types';
import { __resetMetadataClientForTest, lookupModelFamilyByModel } from '../../metadata/metadata-client';
import {
  classifyRelayReasoningTierRejection,
  relayReasoningTierFallback,
  relayReasoningTiersFromEfforts,
  relayRejectedReasoningTiers,
  relayReasoningTierCacheKey,
} from '../relay-reasoning-tiers';
import { sendWithRelayRejectionLoop } from '../relay-rejection-loop';
import { recordRelayReasoningTierRejection } from '../relay-reasoning-tiers';
import { createAppStore } from '../../store/app-store';
import { setRelayReasoningLevels } from '../../relay-model-advanced-ops';
import { buildProviderStreamOptions, filterRequestCapabilityIntent } from '../stream-options';

type Fixture = {
  effortCases: Array<{ caseId: string; efforts: string[]; expect: string[] }>;
  classifyCases: Array<{
    caseId: string; transport: string; status: number; body: string;
    sentTier: string | null; outputStarted: boolean; expect: string | null;
  }>;
  fallbackCases: Array<{ caseId: string; available: string[]; rejected: string[]; selected: string; expect: string | null }>;
};

const fixture: Fixture = (() => {
  let dir = process.cwd();
  while (true) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'reasoning-tier.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as Fixture;
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error('reasoning-tier.v1.json not found');
    dir = parent;
  }
})();

describe('RELAY-TIER effort', () => {
  it.each(fixture.effortCases.map((item) => [item.caseId, item] as const))('RELAY-TIER-effort-%s', (_caseId, item) => {
    expect(relayReasoningTiersFromEfforts(item.efforts)).toEqual(item.expect);
  });
});

describe('RELAY-TIER classify', () => {
  it.each(fixture.classifyCases.map((item) => [item.caseId, item] as const))('RELAY-TIER-classify-%s', (_caseId, item) => {
    expect(classifyRelayReasoningTierRejection({
      status: item.status, body: item.body, sentTier: item.sentTier, outputStarted: item.outputStarted,
    })).toBe(item.expect);
  });
});

describe('RELAY-TIER fallback', () => {
  it.each(fixture.fallbackCases.map((item) => [item.caseId, item] as const))('RELAY-TIER-fallback-%s', (_caseId, item) => {
    expect(relayReasoningTierFallback(item.available, item.rejected, item.selected)).toBe(item.expect);
  });
});

/* ── Snapping within a send ─────────────────────────────────────────── */

function relayProvider(): Provider {
  return {
    id: 'relay-tier', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [],
    apiKey: 'sk-relay', apiKeyPreview: 'sk-…', baseURLText: 'https://relay.example',
    relayRequested: {
      authMode: 'bearer', securityMode: 'remote_https', transport: 'openai_responses',
      resolvedAPIBaseURL: 'https://relay.example/v1',
    },
  } as unknown as Provider;
}

const gpt: AIModel = {
  id: 'gpt-5', name: 'gpt-5', capabilities: ['text'], reasoningModeAvailable: false,
  isAvailable: true, isDefault: false, priceTier: '',
} as AIModel;

async function drain(stream: ReadableStream<StreamEvent>): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  const reader = stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) return events;
    events.push(value);
  }
}

beforeEach(() => {
  localStorage.clear();
  __resetMetadataClientForTest();
});

afterEach(() => {
  localStorage.clear();
  __resetMetadataClientForTest();
  vi.unstubAllGlobals();
});

describe('RELAY-TIER in-send', () => {
  it('RELAY-TIER-in-send-retry Responses selects max, upstream 400 -> the second request body in the same send has reasoning.effort set to the deep tier value, and the negative cache records max', async () => {
    // model-facts (by-model view) gives four tiers; the auto set = fast / balanced / deep / max.
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      data: { revision: 'r1', byModel: { 'gpt-5': { family: 'openai', providerKind: 'openAI', facts: { reasoningEfforts: ['low', 'medium', 'high', 'xhigh'] } } } },
    }), { status: 200 })));
    expect(await lookupModelFamilyByModel('gpt-5')).toBe('openai');

    const rejection = fixture.classifyCases[0]!;
    const provider = relayProvider();
    const bodies: Array<Record<string, unknown>> = [];
    const deps: RelayOrchestratorDeps = {
      transport: {
        fetch: async (_url, init) => {
          bodies.push(JSON.parse(String(init.body)) as Record<string, unknown>);
          if (bodies.length === 1) {
            return new Response(rejection.body, { status: rejection.status, headers: { 'Content-Type': 'application/json' } });
          }
          return new Response('event: response.output_text.delta\ndata: {"delta":"ok"}\n\ndata: [DONE]\n\n', {
            status: 200, headers: { 'Content-Type': 'text/event-stream' },
          });
        },
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    };
    const streamOptions = buildProviderStreamOptions(provider, { reasoning: 'max' } as StreamOptions, gpt);
    const handle = sendWithRelayRejectionLoop({
      store: {} as never,
      provider,
      model: gpt,
      history: [{ role: 'user', content: 'hello' }],
      streamOptions,
      send: (history, options) => sendRelayStream(provider.apiKey, gpt.id, history, provider.baseURLText, options, deps),
      resolveCandidates: async () => [],
    });
    const events = await drain(handle.stream);

    expect(bodies).toHaveLength(2);
    expect((bodies[0]!.reasoning as { effort?: string }).effort).toBe('xhigh');
    expect((bodies[1]!.reasoning as { effort?: string }).effort).toBe('high');
    expect(events.some((event) => event.type === 'error')).toBe(false);
    expect(relayRejectedReasoningTiers(relayReasoningTierCacheKey(provider, gpt))).toEqual(['max']);

    // Later sends: the outbound gate uses the same snapping function, so selecting max sends deep directly.
    const later = filterRequestCapabilityIntent({
      provider, model: gpt, reasoningMode: 'automatic', webSearchEnabled: false,
      streamOptions: buildProviderStreamOptions(provider, { capabilityPreferences: { web: 'off', reasoningIntent: 'max' } } as StreamOptions, gpt),
    });
    expect(later.reasoning).toBe('deep');
    expect(later.capabilityPreferences?.reasoningIntent).toBe('deep');
  });
});

describe('RELAY-TIER clear', () => {
  it('when the user changes the reasoning tier override, the tier rejection record of that model is cleared', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({
      data: { revision: 'r1', byModel: { 'gpt-5': { family: 'openai', providerKind: 'openAI', facts: { reasoningEfforts: ['low', 'medium', 'high', 'xhigh'] } } } },
    }), { status: 200 })));
    await lookupModelFamilyByModel('gpt-5');
    const store = createAppStore();
    const provider = { ...relayProvider(), models: [gpt], catalogModels: [gpt] } as Provider;
    store.getState().addProvider(provider);
    const key = relayReasoningTierCacheKey(provider, gpt)!;
    recordRelayReasoningTierRejection(key, 'max');
    expect(relayRejectedReasoningTiers(key)).toEqual(['max']);
    expect(setRelayReasoningLevels(store, provider.id, gpt.id, ['fast', 'balanced', 'deep'])).toBe(true);
    expect(relayRejectedReasoningTiers(key)).toEqual([]);
  });
});
