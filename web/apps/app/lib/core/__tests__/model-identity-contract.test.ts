import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { findModelInProvider } from '../provider-model-ops';
import { deduplicateByCanonical } from '../providers/catalog-model';

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

interface ContractFile {
  version: number;
  lookupCases: LookupCase[];
  dedupeCases: DedupeCase[];
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
