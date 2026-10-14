import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { findModelInProvider } from '../provider-model-ops';
import { deduplicateByCanonical, deduplicateModels } from '../providers/catalog-model';
import {
  relayStoredModelId,
  resolveRelayStoredModel,
  sameRelayModel,
} from '../providers/relay-model-identity';

interface ContractModel {
  id: string;
  name: string;
  canonicalModelId?: string;
}

interface LookupCase {
  id: string;
  providerKind: Provider['kind'];
  query: string;
  expectedModelId: string | null;
  models: ContractModel[];
}

interface DedupeCase {
  id: string;
  models: ContractModel[];
  expectedModelIds: string[];
}

// Relay section (D-81): literal ID identity; date snapshots, canonical id and display name never match.
interface RelayCases {
  providerKind: Provider['kind'];
  sameRemoteCases: { id: string; left: ContractModel; right: ContractModel; expected: boolean }[];
  lookupCases: { id: string; query: string; models: ContractModel[]; expectedModelId: string | null }[];
  storedIdentifierCases: { id: string; model: ContractModel; expectedStoredModelId: string }[];
  dedupeCases: DedupeCase[];
  readCompatCases: {
    id: string;
    storedModelId: string;
    enabledModels: ContractModel[];
    expectedModelId: string | null;
  }[];
}

interface ContractFile {
  version: number;
  lookupCases: LookupCase[];
  dedupeCases: DedupeCase[];
  relayCases: RelayCases;
}

const contractPath = path.resolve(
  process.cwd(),
  '../../../shared/model-contracts/model_identity_contract.v1.json',
);
const contract = JSON.parse(readFileSync(contractPath, 'utf8')) as ContractFile;

function makeModel(model: ContractModel): AIModel {
  return {
    id: model.id,
    name: model.name,
    canonicalModelId: model.canonicalModelId,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
  };
}

function makeProvider(providerKind: Provider['kind'], models: ContractModel[]): Provider {
  const catalogModels = models.map(makeModel);
  return {
    id: 'provider-contract',
    kind: providerKind,
    status: { kind: 'connected' },
    models: catalogModels,
    catalogModels,
    apiKey: '',
    apiKeyPreview: '',
  };
}

describe('model identity contract', () => {
  for (const testCase of contract.lookupCases) {
    it(`lookup: ${testCase.id}`, () => {
      const provider = makeProvider(testCase.providerKind, testCase.models);
      const resolved = findModelInProvider(provider, testCase.query);
      expect(resolved?.id ?? null).toBe(testCase.expectedModelId);
    });
  }

  for (const testCase of contract.dedupeCases) {
    it(`dedupe: ${testCase.id}`, () => {
      const deduped = deduplicateByCanonical(testCase.models.map(makeModel));
      expect(deduped.map((model) => model.id)).toEqual(testCase.expectedModelIds);
    });
  }
});

describe('model identity contract: relay', () => {
  const relay = contract.relayCases;

  for (const testCase of relay.sameRemoteCases) {
    it(`relay same remote: ${testCase.id}`, () => {
      const left = makeModel(testCase.left);
      const right = makeModel(testCase.right);
      expect(sameRelayModel(left, right)).toBe(testCase.expected);
      expect(sameRelayModel(right, left)).toBe(testCase.expected);
    });
  }

  for (const testCase of relay.lookupCases) {
    it(`relay lookup: ${testCase.id}`, () => {
      const provider = makeProvider(relay.providerKind, testCase.models);
      expect(findModelInProvider(provider, testCase.query)?.id ?? null).toBe(testCase.expectedModelId);
    });
  }

  for (const testCase of relay.storedIdentifierCases) {
    it(`relay stored identifier: ${testCase.id}`, () => {
      expect(relayStoredModelId(makeModel(testCase.model))).toBe(testCase.expectedStoredModelId);
    });
  }

  for (const testCase of relay.dedupeCases) {
    it(`relay dedupe: ${testCase.id}`, () => {
      const deduped = deduplicateModels(testCase.models.map(makeModel), relay.providerKind);
      expect(deduped.map((model) => model.id)).toEqual(testCase.expectedModelIds);
    });
  }

  for (const testCase of relay.readCompatCases) {
    it(`relay read compat: ${testCase.id}`, () => {
      const resolved = resolveRelayStoredModel(testCase.enabledModels.map(makeModel), testCase.storedModelId);
      expect(resolved?.id ?? null).toBe(testCase.expectedModelId);
    });
  }
});
