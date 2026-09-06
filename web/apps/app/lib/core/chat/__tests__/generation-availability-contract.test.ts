import 'fake-indexeddb/auto';
// @vitest-environment jsdom

import { afterEach, describe, expect, it } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import type { AIModel, Provider } from '@oriveo/shared';
import { applyGenerationParameters } from '@oriveo/core/providers/request-builders/generation-parameters';
import {
  __seedMetadataCacheForTest,
  __resetMetadataClientForTest,
  initMetadata,
} from '../../metadata/metadata-client';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';
import { resolveGenerationParameterEvidence } from '../capability-evidence';
import {
  buildProviderStreamOptions,
  buildStreamOptionsFromIntent,
  connectionConfigurable,
  entryVisible,
  filterGenerationParameterOverrides,
  generationParameterAdjustable,
  resolveGenerationProfileForModel,
  sessionActionable,
} from '../stream-options';

interface AvailabilityCase {
  caseId: string;
  intent: {
    providerKind: 'official' | 'relay';
    scope: 'session' | 'connectionDefaults';
    parameter: { id: string; group?: string; support: string; wire?: string | null };
    /** Whether the host in this case lets its users configure the `engine_runtime` group. */
    entitlement: { canManageRuntime: boolean };
  };
  expect: { inScope: boolean; entryVisible: boolean; editable: boolean };
}

interface Contract {
  version: number;
  availabilityCases: AvailabilityCase[];
}

const contract = loadContract();

describe('generation_parameter_contract.v1 availabilityCases - Web production consumer', () => {
  afterEach(() => {
    __resetMetadataClientForTest();
    resetCapabilityEvidenceIdentitiesForTesting();
    localStorage.clear();
  });

  it('locks the whole shared availability golden, not a subset of it', () => {
    expect(contract.version).toBe(1);
    expect(contract.availabilityCases).toHaveLength(58);
    expect(new Set(contract.availabilityCases.map((item) => item.caseId)).size).toBe(58);
    expect(contract.availabilityCases).toEqual(expect.arrayContaining([
      expect.objectContaining({ caseId: 'official.session.support_accepted' }),
      expect.objectContaining({ caseId: 'official.connectionDefaults.support_accepted_unverified' }),
      expect.objectContaining({ caseId: 'relay.session.support_unknown' }),
      expect.objectContaining({ caseId: 'relay.connectionDefaults.support_accepted' }),
      expect.objectContaining({ caseId: 'official.session.support_future_supported' }),
      expect.objectContaining({ caseId: 'relay.connectionDefaults.support_future_supported' }),
    ]));
  });

  for (const item of contract.availabilityCases) {
    it(`${item.caseId} reaches the production visibility and editability predicates`, async () => {
      await primeMetadata(item);
      await initMetadata();

      const provider = makeProvider(item);
      const model = makeModel(item);
      if (item.intent.providerKind === 'relay') {
        beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
      }

      const profile = resolveGenerationProfileForModel(provider, model);
      expect(profile, `${item.caseId} profile`).toBeTruthy();
      const streamOptions = buildProviderStreamOptions(provider, undefined, model);
      const evidence = resolveGenerationParameterEvidence({
        provider,
        model,
        profile: profile!,
        parameterId: item.intent.parameter.id,
        hasExplicitValue: false,
        streamOptions,
      });
      const scopeParameters = item.intent.scope === 'session'
        ? sessionActionable(provider, model)
        : connectionConfigurable(provider, model, item.intent.entitlement);
      const inScope = scopeParameters.some(({ id }) => id === item.intent.parameter.id);
      const editable = inScope
        && generationParameterAdjustable(
          profile!.wire[item.intent.parameter.id],
          item.intent.parameter.support,
          evidence,
        );

      expect(inScope, `${item.caseId}: inScope`).toBe(item.expect.inScope);
      expect(
        entryVisible(provider, model, item.intent.scope, item.intent.entitlement),
        `${item.caseId}: entryVisible`,
      ).toBe(item.expect.entryVisible);
      expect(editable, `${item.caseId}: editable`).toBe(item.expect.editable);
    });
  }

  // An official provider plus an explicit user-supplied value plus no evidence of our own means the
  // value goes through. This case previously asserted "out of the final request", which contradicts
  // capability_evidence_contract.v1 `official.explicit.*`, the single authority here.
  // The same declared support is editable under a complete profile identity; without an explicit
  // value no outbound field is produced.
  it('lets an explicitly typed value through for an official accepted row, but never without an explicit value', async () => {
    const item = requiredCase('official.connectionDefaults.support_accepted');
    await primeMetadata(item);
    await initMetadata();
    const provider = makeProvider(item);
    const model = makeModel(item);
    const profile = resolveGenerationProfileForModel(provider, model)!;
    const options = buildProviderStreamOptions(provider, undefined, model);
    const filtered = filterGenerationParameterOverrides(provider, model, {
      [item.intent.parameter.id]: { state: 'value', value: 0.4 },
    }, options);
    const body: Record<string, unknown> = {};

    applyGenerationParameters(body, filtered, profile);

    expect(connectionConfigurable(provider, model, item.intent.entitlement)).toHaveLength(1);
    expect(filtered).toEqual({ [item.intent.parameter.id]: { state: 'value', value: 0.4 } });
    expect(valueAtPath(body, profile.wire[item.intent.parameter.id])).toBe(0.4);

    // Reverse assertion, so "allowed" cannot be implemented as always-true: with no explicit value (inherit) not a byte goes out.
    const inherited = filterGenerationParameterOverrides(provider, model, {
      [item.intent.parameter.id]: { state: 'inherit' },
    }, options);
    expect(inherited).toBeUndefined();
  });

  it('requires complete Relay identity and an explicit value before an unverified declaration writes wire', async () => {
    const item = requiredCase('relay.session.support_accepted_unverified');
    await primeMetadata(item);
    await initMetadata();
    const provider = makeProvider(item);
    const model = makeModel(item);
    const profile = resolveGenerationProfileForModel(provider, model)!;
    const options = buildProviderStreamOptions(provider, undefined, model);
    const noIdentity = filterGenerationParameterOverrides(provider, model, {
      [item.intent.parameter.id]: { state: 'value', value: 0.4 },
    }, options);

    // With an incomplete identity, another connection's declaration can neither be consumed nor turned into an outbound fact for this connection.
    expect(sessionActionable(provider, model)).toEqual([]);
    expect(resolveGenerationParameterEvidence({
      provider, model, profile, parameterId: item.intent.parameter.id,
      hasExplicitValue: true, streamOptions: options,
    })).toMatchObject({ source: 'none', requestPolicy: 'allow_explicit_unverified' });
    expect(noIdentity).toBeUndefined();

    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    const noExplicit = resolveGenerationParameterEvidence({
      provider, model, profile, parameterId: item.intent.parameter.id,
      hasExplicitValue: false,
      streamOptions: options,
    });
    const filtered = filterGenerationParameterOverrides(provider, model, {
      [item.intent.parameter.id]: { state: 'value', value: 0.4 },
    }, options);
    const body: Record<string, unknown> = {};
    applyGenerationParameters(body, filtered, profile);

    expect(noExplicit.requestPolicy).toBe('omit_unknown');
    expect(filtered).toEqual({ [item.intent.parameter.id]: { state: 'value', value: 0.4 } });
    expect(valueAtPath(body, profile.wire[item.intent.parameter.id])).toBe(0.4);
  });
});

function requiredCase(caseId: string): AvailabilityCase {
  const item = contract.availabilityCases.find((candidate) => candidate.caseId === caseId);
  if (!item) throw new Error(`missing generation availability case ${caseId}`);
  return item;
}

async function primeMetadata(item: AvailabilityCase): Promise<void> {
  const { parameter } = item.intent;
  __resetMetadataClientForTest();
  await __seedMetadataCacheForTest({
    data: {
      version: 1,
      contractVersion: 1,
      updatedAt: '2026-08-09T00:00:00Z',
      profiles: {
        reasoning: {}, webSearch: {}, imageGen: {},
        generation: {
          parameters: parameter.group ? { [parameter.id]: { group: parameter.group } } : {},
          templates: {
            capability_availability: {
              transport: 'openai_chat_completions',
              wire: parameter.wire ? { [parameter.id]: parameter.wire } : {},
            },
          },
        },
      },
      relayRuntimeConfig: { defaultTransport: 'openai_chat_completions' },
      providers: {
        openAI: {
          resolveMap: { 'availability-model': 'availability-model' },
          models: {
            'availability-model': {
              canonicalModelId: 'availability-model',
              transport: 'openai_chat_completions',
              profiles: {
                generation: {
                  template: 'capability_availability',
                  parameters: [{ id: parameter.id, support: parameter.support, source: 'authoritative_metadata' }],
                },
              },
            },
          },
        },
      },
      providerConfigs: [],
    },
    timestamp: Date.now(),
  });
}

function makeProvider(item: AvailabilityCase): Provider {
  if (item.intent.providerKind === 'official') {
    return {
      id: 'provider-official', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [],
      apiKey: 'fixture-only', apiKeyPreview: '',
    } as unknown as Provider;
  }
  return {
    id: 'provider-relay', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [],
    apiKey: 'fixture-only', apiKeyPreview: '', baseURLText: 'https://relay.example/v1',
    relayResolvedBaseURLText: 'https://relay.example/v1', relayResolvedTransport: 'openai_chat_completions',
    relayRequested: { transport: 'openai_chat_completions', securityMode: 'remote_https' },
  } as unknown as Provider;
}

function makeModel(item: AvailabilityCase): AIModel {
  const { parameter } = item.intent;
  return {
    id: 'availability-model', name: 'availability-model', capabilities: ['text'], reasoningModeAvailable: false,
    isAvailable: true, isDefault: false, priceTier: '', transport: 'openai_chat_completions',
    generationProfile: {
      template: 'capability_availability',
      parameters: [{ id: parameter.id, group: parameter.group, support: parameter.support, source: 'authoritative_metadata' }],
    },
  } as unknown as AIModel;
}

function valueAtPath(source: unknown, wire: string | undefined): unknown {
  if (!wire) return undefined;
  return wire.split('.').reduce<unknown>((value, segment) => (
    value && typeof value === 'object' ? (value as Record<string, unknown>)[segment] : undefined
  ), source);
}

function loadContract(): Contract {
  return JSON.parse(readFileSync(findContractPath(), 'utf8')) as Contract;
}

function findContractPath(): string {
  let current = process.cwd();
  for (;;) {
    const candidate = path.join(current, 'shared', 'model-contracts', 'generation_parameter_contract.v1.json');
    if (existsSync(candidate)) return candidate;
    const parent = path.dirname(current);
    if (parent === current) throw new Error('generation_parameter_contract.v1.json not found');
    current = parent;
  }
}
