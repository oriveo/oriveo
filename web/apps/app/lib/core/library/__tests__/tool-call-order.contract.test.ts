import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';

// Verdict order of tool_call for official / subscription connections (shared fixture tool-call-order.v1.json):
// first-hand / catalog evidence > rejection memory (false only, same revision, declaration unchanged) > modelFacts (used only when the catalog has none) >
// explicit local declaration on a hand-added model > memory true > unknown (fail open).
const getLibraryRuntimeConfig = vi.hoisted(() => vi.fn());
const getModelFacts = vi.hoisted(() => vi.fn());
const getModelFactsRevision = vi.hoisted(() => vi.fn());
const getModelTransport = vi.hoisted(() => vi.fn());
const getRelayRuntimeConfig = vi.hoisted(() => vi.fn());
const resolveCatalogModel = vi.hoisted(() => vi.fn());
const isMetadataSnapshotConfirmed = vi.hoisted(() => vi.fn());
const getProviderCatalogStatus = vi.hoisted(() => vi.fn(() => 'loaded'));
// The modelFacts revision held in the local IDB: after a page refresh, peek cannot see it before it is loaded.
const factsState = vi.hoisted(() => ({ loaded: true, revision: undefined as string | undefined }));
const ensurePersistedModelFacts = vi.hoisted(() => vi.fn(async () => { factsState.loaded = true; }));

vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  // The badge / MCP read points also read other metadata exports: everything else uses the production implementation.
  ...(await importOriginal<typeof import('../../metadata/metadata-client')>()),
  getLibraryRuntimeConfig,
  getModelFacts,
  getModelFactsRevision,
  peekModelFactsRevision: () => (factsState.loaded ? factsState.revision : undefined),
  ensurePersistedModelFacts,
  normalizeModelFactsID: (id: string) => id,
  getRelayRuntimeConfig: () => ({ transportEnvelopes: {}, officialProviderWhitelist: [] }),
  getModelTransport,
  getRelayRuntimeConfig,
  isMetadataSnapshotConfirmed,
  getProviderCatalogStatus,
  resolveCatalogModel,
}));

vi.mock('../../../infra/storage/partition', () => ({ getActiveUIDSync: () => 'acct-1' }));

import { isLibraryAgentSupported } from '../routing';
import { DEFAULT_LIBRARY_RUNTIME_CONFIG, type LibraryRuntimeConfig } from '../types';
import { effectiveCapabilityTransport } from '../../chat/capability-evidence';
import { connectionSupportsMcpTools } from '../../mcp/mcp-chat';
import { projectModelCapabilityPresentation } from '../../chat/model-capability-presentation';
import { replaceProviderModels } from '../../provider-model-ops';
import { prepareToolCallVerdict } from '../../chat/tool-call-verdict';
import type { StoreApi } from 'zustand';
import type { AppStore } from '../../store/app-store';
import {
  recordToolCallSupportFalse,
  type ToolCallRecoveryIdentity,
} from '../../chat/capability-recovery-runtime';
import { toolCallVerdictForSend } from '../../chat/relay-rejection-loop';

type Verdict = boolean | null;
interface ToolCallOrderCase {
  id: string;
  catalog: { evidence: 'supported' | 'unsupported' | null; topLevelToolCall: boolean } | null;
  modelFacts: boolean | null;
  localDeclaration: boolean | null;
  form?: 'subscription';
  factsRevision: string | null;
  memory: { value: boolean; factsRevision: string | null; declarationEditedAfterRecord: boolean } | null;
  expect: { verdict: Verdict; sendsTools: boolean };
}

const ROOT = resolve(__dirname, '../../../../../../..');
const fixture = JSON.parse(readFileSync(
  resolve(ROOT, 'shared/test-fixtures/capability/tool-call-order.v1.json'), 'utf8',
)) as { cases: ToolCallOrderCase[] };

const config: LibraryRuntimeConfig = { ...DEFAULT_LIBRARY_RUNTIME_CONFIG, serverResearchEnabled: true };
const MODEL_ID = 'gpt-x';
const TRANSPORT = 'openai_chat';
const ACCOUNT_ID = 'acct-1';

function provider(form: ToolCallOrderCase['form']): Provider {
  const authMode = form === 'subscription' ? 'subscription' : 'apiKey';
  return { id: 'p1', kind: 'openAI', apiKey: 'k', authMode, accountId: ACCOUNT_ID } as unknown as Provider;
}

function model(localDeclaration: boolean | null, isManual: boolean): AIModel {
  return {
    id: MODEL_ID,
    isManual,
    name: MODEL_ID,
    capabilities: ['text'],
    toolCall: localDeclaration ?? undefined,
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: 'standard',
    transport: TRANSPORT,
  } as AIModel;
}

// Catalog entry: evidence is the catalog's tool_call evidence; null = evidence absent (the namespace is not delivered),
// and topLevelToolCall is the legacy top-level slot, which by contract cannot be fallen back to as evidence.
function catalogEntry(catalog: NonNullable<ToolCallOrderCase['catalog']>) {
  return {
    canonicalModelId: MODEL_ID,
    toolCall: catalog.topLevelToolCall,
    transport: TRANSPORT,
    ...(catalog.evidence === null ? {} : {
      capabilityEvidenceCandidates: [{
        key: 'tool_call', support: catalog.evidence, source: 'server_typed', grade: 'machine_verified',
        scope: 'provider_model_transport', providerKind: 'openAI', modelId: MODEL_ID, transport: TRANSPORT,
      }],
    }),
  };
}


beforeEach(() => {
  vi.clearAllMocks();
  localStorage.clear();
  getModelTransport.mockReturnValue(TRANSPORT);
  getModelFactsRevision.mockReturnValue('facts-r1');
  factsState.loaded = true;
  factsState.revision = 'facts-r1';
  isMetadataSnapshotConfirmed.mockReturnValue(true);
  getProviderCatalogStatus.mockReturnValue('loaded');
});

function storeWith(connection: Provider): StoreApi<AppStore> {
  return { getState: () => ({ providers: [connection], updateProvider: vi.fn() }) } as unknown as StoreApi<AppStore>;
}

function editDeclaration(connection: Provider, before: AIModel, after: AIModel): void {
  replaceProviderModels(storeWith({ ...connection, models: [before] } as Provider), { ...connection, models: [before] } as Provider, [after]);
}

function manualIdentity(connection: Provider, candidate: AIModel): ToolCallRecoveryIdentity {
  return {
    accountId: ACCOUNT_ID,
    connectionId: connection.id,
    authMode: 'apiKey',
    canonicalModelId: MODEL_ID,
    finalTransport: effectiveCapabilityTransport(connection, candidate),
  };
}

describe('tool_call rejection memory is one verdict for every consumer', () => {
  it('modelFacts supported + rejection memory false: no agent loop, MCP off, no tool badge', () => {
    resolveCatalogModel.mockReturnValue(null);
    getModelFacts.mockReturnValue({ toolCall: true });
    const connection = provider(undefined);
    const candidate = model(null, true);
    expect(isLibraryAgentSupported(connection, candidate, config)).toBe(true);
    expect(connectionSupportsMcpTools(connection, candidate)).toBe(true);
    expect(projectModelCapabilityPresentation(connection, candidate).tool).toBe(true);
    recordToolCallSupportFalse(manualIdentity(connection, candidate));
    expect(toolCallVerdictForSend(connection, candidate, manualIdentity(connection, candidate))).toBe(false);
    expect(isLibraryAgentSupported(connection, candidate, config)).toBe(false);
    expect(connectionSupportsMcpTools(connection, candidate)).toBe(false);
    expect(projectModelCapabilityPresentation(connection, candidate).tool).toBe(false);
  });

  it('reload before modelFacts loaded: send path loads the local revision and keeps the memory', async () => {
    resolveCatalogModel.mockReturnValue(null);
    getModelFacts.mockReturnValue({ toolCall: true });
    const connection = provider(undefined);
    const candidate = model(null, true);
    recordToolCallSupportFalse(manualIdentity(connection, candidate));
    // Refresh: memory does not hold the revision yet, the local IDB does.
    factsState.loaded = false;
    await prepareToolCallVerdict(connection, candidate);
    expect(ensurePersistedModelFacts).toHaveBeenCalledOnce();
    expect(toolCallVerdictForSend(connection, candidate, manualIdentity(connection, candidate))).toBe(false);
  });
});

describe('tool-call-order.v1 official connection verdict order', () => {
  it('fixture has cases', () => {
    expect(fixture.cases.length).toBeGreaterThan(0);
  });

  for (const testCase of fixture.cases) {
    it(`TOOL-CALL-ORDER-${testCase.id}`, () => {
      resolveCatalogModel.mockReturnValue(testCase.catalog ? catalogEntry(testCase.catalog) : null);
      getModelFacts.mockReturnValue(testCase.modelFacts === null ? undefined : { toolCall: testCase.modelFacts });
      const connection = provider(testCase.form);
      // Outside the catalog = a hand-added model (the memory is only written for subscription / hand-added models).
      const candidate = model(testCase.localDeclaration, testCase.catalog === null);
      const effectiveTransport = effectiveCapabilityTransport(connection, candidate);
      const identity: ToolCallRecoveryIdentity = {
        accountId: ACCOUNT_ID,
        connectionId: connection.id,
        authMode: connection.authMode ?? 'apiKey',
        canonicalModelId: MODEL_ID,
        finalTransport: effectiveTransport,
      };
      // Only false is recorded; there is no record to preset for memory.value=true. The revision at record time goes through the production write path.
      if (testCase.memory?.value === false) {
        factsState.revision = testCase.memory.factsRevision ?? undefined;
        recordToolCallSupportFalse(identity);
        // The user edits the hand-added declaration: through the production model rewrite entry point, changing the declaration from another value to the fixture value.
        if (testCase.memory.declarationEditedAfterRecord) {
          editDeclaration(connection, { ...candidate, toolCall: testCase.localDeclaration === true ? false : true }, candidate);
        }
      }
      factsState.revision = testCase.factsRevision ?? undefined;
      getModelFactsRevision.mockReturnValue(testCase.factsRevision ?? undefined);

      // The production verdict of the send path (the library send and MCP send share this one function);
      // whether tools are sent = the routing gate isLibraryAgentSupported and the verdict not being false.
      const verdict = toolCallVerdictForSend(connection, candidate, identity);
      expect({
        verdict,
        sendsTools: isLibraryAgentSupported(connection, candidate, config) && verdict !== false,
      }).toEqual(testCase.expect);
    });
  }
});
