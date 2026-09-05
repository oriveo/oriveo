import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../metadata/metadata-client', () => ({
  resolveCatalogModel: vi.fn(),
  getRelayRuntimeConfig: vi.fn(() => null),
  // The generation profile of an official provider is resolved by core dispatch from the
  // same fixture metadata (see resolveGenerationProfile in request-builders/dispatch.ts),
  // so returning undefined here does not weaken the assertions: what the builder actually
  // consumes is the profile dispatch resolved.
  resolveGenerationProfileRef: vi.fn(() => undefined),
  // Badge visibility is decided in one place by presentCapabilityControl, which reads the
  // catalog transport and the v2 runtime. This fixture carries no runtime, which covers the
  // "legacy profile only" case exactly: without an exact recipe the answer is unknown, and a
  // newer client must not light up an automatic control from a legacy profile alone.
  getModelTransport: vi.fn(() => undefined),
  getCapabilityRuntime: vi.fn(() => undefined),
  getDeclaredReasoningLevels: vi.fn(() => []),
}));

import type { AIModel, Provider } from '@oriveo/shared';
import { PROVIDER_KINDS } from '@oriveo/shared';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import type { GenerationParameterOverrides } from '@oriveo/core/providers/request-builders/types';
import { resolveCatalogModel } from '../../metadata/metadata-client';
import { buildStreamOptionsFromIntent } from '../../chat/stream-options';
import {
  generationParameterProfileFingerprint,
  resolveGenerationParameterOverrides,
  saveGenerationParameterOverrides,
} from '../../chat/generation-parameter-settings';
import { buildCatalogModel } from '../catalog-model';
import { modelSupportsCapabilityFilter } from '../../chat/model-capability-presentation';

const mockResolveCatalogModel = vi.mocked(resolveCatalogModel);

// Consumer of the shared contract fixture's uiCases.
// Semantics: the model declares a capability but its profile is null, so the UI switch or
// selector must stay hidden.
// - reasoning gate: catalog-model.ts `reasoningModeAvailable = Boolean(profiles.reasoning)`,
//   which collapses ChatView availableReasoningModes to ['automatic'] and hides the selector.
// - web gate: stream-options.ts, `capability includes 'web' AND webSearchProfile exists`,
//   matching the two conditions behind ChatView supportsWebControl.

interface ContractUiCase {
  caseId: string;
  intent: {
    providerKind: string;
    modelId: string;
    capability: string;
  };
  expect: { visible: boolean };
}

interface ContractModelEntry {
  canonicalModelId: string;
  displayName?: string;
  capabilities: string[];
  transport?: string;
  profiles: {
    reasoning: string | null;
    webSearch: string | null;
    imageGen: string | null;
    generation?: unknown;
  };
}

interface ContractCase {
  caseId: string;
  intent: {
    providerKind: string;
    modelId: string;
    generationOverrides?: GenerationParameterOverrides;
  };
}

interface RequestShapeContract {
  version: number;
  metadata: {
    version: number;
    providers: Record<string, { resolveMap?: Record<string, string>; models: Record<string, ContractModelEntry> }>;
  };
  cases: ContractCase[];
  uiCases: ContractUiCase[];
  generationProviderKindUniverse: string[];
}

describe('request_shape_contract.v1 uiCases', () => {
  const contract = loadContract();

  beforeEach(() => {
    mockResolveCatalogModel.mockReset();
  });

  it('loads fixture v1 uiCases', () => {
    expect(contract.version).toBe(1);
    expect(contract.uiCases.map((item) => item.caseId)).toEqual([
      'capability_without_profile_hides_web',
      'capability_without_profile_hides_reasoning',
    ]);
  });

  for (const uiCase of loadContract().uiCases) {
    it(`${uiCase.caseId} matches capability/profile UI gate`, () => {
      const entry = findModelEntry(contract, uiCase);
      mockResolveCatalogModel.mockReturnValue({
        canonicalModelId: entry.canonicalModelId,
        displayName: entry.displayName,
        pricingStatus: 'unknown',
        capabilities: entry.capabilities,
        pricing: null,
        profiles: {
          reasoning: entry.profiles.reasoning ?? undefined,
          webSearch: entry.profiles.webSearch ?? undefined,
          imageGen: entry.profiles.imageGen ?? undefined,
        },
        transport: entry.transport,
        isDefault: false,
      });

      const model = buildCatalogModel({
        providerKind: uiCase.intent.providerKind,
        runtimeModelId: uiCase.intent.modelId,
        fallbackName: uiCase.intent.modelId,
      });

      const provider = {
        id: `ui-${uiCase.intent.providerKind}`,
        kind: uiCase.intent.providerKind,
        status: { kind: 'connected' },
        models: [model],
        catalogModels: [model],
        apiKey: '',
        apiKeyPreview: '',
      } as Provider;
      expect(resolveControlVisible(provider, model, uiCase.intent.capability)).toBe(
        uiCase.expect.visible,
      );
    });
  }
});

// End-to-end dormant consumer, from the panel to the outbound request:
// the production write (saveGenerationParameterOverrides, which is what the generation
// parameter panel saves through)
//   -> production read and priority merge (resolveGenerationParameterOverrides)
//   -> production StreamOptions assembly (buildStreamOptionsFromIntent)
//   -> production dispatch and request construction (core buildProviderRequest into each builder)
// v1 has no capabilityRuntime exact recipe, so the user's values must be preserved in
// preferences without changing the final transport or body. Automatic outbound behavior
// for an exact recipe is proven by the model control runtime production consumer test.
describe('request_shape_contract.v1 generation cases stay dormant without an exact runtime', () => {
  const contract = loadContract();
  const generationCases = contract.cases.filter((item) => item.intent.generationOverrides);

  beforeEach(() => {
    localStorage.clear();
    mockResolveCatalogModel.mockReset();
  });

  it('fixture ProviderKind set matches the production enum exactly', () => {
    expect(contract.generationProviderKindUniverse).toEqual([...PROVIDER_KINDS]);
  });

  it('every official providerKind has a generation case', () => {
    expect(generationCases.length).toBeGreaterThanOrEqual(15);
  });

  for (const contractCase of generationCases) {
    it(`${contractCase.caseId} keeps the panel values but does not change the production final request`, async () => {
      const provider = contract.metadata.providers[contractCase.intent.providerKind];
      const canonical = provider?.resolveMap?.[contractCase.intent.modelId]
        ?? contractCase.intent.modelId;
      const entry = provider?.models?.[canonical];
      if (!entry) throw new Error(`fixture is missing the model definition: ${contractCase.caseId}`);

      mockResolveCatalogModel.mockReturnValue({
        canonicalModelId: entry.canonicalModelId,
        displayName: entry.displayName,
        pricingStatus: 'unknown',
        capabilities: entry.capabilities,
        pricing: null,
        profiles: {
          reasoning: entry.profiles.reasoning ?? undefined,
          webSearch: entry.profiles.webSearch ?? undefined,
          imageGen: entry.profiles.imageGen ?? undefined,
          generation: entry.profiles.generation ?? undefined,
        },
        transport: entry.transport,
        isDefault: false,
      });

      const model: AIModel = buildCatalogModel({
        providerKind: contractCase.intent.providerKind,
        runtimeModelId: contractCase.intent.modelId,
        fallbackName: contractCase.intent.modelId,
      });
      const providerRecord = {
        id: `provider-${contractCase.caseId}`,
        kind: contractCase.intent.providerKind,
      } as unknown as Provider;
      const scope = {
        providerId: providerRecord.id,
        modelId: model.id,
        profileFingerprint: generationParameterProfileFingerprint(providerRecord, model),
      };

      // Saved from the panel.
      saveGenerationParameterOverrides(scope, contractCase.intent.generationOverrides!);
      // Read back by the send path, through the same production priority merge.
      const resolved = resolveGenerationParameterOverrides(scope);
      expect(resolved, `${contractCase.caseId}: the value saved in the panel was not read back by the send path`).toBeTruthy();

      const request = await buildProviderRequest(
        {
          providerKind: contractCase.intent.providerKind as never,
          apiKey: 'contract-test-key',
          modelID: contractCase.intent.modelId,
          messages: [{ role: 'user', content: 'hello' }],
          options: buildStreamOptionsFromIntent(model, 'automatic', false, resolved) as never,
        },
        async () => contract.metadata as never,
      );
      const baseline = await buildProviderRequest(
        {
          providerKind: contractCase.intent.providerKind as never,
          apiKey: 'contract-test-key',
          modelID: contractCase.intent.modelId,
          messages: [{ role: 'user', content: 'hello' }],
          options: buildStreamOptionsFromIntent(model, 'automatic', false, undefined) as never,
        },
        async () => contract.metadata as never,
      );

      expect({ url: request.url, headers: request.headers, body: request.body }).toEqual({
        url: baseline.url,
        headers: baseline.headers,
        body: baseline.body,
      });
    });
  }
});

function resolveControlVisible(
  provider: Provider,
  model: ReturnType<typeof buildCatalogModel>,
  capability: string,
): boolean {
  switch (capability) {
    case 'reasoning':
      return modelSupportsCapabilityFilter(provider, model, 'reasoning');
    case 'web':
      return modelSupportsCapabilityFilter(provider, model, 'web');
    default:
      throw new Error(`uiCase capability not wired into the harness: ${capability}`);
  }
}

function findModelEntry(
  contract: RequestShapeContract,
  uiCase: ContractUiCase,
): ContractModelEntry {
  const provider = contract.metadata.providers[uiCase.intent.providerKind];
  const entry = provider?.models[uiCase.intent.modelId];
  if (!entry) {
    throw new Error(
      `fixture is missing the model definition: ${uiCase.intent.providerKind}/${uiCase.intent.modelId}`,
    );
  }
  return entry;
}

function loadContract(): RequestShapeContract {
  return JSON.parse(readFileSync(findContractPath(), 'utf8')) as RequestShapeContract;
}

function findContractPath(): string {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'shared', 'model-contracts', 'request_shape_contract.v1.json');
    if (existsSync(candidate)) return candidate;

    const parent = path.dirname(current);
    if (parent === current) {
      throw new Error('request_shape_contract.v1.json not found');
    }
    current = parent;
  }
}
