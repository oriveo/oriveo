// @vitest-environment jsdom
//
// Display facts: "shows thinking" (shared fixture display-facts.v1.json thinkingCases).
// Each case builds a production connection / model for its form, reads `reasoning/thinking` through the facade entry
// resolveModelCapabilityEvidence and asserts showsThinking: adapters produce it only from the form's own source,
// a missing source means not shown.

import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';

// The official catalog and the model-facts sidecar are supplied per case: only these two lookups are replaced, adapters and facade run production code.
const METADATA = vi.hoisted(() => ({
  catalog: new Map<string, { capabilities: string[] } | null>(),
  facts: new Map<string, { reasoning?: boolean }>(),
  runtime: null as unknown,
}));
vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../metadata/metadata-client')>()),
  resolveCatalogModel: (modelID: string) => {
    const entry = METADATA.catalog.get(modelID);
    return entry ? { canonicalModelId: modelID, capabilities: entry.capabilities } : null;
  },
  getModelFacts: (_providerKind: string, modelID: string) => METADATA.facts.get(modelID),
  getModelFactsRevision: () => undefined,
  // Web badge cases give the official model a minimal recipe runtime; other cases keep no runtime.
  getCapabilityRuntime: () => METADATA.runtime,
  getModelTransport: () => undefined,
}));

import { resolveModelCapabilityEvidence } from '../../chat/capability-evidence';
import { visibleModelCapabilityBadges } from '../../chat/model-capability-presentation';
import { decidedTransport } from '@oriveo/core/providers/relay-effective';
import { presentCapabilityControl } from '../../chat/capability-control-presentation';
import { chatTemplateThinkingApplies } from '../../chat/chat-template-thinking';
import { beginCapabilityEvidenceIdentityIfAbsent } from '../../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';
import {
  modelOptionConnection,
  modelOptionReasoningFacts,
  resolveModelOptionCapabilityShape,
  type ModelOptionCapabilityShape,
} from '../../chat/model-option-capability-shape';
import { modelMatchesFilters } from '../../../../components/chat/ModelSwitcher/model-switcher-data';
import type { RelayCapabilityEvidenceIdentity } from '../truth/capability-truth-adapter';

const ROOT = resolve(__dirname, '../../../../../../..');
const fixture = JSON.parse(readFileSync(
  resolve(ROOT, 'shared/test-fixtures/capability/display-facts.v1.json'), 'utf8',
)) as { thinkingCases: ThinkingCase[]; managedWebBadgeCases: WebBadgeCase[] };

interface ThinkingCase {
  id: string;
  form: 'official' | 'subscription' | 'relay';
  modelId: string;
  source: {
    catalogCapabilities?: string[];
    catalogEntry?: null;
    modelFacts?: { reasoning?: boolean } | null;
    firstHandEfforts?: string[];
    declaredCapabilities?: string[];
  };
  tiers: string[];
  expect: { showsThinking: boolean; thinkingRow: 'switchable' | 'fixed' | 'none' };
}

interface WebBadgeCase {
  id: string;
  form: 'official';
  webControlState: 'auto_available' | 'managed_only' | 'custom_only' | 'unknown' | 'unavailable';
  expect: { badge: boolean; pickerFilterMatches: boolean };
}

const RELAY_IDENTITY: RelayCapabilityEvidenceIdentity = {
  partitionId: 'uid-display-facts',
  connectionInstanceId: 'relay-instance-1',
  connectionGeneration: '1',
  credentialEpoch: '1',
  endpointFingerprint: 'relay-endpoint-1',
};

function plainModel(id: string, overrides: Partial<AIModel> = {}): AIModel {
  return {
    id, name: id, capabilities: ['text'], reasoningModeAvailable: false,
    isAvailable: true, isDefault: false, priceTier: '',
    ...overrides,
  } as AIModel;
}

function officialConnection(entry: ThinkingCase): { provider: Provider; model: AIModel } {
  if (entry.source.catalogCapabilities) {
    METADATA.catalog.set(entry.modelId, { capabilities: entry.source.catalogCapabilities });
  }
  if (entry.source.modelFacts) METADATA.facts.set(entry.modelId, entry.source.modelFacts);
  const provider = {
    id: 'byok-openai', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [],
    apiKey: 'sk-byok', apiKeyPreview: 'sk-…', authMode: 'apiKey',
  } as Provider;
  return { provider, model: plainModel(entry.modelId) };
}

function subscriptionConnection(entry: ThinkingCase): { provider: Provider; model: AIModel } {
  if (entry.source.modelFacts) METADATA.facts.set(entry.modelId, entry.source.modelFacts);
  const model = plainModel(entry.modelId, {
    ...(entry.source.firstHandEfforts ? { upstreamReasoningLevels: entry.source.firstHandEfforts } : {}),
  });
  const provider = {
    id: '22222222-2222-4222-8222-222222222222', kind: 'grok', status: { kind: 'connected' },
    models: [model], catalogModels: [], apiKey: '', apiKeyPreview: '', authMode: 'subscription',
  } as unknown as Provider;
  return { provider, model };
}

function relayConnection(entry: ThinkingCase): { provider: Provider; model: AIModel } {
  const provider = {
    id: 'relay-1', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [],
    apiKey: 'sk-relay', apiKeyPreview: 'sk-…', baseURLText: 'https://relay.example',
    relayRequested: { authMode: 'bearer', securityMode: 'remote_https', resolvedAPIBaseURL: 'https://relay.example/v1' },
  } as unknown as Provider;
  const declared = (entry.source.declaredCapabilities ?? []) as AIModel['capabilities'];
  return { provider, model: plainModel(entry.modelId, { capabilities: ['text', ...declared] }) };
}

function connectionFor(entry: ThinkingCase): { provider: Provider; model: AIModel } {
  METADATA.catalog.clear();
  METADATA.facts.clear();
  const build = {
    official: officialConnection,
    subscription: subscriptionConnection,
    relay: relayConnection,
  }[entry.form];
  const connection = build(entry);
  expect(connection.model, `${entry.id} model`).toBeDefined();
  return connection;
}

function showsThinking(entry: ThinkingCase): boolean {
  const { provider, model } = connectionFor(entry);
  const resolution = resolveModelCapabilityEvidence({
    key: 'reasoning/thinking',
    provider,
    model,
    // Give a fixed outbound protocol so facts can match.
    effectiveTransport: 'openai_responses',
    ...(entry.form === 'relay' ? { relayIdentity: RELAY_IDENTITY } : {}),
  });
  return resolution.support === 'supported';
}

// Fixture tiers use names shared across ends; the Web thinking vocabulary is off / low / balanced / deep / max, and "on" is the switch's single level.
const WEB_REASONING_INTENT: Readonly<Record<string, string>> = {
  off: 'off', on: 'balanced', low: 'low', medium: 'balanced', high: 'deep', max: 'max',
};

/**
 * Reasoning control the official catalog delivers for a model (server recipe): tiers present -> auto_available;
 * catalog entry without tiers -> unavailable; model missing from the catalog -> nothing delivered.
 * This is catalog input; the form's verdict is computed by production code.
 */
function officialCatalogReasoningControl(entry: ThinkingCase): AIModel['capabilityControls'] {
  if (!entry.source.catalogCapabilities) return undefined;
  METADATA.runtime = { recipes: { reasoning_recipe: {} }, sourceIndex: {} };
  if (entry.tiers.length === 0) return { reasoning: { state: 'unavailable', availableIntents: [] } } as AIModel['capabilityControls'];
  return {
    reasoning: {
      state: 'auto_available', recipeRef: 'reasoning_recipe',
      availableIntents: entry.tiers.map((tier) => WEB_REASONING_INTENT[tier] ?? tier),
    },
  } as AIModel['capabilityControls'];
}

/**
 * Thinking row shape, assembled the same way as the model options panel: control state from presentCapabilityControl,
 * status / tiers / shows-thinking from modelOptionReasoningFacts, connection class from modelOptionConnection.
 */
function thinkingRow(entry: ThinkingCase): 'switchable' | 'fixed' | 'none' {
  METADATA.runtime = null;
  const connection = connectionFor(entry);
  const { provider } = connection;
  let { model } = connection;
  if (entry.form === 'relay') {
    // A relay connection in the panel already has its evidence identity registered and its first-send protocol decided (Anthropic Messages: no chat-template thinking switch).
    Object.assign(provider, {
      relayResolvedTransport: 'anthropic_messages',
      relayRequested: { ...provider.relayRequested, transport: 'anthropic_messages' },
    });
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
  }
  if (entry.form === 'official') {
    const controls = officialCatalogReasoningControl(entry);
    if (controls) model = { ...model, capabilityControls: controls };
  }
  const control = presentCapabilityControl(provider, model, 'reasoning');
  const shape = resolveModelOptionCapabilityShape({
    capability: 'reasoning',
    ...modelOptionReasoningFacts(provider, model, control),
    connection: modelOptionConnection(provider),
    isWritable: true,
    protocolUndecided: false,
    rejectedIntents: [],
    chatTemplateThinkingIsOn: false,
    supportsChatTemplate: chatTemplateThinkingApplies(provider.kind === 'relay' ? decidedTransport(provider, model) : undefined),
  });
  METADATA.runtime = null;
  return rowOf(shape);
}

function rowOf(shape: ModelOptionCapabilityShape): 'switchable' | 'fixed' | 'none' {
  if (shape.kind === 'tiers' || shape.kind === 'toggle') return 'switchable';
  if (shape.kind === 'notice' && shape.status === 'alwaysThinks') return 'fixed';
  if (shape.kind === 'disclosure' && shape.status.kind === 'showsThinkingFixed') return 'fixed';
  if (shape.kind === 'disclosure' && shape.status.kind === 'modelLacksCapability') return 'none';
  throw new Error(`unexpected thinking row ${JSON.stringify(shape)}`);
}

function webBadgeConnection(entry: WebBadgeCase): { provider: Provider; model: AIModel } {
  METADATA.runtime = { recipes: { web_recipe: {} }, sourceIndex: {} };
  const provider = {
    id: 'byok-openai', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [],
    apiKey: 'sk-byok', apiKeyPreview: 'sk-…', authMode: 'apiKey',
  } as Provider;
  const control = entry.webControlState === 'auto_available'
    ? { state: 'auto_available', recipeRef: 'web_recipe', availableIntents: ['automatic'] }
    : { state: entry.webControlState, availableIntents: [] };
  return {
    provider,
    model: plainModel(`official-${entry.id}`, {
      capabilities: ['text', 'web'],
      capabilityControls: { web: control },
    } as Partial<AIModel>),
  };
}

describe('display facts · shows thinking (display-facts.v1.json thinkingCases)', () => {
  it('fixture carries thinking cases for every form', () => {
    expect(new Set(fixture.thinkingCases.map((entry) => entry.form)))
      .toEqual(new Set(['official', 'subscription', 'relay']));
  });

  for (const entry of fixture.thinkingCases) {
    it(`DISPLAY-FACTS-${entry.id} shows thinking = ${entry.expect.showsThinking}`, () => {
      expect(showsThinking(entry)).toBe(entry.expect.showsThinking);
    });
    it(`DISPLAY-FACTS-${entry.id} thinking row = ${entry.expect.thinkingRow}`, () => {
      expect(thinkingRow(entry)).toBe(entry.expect.thinkingRow);
    });
  }
});

describe('display facts · web badge and picker filter (display-facts.v1.json managedWebBadgeCases)', () => {
  for (const entry of fixture.managedWebBadgeCases) {
    it(`DISPLAY-FACTS-${entry.id} badge = ${entry.expect.badge}, filter = ${entry.expect.pickerFilterMatches}`, () => {
      METADATA.runtime = null;
      const { provider, model } = webBadgeConnection(entry);
      expect(model, `${entry.id} model`).toBeDefined();
      expect(visibleModelCapabilityBadges(provider, model).includes('web')).toBe(entry.expect.badge);
      expect(modelMatchesFilters(provider, model, new Set(['web']))).toBe(entry.expect.pickerFilterMatches);
      METADATA.runtime = null;
    });
  }
});
