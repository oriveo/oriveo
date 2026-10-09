import 'fake-indexeddb/auto';
// @vitest-environment jsdom
//
// Engines that run models locally (contract "engines that run models themselves: channels and parameter tables").
// 1. The in-app constant table is reconciled row by row with localEngineProfiles in the shared rules file.
// 2. Each localEngineCases entry goes through the production chain: production buildProviderStreamOptions
//    resolves the profile, production sendRelayStream assembles and sends the request body, and the
//    assertions only look at the final body captured by the transport. The dropped list is what the
//    production writer returns for that same production profile.

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { sendRelayStream, type RelayOrchestratorDeps } from '@oriveo/core/providers/relay-orchestrator';
import { writeGenerationParameters } from '@oriveo/core/providers/request-builders/generation-parameters';
import type { GenerationParameterOverrides } from '@oriveo/core/providers/request-builders/types';
import { __resetMetadataClientForTest } from '../../metadata/metadata-client';
import { buildProviderStreamOptions, resolveGenerationProfileForModel } from '../stream-options';
import { LOCAL_ENGINE_PROFILES } from '../local-engine-profiles';

type Row = Record<string, unknown> & { id: string };
type Rules = { localEngineProfiles: Record<string, Record<string, { template: string; parameters: Row[] }>> };
type EngineCase = {
  caseId: string;
  engine: string;
  transport: string;
  overrides: GenerationParameterOverrides;
  expect: {
    bodyIncludes: Record<string, unknown>;
    numericFields: string[];
    bodyExcludes: string[];
    dropped: Array<{ parameterId: string; reason: string }>;
  };
};

const rules = loadJSON<Rules>('generation_parameter_contract.v1.json');
const cases = loadJSON<{ localEngineCases: EngineCase[] }>('generation_parameter_contract.v1.cases.json').localEngineCases;

function makeProvider(engine: string, transport: string, baseURL: string): Provider {
  return {
    id: `local-${engine}-${transport}`,
    kind: 'relay',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: '',
    apiKeyPreview: '',
    baseURLText: baseURL,
    relayRequested: { transport, engineProfile: engine, authMode: 'none', securityMode: 'local_http', resolvedAPIBaseURL: baseURL },
  } as unknown as Provider;
}

function makeModel(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: 'local-model',
    name: 'local-model',
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    ...overrides,
  } as AIModel;
}

async function outboundBody(
  provider: Provider,
  model: AIModel,
  overrides: GenerationParameterOverrides,
): Promise<Record<string, unknown>> {
  const options = buildProviderStreamOptions(provider, { generationParameters: overrides }, model);
  let captured: Record<string, unknown> | undefined;
  const deps: RelayOrchestratorDeps = {
    transport: {
      fetch: async (_url, init) => {
        captured = JSON.parse(String(init.body)) as Record<string, unknown>;
        return new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }], content: 'ok' }), { status: 200 });
      },
    },
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
  const handle = sendRelayStream('', model.id, [{ role: 'user', content: 'hello' }], provider.baseURLText, {
    ...options,
    relayStream: false,
  }, deps);
  await handle.stream.getReader().read();
  expect(captured, 'the production relay send path did not issue a request').toBeDefined();
  return captured!;
}

beforeEach(() => {
  localStorage.clear();
  __resetMetadataClientForTest();
});

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('in-app constant table vs. localEngineProfiles in the rules file, row by row', () => {
  const contractRows = Object.entries(rules.localEngineProfiles).flatMap(([engine, channels]) =>
    Object.entries(channels).flatMap(([transport, table]) => table.parameters.map((row) => ({ engine, transport, row }))));

  it('total row count is 108', () => {
    expect(contractRows).toHaveLength(108);
    const localCount = Object.values(LOCAL_ENGINE_PROFILES)
      .flatMap((channels) => Object.values(channels))
      .reduce((sum, table) => sum + table.parameters.length, 0);
    expect(localCount).toBe(108);
  });

  for (const [engine, channels] of Object.entries(rules.localEngineProfiles)) {
    for (const [transport, table] of Object.entries(channels)) {
      it(`${engine} · ${transport}: template and every row's id/wire/type/range/default/enum match`, () => {
        const local = LOCAL_ENGINE_PROFILES[engine]?.[transport];
        expect(local?.template).toBe(table.template);
        expect(local?.parameters).toEqual(table.parameters);
      });
    }
  }
});

describe('localEngineCases: request bodies produced by the production send path', () => {
  for (const testCase of cases) {
    it(testCase.caseId, async () => {
      const baseURL = testCase.transport === 'llamacpp_native' ? 'http://127.0.0.1:8080' : 'http://127.0.0.1:8080/v1';
      const provider = makeProvider(testCase.engine, testCase.transport, baseURL);
      const model = makeModel();
      const body = await outboundBody(provider, model, testCase.overrides);
      expect(body).toMatchObject(testCase.expect.bodyIncludes);
      for (const field of testCase.expect.numericFields) {
        expect(typeof body[field], `${field} must go out as a JSON number`).toBe('number');
      }
      for (const field of testCase.expect.bodyExcludes) {
        expect(body, `${field} must not appear in the request body`).not.toHaveProperty(field);
      }
      const profile = resolveGenerationProfileForModel(provider, model);
      const { dropped } = writeGenerationParameters({}, testCase.overrides, profile);
      expect(dropped).toEqual(testCase.expect.dropped);
    });
  }

  it('has 9 cases and none are skipped', () => {
    expect(cases).toHaveLength(9);
  });
});

describe('the profile is derived from the constant table on read, so a stale persisted profile cannot take over', () => {
  it('a llama.cpp model carrying a persisted generationProfile still goes out per the constant table', async () => {
    const provider = makeProvider('llamacpp', 'openai_chat_completions', 'http://127.0.0.1:8080/v1');
    const model = makeModel({
      generationProfile: { template: 'llamacpp_native', parameters: [{ id: 'temperature', support: 'accepted_unverified', source: 'user_declared' }] },
    } as Partial<AIModel>);
    const profile = resolveGenerationProfileForModel(provider, model);
    expect(profile?.template).toBe('openai_chat_completions');
    expect(profile?.wire.max_output_tokens).toBe('max_tokens');
    const body = await outboundBody(provider, model, { mirostat_tau: { state: 'value', value: 7.5 } });
    expect(body.mirostat_tau).toBe(7.5);
  });
});

describe('three real request bodies', () => {
  const schema = { type: 'object', properties: { a: { type: 'string' } } };

  it('llama.cpp chat: numbers stay numbers, response_format carries strict, and max tokens is omitted when unset', async () => {
    const provider = makeProvider('llamacpp', 'openai_chat_completions', 'http://127.0.0.1:8080/v1');
    const body = await outboundBody(provider, makeModel(), {
      temperature: { state: 'value', value: 0.6 },
      top_k: { state: 'value', value: 30 },
      json_schema: { state: 'value', value: schema },
    });
    expect(body.temperature).toBe(0.6);
    expect(body.top_k).toBe(30);
    expect(body.response_format).toEqual({ type: 'json_schema', json_schema: { name: 'oriveo_response', strict: true, schema } });
    expect(body).not.toHaveProperty('max_tokens');
    expect(body).not.toHaveProperty('n_predict');
    expect(body).not.toHaveProperty('json_schema');
  });

  it('vLLM: extension parameters sit at the top level with no extra_body', async () => {
    const provider = makeProvider('vllm', 'openai_chat_completions', 'http://127.0.0.1:8000/v1');
    const body = await outboundBody(provider, makeModel(), {
      top_k: { state: 'value', value: 20 },
      min_p: { state: 'value', value: 0.1 },
      repeat_penalty: { state: 'value', value: 1.05 },
      min_tokens: { state: 'value', value: 2 },
      ignore_eos: { state: 'value', value: false },
      skip_special_tokens: { state: 'value', value: true },
    });
    expect(body).toMatchObject({ top_k: 20, min_p: 0.1, repetition_penalty: 1.05, min_tokens: 2, ignore_eos: false, skip_special_tokens: true });
    expect(body).not.toHaveProperty('extra_body');
  });

  it('llama.cpp native: n_predict and a top-level json_schema', async () => {
    const provider = makeProvider('llamacpp', 'llamacpp_native', 'http://127.0.0.1:8080');
    const body = await outboundBody(provider, makeModel(), {
      max_output_tokens: { state: 'value', value: 128 },
      json_schema: { state: 'value', value: schema },
    });
    expect(body.n_predict).toBe(128);
    expect(body.json_schema).toEqual(schema);
    expect(typeof body.prompt).toBe('string');
    expect(body).not.toHaveProperty('response_format');
    expect(body).not.toHaveProperty('max_tokens');
  });
});

function loadJSON<T>(fileName: string): T {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'shared', 'model-contracts', fileName);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`shared contract ${fileName} not found`);
    current = parent;
  }
}
