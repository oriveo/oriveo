import 'fake-indexeddb/auto';
// @vitest-environment jsdom
//
// Shared contract "model-level parameter facts registered per upstream", decoding side: every
// modelLevelResolveCases entry is fed through the production metadata decoding path (cache ->
// initMetadata -> resolveCatalogModel -> resolveGenerationProfileRef) and the resolved profile is
// asserted. The platform-level fixture holds only default definitions: temperature 0-2, and
// temperature and Top P are not mutually exclusive.

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sendRelayStream, type RelayOrchestratorDeps } from '@oriveo/core/providers/relay-orchestrator';
import {
  clearWireHardeningDiagnostics,
  readWireHardeningDiagnostics,
} from '@oriveo/core/providers/request-builders/generation-parameters';
import type { GenerationParameterProfile } from '@oriveo/core/providers/request-builders/types';
import {
  __resetMetadataClientForTest,
  __seedMetadataCacheForTest,
  initMetadata,
  resolveCatalogModel,
  resolveGenerationProfileRef,
} from '../metadata-client';

interface ResolveCase {
  caseId: string;
  model: { template: string; parameters: Array<Record<string, unknown> & { id: string }> };
  expect: {
    parameters: Record<string, Record<string, unknown>>;
    parameterIds?: string[];
    wire: Record<string, string>;
    wireRejections?: Array<{ parameterId: string; reason: string }>;
  };
}

const cases = loadJSON<{ modelLevelResolveCases: ResolveCase[] }>(
  'generation_parameter_contract.v1.cases.json',
).modelLevelResolveCases;

const RELAY_CHAT_MODEL = 'relay-chat-fixture';
const schema = { type: 'object', properties: { answer: { type: 'string' } }, required: ['answer'] };

function modelEntry(id: string, generation: ResolveCase['model']) {
  return { canonicalModelId: id, transport: generation.template, profiles: { generation } };
}

const models: Record<string, unknown> = Object.fromEntries(
  cases.map((item, index) => [`case-${index}`, modelEntry(`case-${index}`, item.model)]),
);
models[RELAY_CHAT_MODEL] = modelEntry(RELAY_CHAT_MODEL, {
  template: 'openai_chat_completions',
  parameters: [
    { id: 'max_output_tokens', support: 'supported', source: 'authoritative_metadata', wire: 'max_completion_tokens' },
    { id: 'json_schema', support: 'supported', source: 'provider_metadata', strict: true },
  ],
});

const METADATA_FIXTURE = {
  version: 1,
  contractVersion: 1,
  updatedAt: '2026-10-08T00:00:00Z',
  profiles: {
    reasoning: {},
    webSearch: {},
    imageGen: {},
    generation: {
      parameters: {
        max_output_tokens: { group: 'budget', valueSchema: 'integer', range: { min: 1 } },
        temperature: { group: 'sampling', valueSchema: 'number', range: { min: 0, max: 2, step: 0.01 } },
        top_p: { group: 'sampling', valueSchema: 'number', range: { minExclusive: 0, max: 1, step: 0.01 } },
        json_schema: { group: 'output_contract', valueSchema: 'json-schema', conflictsWith: ['tools', 'response_format'] },
        response_format: { group: 'output_contract', valueSchema: 'enum', enumValues: ['text', 'json'] },
      },
      templates: {
        openai_chat_completions: {
          transport: 'openai_chat_completions',
          wire: {
            max_output_tokens: 'max_tokens',
            temperature: 'temperature',
            top_p: 'top_p',
            json_schema: 'response_format',
            response_format: 'response_format',
          },
        },
        anthropic_messages: {
          transport: 'anthropic_messages',
          wire: {
            max_output_tokens: 'max_tokens',
            temperature: 'temperature',
            top_p: 'top_p',
            json_schema: 'output_config.format',
          },
        },
      },
    },
  },
  providers: {
    openAI: {
      resolveMap: Object.fromEntries(Object.keys(models).map((id) => [id, id])),
      models,
    },
  },
  providerConfigs: [],
};

function resolveProfile(modelID: string): GenerationParameterProfile | undefined {
  return resolveGenerationProfileRef(resolveCatalogModel(modelID, 'openAI')?.profiles.generation);
}

beforeAll(async () => {
  __resetMetadataClientForTest();
  await __seedMetadataCacheForTest({ data: METADATA_FIXTURE as never, timestamp: Date.now() });
  await initMetadata();
});

afterAll(() => {
  __resetMetadataClientForTest();
});

describe('modelLevelResolveCases (shared contract, case by case, through production metadata decoding)', () => {
  it('the case group size is frozen at 11', () => {
    expect(cases).toHaveLength(11);
  });

  cases.forEach((item, index) => {
    it(item.caseId, () => {
      clearWireHardeningDiagnostics();
      const profile = resolveProfile(`case-${index}`);
      expect(profile, 'production decoding did not produce a profile').toBeDefined();
      for (const [id, expected] of Object.entries(item.expect.parameters)) {
        const parameter = profile!.parameters.find((entry) => entry.id === id);
        expect(parameter, `parameter ${id} is missing from the resolved result`).toBeDefined();
        for (const [field, value] of Object.entries(expected)) {
          // Default semantics: an omitted conflictsWith means not mutually exclusive, and an omitted strict means not written.
          const actual = field === 'conflictsWith'
            ? parameter!.conflictsWith ?? []
            : field === 'strict'
              ? parameter!.strict === true
              : (parameter as Record<string, unknown>)[field];
          expect(actual, `${id}.${field}`).toEqual(value);
        }
      }
      if (item.expect.parameterIds) {
        expect(profile!.parameters.map((entry) => entry.id)).toEqual(item.expect.parameterIds);
      }
      for (const [id, wirePath] of Object.entries(item.expect.wire)) {
        expect(profile!.wire[id], `wire ${id}`).toBe(wirePath);
      }
      const rejections = item.expect.wireRejections ?? [];
      for (const rejection of rejections) {
        // An invalid model-level wire leaves the parameter without a write path; it does not fall back to the template's path.
        expect(profile!.wire).not.toHaveProperty(rejection.parameterId);
      }
      expect(readWireHardeningDiagnostics().map(({ parameterId, reason }) => ({ parameterId, reason })))
        .toEqual(rejections);
    });
  });

  it('resolving the same invalid model-level wire repeatedly records only one diagnostic', () => {
    const index = cases.findIndex((item) => item.expect.wireRejections?.length);
    expect(index).toBeGreaterThanOrEqual(0);
    clearWireHardeningDiagnostics();
    resolveProfile(`case-${index}`);
    resolveProfile(`case-${index}`);
    expect(readWireHardeningDiagnostics()).toHaveLength(1);
  });
});

describe('Relay Chat production send path: decoded model-level facts go out on the wire', () => {
  it('max tokens is written as max_completion_tokens and the JSON Schema carries strict', async () => {
    const profile = resolveProfile(RELAY_CHAT_MODEL);
    expect(profile?.wire.max_output_tokens).toBe('max_completion_tokens');
    let captured: Record<string, unknown> | undefined;
    const deps: RelayOrchestratorDeps = {
      transport: {
        fetch: async (_url, init) => {
          captured = JSON.parse(String(init.body)) as Record<string, unknown>;
          return new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), { status: 200 });
        },
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    };
    const handle = sendRelayStream(
      'sk-relay',
      RELAY_CHAT_MODEL,
      [{ role: 'user', content: 'hello' }],
      'https://relay.example/v1',
      {
        relayStream: false,
        relayTransport: 'openai_chat_completions',
        generationProfile: profile,
        generationParameters: {
          max_output_tokens: { state: 'value', value: 2048 },
          json_schema: { state: 'value', value: schema },
        },
      },
      deps,
    );
    const reader = handle.stream.getReader();
    while (!(await reader.read()).done) { /* drain the whole stream */ }
    expect(captured, 'the production relay send path did not send a request').toBeDefined();
    expect(captured!.max_completion_tokens).toBe(2048);
    expect(captured).not.toHaveProperty('max_tokens');
    expect(captured!.response_format).toEqual({
      type: 'json_schema', json_schema: { name: 'oriveo_response', strict: true, schema },
    });
  });
});

function loadJSON<T>(fileName: string): T {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'shared', 'model-contracts', fileName);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${fileName} not found`);
    current = parent;
  }
}
