// Model retirement verdicts: conversation status, display-name fallback, and new-conversation fallback.
// Fixture source: shared/test-fixtures/provider-catalog/model-retired.v1.json (cases RETIRED-<id>).
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import {
  resolveModelRetirement,
  type RetirementCatalog,
} from '../conversation-model-status';
import { createProviderSelectionSnapshot } from '../../providers/provider-selection-snapshot';

// New-conversation cases go through the production entry createProviderSelectionSnapshot: the metadata catalog is fed from each case's catalog.
const catalogState = vi.hoisted(() => ({ current: null as RetirementCatalog | null }));

vi.mock('../../metadata/metadata-client', async (importOriginal) => (await import('../../../__tests__/mocks/metadata-client')).metadataClientMock(importOriginal, {
  getProviderCatalogStatus: () => (catalogState.current ? 'loaded' : 'pending'),
  getProviderDefaultModelId: () => catalogState.current?.defaultModelId,
  getProviderRetiredModels: () => catalogState.current?.retiredModels ?? [],
  listProviderModelIds: () => catalogState.current?.models.map((model) => model.id) ?? [],
  resolveCatalogModel: (id: string) => {
    const catalog = catalogState.current;
    if (!catalog) return undefined;
    const canonical = catalog.resolveMap?.[id];
    const entry = catalog.models.find((model) => model.id === id);
    if (entry) return { canonicalModelId: canonical ?? id, displayName: entry.displayName, lifecycle: entry.lifecycle };
    return canonical ? { canonicalModelId: canonical } : undefined;
  },
}));

interface ConversationCase {
  id: string;
  catalog: RetirementCatalog | null;
  userModels: string[];
  conversation: { modelId: string; storedName: string | null };
  expect: {
    status: 'available' | 'retired' | 'missing';
    successorId: string | null;
    displayName: string;
    sendBlocked: boolean;
    modelIdAfter: string;
  };
}

interface NewChatCase {
  id: string;
  catalog: RetirementCatalog | null;
  userModels: string[];
  userModelCanonicalIds?: Record<string, string>;
  preferredModelId: string | null;
  expect: { modelId: string | null; hint: 'last_used_retired' | null };
}

const fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'provider-catalog', 'model-retired.v1.json');
    if (existsSync(candidate)) {
      return JSON.parse(readFileSync(candidate, 'utf8')) as {
        now: string;
        conversationCases: ConversationCase[];
        newChatCases: NewChatCase[];
      };
    }
    dir = path.dirname(dir);
  }
  throw new Error('model-retired.v1.json not found');
})();

describe('model retired fixture', () => {
  for (const testCase of fixture.conversationCases) {
    it(`RETIRED-${testCase.id}`, () => {
      const input = {
        catalog: testCase.catalog,
        userModels: testCase.userModels,
        conversation: testCase.conversation,
        now: fixture.now,
      };
      const before = structuredClone(input);
      const result = resolveModelRetirement(input);
      expect({
        status: result.status,
        successorId: result.successorId,
        displayName: result.displayName,
        sendBlocked: result.sendBlocked,
      }).toEqual({
        status: testCase.expect.status,
        successorId: testCase.expect.successorId,
        displayName: testCase.expect.displayName,
        sendBlocked: testCase.expect.sendBlocked,
      });
      // The verdict neither rewrites the conversation model nor mutates any input
      expect(result.modelId).toBe(testCase.expect.modelIdAfter);
      expect(input.conversation.modelId).toBe(testCase.expect.modelIdAfter);
      expect(input).toEqual(before);
    });
  }

  afterEach(() => {
    vi.useRealTimers();
    catalogState.current = null;
  });

  for (const testCase of fixture.newChatCases) {
    it(`RETIRED-${testCase.id}`, () => {
      vi.useFakeTimers({ toFake: ['Date'] });
      vi.setSystemTime(new Date(fixture.now));
      catalogState.current = testCase.catalog;
      const models: AIModel[] = testCase.userModels.map((id) => ({
        id,
        name: id,
        canonicalModelId: testCase.userModelCanonicalIds?.[id],
        capabilities: ['text'],
        reasoningModeAvailable: false,
        isAvailable: true,
        isDefault: false,
        priceTier: '$',
      }));
      const provider: Provider = {
        id: 'fixture-provider',
        kind: 'openAI',
        status: { kind: 'connected' },
        models,
        catalogModels: [],
        apiKey: 'sk-test',
        apiKeyPreview: 'sk-...test',
      };
      const before = structuredClone(provider);
      const snapshot = createProviderSelectionSnapshot(provider, { preferredModelId: testCase.preferredModelId });
      expect({
        modelId: snapshot?.defaultModel?.id ?? null,
        hint: snapshot?.defaultModelHint ?? null,
      }).toEqual(testCase.expect);
      expect(provider).toEqual(before);
    });
  }
});
