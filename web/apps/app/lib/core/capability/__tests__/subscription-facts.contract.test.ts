// @vitest-environment jsdom
//
// Subscription-form input projection and reasoning levels (shared fixture subscription-facts.v1.json).
// inputCases: each case builds a subscription connection (first-hand modalities -> upstream declaration on the model;
// modelFacts -> sidecar dictionary) and asserts the projection through the production entry
// resolveInputCapabilityProjections; endImplements=true uses the Grok subscription chat line (this end implements all three
// families), false uses Codex (the Responses line has no video family). reasoningLevelCases go through
// subscriptionDeclaredReasoningLevels (with the real metadata-client).

import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { decodeCodexModelDescriptors } from '@oriveo/core/providers/openai-subscription';

// Only the model-facts sidecar lookup is replaced; adapters and the projection facade run production code.
const FACTS = vi.hoisted(() => ({
  current: undefined as { modalities?: { input?: string[] }; reasoningEfforts?: string[] } | undefined,
}));
vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../metadata/metadata-client')>()),
  getModelFacts: () => FACTS.current,
  getModelFactsRevision: () => undefined,
}));

import { buildOpenAISubscriptionModels } from '../../providers/openai-subscription-catalog';
import { buildGrokSubscriptionModels } from '../../providers/grok-subscription-catalog';
import { resolveInputCapabilityProjections } from '../truth/input-truth-adapter';
import { subscriptionInputVerdict } from '../truth/subscription-truth-adapter';

const ROOT = resolve(__dirname, '../../../../../../..');
const fixture = JSON.parse(readFileSync(
  resolve(ROOT, 'shared/test-fixtures/capability/subscription-facts.v1.json'), 'utf8',
)) as { inputCases: InputCase[]; reasoningLevelCases: ReasoningLevelCase[] };

type InputKey = 'vision_input' | 'file_input' | 'video_input';

interface InputCase {
  id: string;
  key: InputKey;
  firstHand: string[] | null;
  modelFacts: string[] | null;
  endImplements: boolean;
  expect: {
    state: string;
    reasonCode?: string;
    visible: boolean;
    editable: boolean;
    outbound: 'native_part' | 'placeholder';
    disabledReason?: string;
  };
}

interface ReasoningLevelCase {
  id: string;
  firstHandEfforts: string[] | null;
  modelFactsEfforts: string[] | null;
  expect: string[];
}

function connection(model: AIModel, kind: 'openAI' | 'grok'): Provider {
  return {
    id: kind === 'openAI' ? '11111111-1111-4111-8111-111111111111' : '22222222-2222-4222-8222-222222222222',
    kind, status: { kind: 'connected' }, models: [model], catalogModels: [], apiKey: '', apiKeyPreview: '',
    authMode: 'subscription',
  } as unknown as Provider;
}

/** endImplements=false: production Codex catalog mapping (the upstream /models input_modalities go into the model as-is). */
function codexModel(firstHand: string[] | null): AIModel {
  const [model] = buildOpenAISubscriptionModels(decodeCodexModelDescriptors({
    models: [{
      slug: 'gpt-sub', visibility: 'list', supported_in_api: true,
      ...(firstHand ? { input_modalities: firstHand } : {}),
    }],
  }));
  return model;
}

/** endImplements=true: Grok subscription chat line; the Grok upstream declares no modalities, so the case adds the first-hand list to the model. */
function grokChatModel(firstHand: string[] | null): AIModel {
  const [model] = buildGrokSubscriptionModels([{
    id: 'grok-sub', supportsWebSearch: false, supportsReasoning: false, reasoningEfforts: [], apiBackend: 'chat',
  }]);
  return firstHand ? { ...model, upstreamInputModalities: firstHand } : model;
}

describe('subscription-facts.v1 inputCases', () => {
  beforeEach(() => { FACTS.current = undefined; });

  it('the Codex catalog mapping keeps first-hand input modalities and leaves them unset when the upstream gives none', () => {
    expect(codexModel(['text', 'image']).upstreamInputModalities).toEqual(['text', 'image']);
    expect(codexModel(null).upstreamInputModalities).toBeUndefined();
  });

  for (const testCase of fixture.inputCases) {
    it(`SUBSCRIPTION-FACTS-${testCase.id}`, () => {
      FACTS.current = testCase.modelFacts ? { modalities: { input: testCase.modelFacts } } : undefined;
      const model = testCase.endImplements ? grokChatModel(testCase.firstHand) : codexModel(testCase.firstHand);
      const provider = connection(model, testCase.endImplements ? 'grok' : 'openAI');

      const projections = resolveInputCapabilityProjections(provider, model, undefined);
      expect(projections).not.toBeNull();
      const projection = projections![testCase.key];
      expect({
        visible: projection.visible,
        editable: projection.editable,
        outbound: projection.outbound,
      }).toEqual({
        visible: testCase.expect.visible,
        editable: testCase.expect.editable,
        outbound: testCase.expect.outbound,
      });
      expect(projection.disabledReason ?? undefined).toBe(
        testCase.expect.disabledReason
          ?? (testCase.expect.state === 'unavailable' ? 'disabled.model_absent' : undefined),
      );

      const verdict = subscriptionInputVerdict(provider, model, testCase.key);
      expect(verdict.state).toBe(testCase.expect.state);
      if (testCase.expect.reasonCode) expect(verdict.reasonCode).toBe(testCase.expect.reasonCode);
    });
  }
});

// Levels read getModelFacts inside the metadata-client module (the mock above cannot replace in-module calls):
// this block uses the real module and loads a dictionary with one model id per case through the production ensureModelFacts.
describe('subscription-facts.v1 reasoningLevelCases', () => {
  const modelIdOf = (testCase: ReasoningLevelCase) => `rl-${testCase.id.replace(/_/g, '-')}`;
  let metadata: typeof import('../../metadata/metadata-client');

  beforeAll(async () => {
    const facts = Object.fromEntries(fixture.reasoningLevelCases
      .filter((testCase) => testCase.modelFactsEfforts)
      .map((testCase) => [`openAI/${modelIdOf(testCase)}`, { reasoningEfforts: testCase.modelFactsEfforts }]));
    vi.spyOn(globalThis, 'fetch').mockImplementation(async () => new Response(JSON.stringify({
      code: 0, data: { facts, revision: 'subscription-facts-r1' }, message: 'ok',
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    metadata = await vi.importActual<typeof import('../../metadata/metadata-client')>('../../metadata/metadata-client');
    await metadata.ensureModelFacts();
  });
  afterAll(async () => {
    await metadata.__settleMetadataBackgroundWorkForTest();
    metadata.__resetMetadataClientForTest();
    vi.restoreAllMocks();
  });

  for (const testCase of fixture.reasoningLevelCases) {
    it(`SUBSCRIPTION-FACTS-${testCase.id}`, () => {
      const base = { ...codexModel(null), id: modelIdOf(testCase) };
      const model = testCase.firstHandEfforts ? { ...base, upstreamReasoningLevels: testCase.firstHandEfforts } : base;
      expect(metadata.subscriptionDeclaredReasoningLevels('openAI', model)).toEqual(testCase.expect);
    });
  }
});
