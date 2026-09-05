import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { buildAnthropicRequest } from '../anthropic';
import { buildGeminiRequest } from '../gemini';
import { buildGrokRequest } from '../grok';
import { buildOpenAICompatibleRequest } from '../openai-compatible';
import {
  applyGenerationParameters,
  clearWireHardeningDiagnostics,
  readWireHardeningDiagnostics,
  restrictWireToDeclaredParameters,
  wireRejectionReason,
} from '../generation-parameters';
import { deepMerge, resolveGenerationProfile, type RuntimeMetadataResponse } from '../runtime';
import type { GenerationParameterProfile, ProviderRequest, RequestParams } from '../types';

type Override =
  | { state: 'inherit' }
  | { state: 'omit' }
  | { state: 'value'; value: number };

interface ContractCase {
  caseId: string;
  intent: {
    transport:
      | 'openai_chat_completions'
      | 'openai_responses'
      | 'anthropic_messages'
      | 'gemini_generate_content';
    authMode: string;
    modelId: string;
    override: Override;
  };
  expect: {
    headersInclude?: Record<string, unknown>;
    headersExclude?: string[];
    bodyIncludes?: Record<string, unknown>;
    bodyExcludes?: string[];
  };
}

interface WireHardeningCase {
  caseId: string;
  wire: string;
  value: number;
  expect: { applied: boolean; reason: string | null };
}

interface GenerationParameterContract {
  version: number;
  schema: {
    support: string[];
    overrideStates: string[];
    groups: string[];
    fingerprintFields: string[];
  };
  cases: ContractCase[];
  wireHardening: {
    segmentPattern: string;
    blockedSegments: string[];
    maxSegments: number;
    builderOwnedRootFields: string[];
    jsonSchemaLimits: { maxBytes: number; maxDepth: number };
  };
  wireHardeningCases: WireHardeningCase[];
  lifecycleCases: Array<{
    caseId: string;
    intent: { storedState: 'value' | 'omit'; support?: string };
    expect: { lifecycle: 'active' | 'dormant' };
  }>;
}

describe('generation_parameter_contract.v1 red proof', () => {
  const contract = loadContract();

  it('freezes all groups, support states, override states, and fingerprint fields', () => {
    expect(contract.version).toBe(1);
    expect(contract.schema.groups).toEqual([
      'budget',
      'reasoning',
      'sampling',
      'repetition',
      'reproducibility',
      'output_contract',
      'engine_runtime',
    ]);
    // The schema originally declared only six values while the case data in this file already
    // used eight literals (accepted and future_supported were never declared). The data wins, and
    // the order follows the three-class mapping table.
    expect(contract.schema.support).toEqual([
      'supported',
      'accepted',
      'accepted_unverified',
      'fixed',
      'unsupported',
      'mode_dependent',
      'unknown',
      'future_supported',
    ]);
    expect(contract.schema.overrideStates).toEqual(['inherit', 'value', 'omit']);
    expect(contract.schema.fingerprintFields).toHaveLength(6);
    expect(contract.cases).toHaveLength(12);
  });

  for (const item of contract.cases) {
    it(`${item.caseId} matches a production request builder`, () => {
      const request = buildProductionRequest(item);
      assertRequest(request, item);
    });
  }

  it('keeps official models at zero optional injection without a metadata profile', () => {
    const body: Record<string, unknown> = {};
    applyGenerationParameters(
      body,
      { temperature: { state: 'value', value: 0 } },
      undefined,
    );
    expect(body).toEqual({});
  });

  it('rejects mutually exclusive active parameters before a request is sent', () => {
    const body: Record<string, unknown> = {};
    expect(() => applyGenerationParameters(
      body,
      {
        temperature: { state: 'value', value: 0.2 },
        top_p: { state: 'value', value: 0.8 },
      },
      {
        template: 'openai_chat_completions',
        wire: { temperature: 'temperature', top_p: 'top_p' },
        parameters: [
          { id: 'temperature', support: 'supported', source: 'test', conflictsWith: ['top_p'] },
          { id: 'top_p', support: 'supported', source: 'test', conflictsWith: ['temperature'] },
        ],
      },
    )).toThrow('temperature conflicts with top_p');
  });

  it('consumes facade-filtered overrides, while real outbound conflicts still fail', () => {
    const profile: GenerationParameterProfile = {
      template: 'openai_chat_completions',
      wire: { temperature: 'temperature', top_p: 'top_p', top_logprobs: 'top_logprobs' },
      parameters: [
        { id: 'temperature', support: 'unsupported', source: 'contract', conflictsWith: ['top_p'] },
        { id: 'top_p', support: 'supported', source: 'contract', conflictsWith: ['temperature'] },
        {
          id: 'top_logprobs', support: 'unsupported', source: 'contract',
          requires: [{ key: 'logprobs', value: true }],
        },
      ],
    };
    const request = buildOpenAICompatibleRequest({
      providerKind: 'relay', apiKey: '', modelID: 'fixture-chat', baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hello' }],
      options: {
        generationProfile: profile,
        generationParameters: {
          // The app facade has already rejected temperature / top_logprobs.
          // Writers must not recreate raw-support eligibility here.
          top_p: { state: 'value', value: 0.8 },
        },
      },
    }, null);
    expect(request.body.temperature).toBeUndefined();
    expect(request.body.top_logprobs).toBeUndefined();
    expect(request.body.top_p).toBe(0.8);

    const conflictingProfile: GenerationParameterProfile = {
      ...profile,
      parameters: profile.parameters.map((parameter) => ({ ...parameter, support: 'supported' })),
    };
    expect(() => buildOpenAICompatibleRequest({
      providerKind: 'relay', apiKey: '', modelID: 'fixture-chat', baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hello' }],
      options: {
        generationProfile: conflictingProfile,
        generationParameters: {
          temperature: { state: 'value', value: 0.2 },
          top_p: { state: 'value', value: 0.8 },
        },
      },
    }, null)).toThrow('temperature conflicts with top_p');
  });

  it('relay unknown omit removes a field from a production request body', () => {
    const fixtureCase = contract.lifecycleCases.find((item) => item.caseId === 'relay.declared.unknown_omit');
    expect(fixtureCase?.intent).toMatchObject({ storedState: 'omit', support: 'unknown' });
    expect(fixtureCase?.expect.lifecycle).toBe('active');

    const profile = resolveGenerationProfile(loadRequestShapeMetadata(), {
      template: 'openai_chat_completions',
      parameters: [{ id: 'temperature', support: 'unknown', source: 'user_declared' }],
    });
    expect(profile).toBeDefined();
    const request = buildOpenAICompatibleRequest({
      providerKind: 'relay', apiKey: '', modelID: 'fixture-chat', baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hello' }],
      options: {
        generationProfile: profile!,
        generationParameters: { temperature: { state: 'omit' } },
      },
    }, { temperature: 0.7 });
    expect(request.body.temperature).toBeUndefined();
  });

  it('enforces metadata value schemas and ranges before a request is sent', () => {
    const profile: GenerationParameterProfile = {
      template: 'openai_chat_completions',
      wire: { max_output_tokens: 'max_tokens' },
      parameters: [{
        id: 'max_output_tokens', support: 'supported', source: 'test',
        valueSchema: 'integer', range: { min: 1, max: 4096 },
      }],
    };
    expect(() => applyGenerationParameters(
      {}, { max_output_tokens: { state: 'value', value: 1.5 } }, profile,
    )).toThrow('max_output_tokens must be an integer');
    expect(() => applyGenerationParameters(
      {}, { max_output_tokens: { state: 'value', value: 0 } }, profile,
    )).toThrow('max_output_tokens must be at least 1');
  });

  it.each([
    ['openai_chat_completions', 'response_format', { type: 'json_schema', json_schema: expect.objectContaining({ strict: true }) }],
    ['openai_responses', 'text.format', expect.objectContaining({ type: 'json_schema', strict: true })],
    ['anthropic_messages', 'output_format', expect.objectContaining({ type: 'json_schema' })],
    ['gemini_generate_content', 'generationConfig.responseJsonSchema', { type: 'object' }],
  ] as const)('maps JSON Schema through the dedicated %s output contract', (template, wirePath, expected) => {
    const body: Record<string, unknown> = {};
    applyGenerationParameters(body, {
      json_schema: { state: 'value', value: { type: 'object' } },
    }, {
      template,
      wire: { json_schema: wirePath },
      parameters: [{ id: 'json_schema', support: 'supported', source: 'contract', valueSchema: 'json-schema' }],
    });
    expect(valueAtPath(body, wirePath)).toEqual(expected);
    if (template === 'gemini_generate_content') {
      expect(valueAtPath(body, 'generationConfig.responseMimeType')).toBe('application/json');
    }
  });

  it('rejects tools/schema conflicts and logprobs dependencies before body mutation', () => {
    const schemaProfile: GenerationParameterProfile = {
      template: 'openai_chat_completions',
      wire: { json_schema: 'response_format', logprobs: 'logprobs', top_logprobs: 'top_logprobs' },
      parameters: [
        { id: 'json_schema', support: 'supported', source: 'contract', valueSchema: 'json-schema', conflictsWith: ['tools'] },
        { id: 'logprobs', support: 'supported', source: 'contract', valueSchema: 'boolean' },
        { id: 'top_logprobs', support: 'supported', source: 'contract', valueSchema: 'integer', requires: [{ key: 'logprobs', value: true }] },
      ],
    };
    expect(() => applyGenerationParameters({}, {
      json_schema: { state: 'value', value: { type: 'object' } },
    }, schemaProfile, { toolsActive: true })).toThrow('json_schema conflicts with tools');
    expect(() => applyGenerationParameters({}, {
      top_logprobs: { state: 'value', value: 5 },
    }, schemaProfile)).toThrow('top_logprobs requires logprobs');
  });
});

/**
 * The wire sent by the server is a write path: the client trusts the semantics, not the shape.
 *
 * Every assertion's input comes from the production chain - the profile is parsed by the
 * production `resolveGenerationProfile` from server-shaped (here malformed) metadata, and the
 * body is produced by the production `buildOpenAICompatibleRequest`. Hand-writing a body and
 * injecting `__proto__` into it would only prove that the test can write a case.
 */
describe('generation_parameter_contract.v1 wire hardening', () => {
  const contract = loadContract();

  it('freezes the shared hardening rule set', () => {
    expect(contract.wireHardening.segmentPattern).toBe('^[A-Za-z_][A-Za-z0-9_]*$');
    expect(contract.wireHardening.blockedSegments).toEqual(['__proto__', 'prototype', 'constructor']);
    expect(contract.wireHardening.maxSegments).toBe(4);
    expect(contract.wireHardening.builderOwnedRootFields).toEqual([
      'model', 'messages', 'input', 'contents', 'prompt', 'attachments', 'instructions', 'system', 'stream', 'stream_options', 'tools', 'tool_choice', 'plugins',
    ]);
    expect(contract.wireHardening.jsonSchemaLimits).toEqual({ maxBytes: 65536, maxDepth: 32 });
    expect(contract.wireHardeningCases.length).toBeGreaterThanOrEqual(15);
  });

  for (const item of contract.wireHardeningCases) {
    it(`${item.caseId} is enforced on a production request builder`, () => {
      clearWireHardeningDiagnostics();
      const request = buildOpenAICompatibleRequest(hostileParams(item), null);

      if (item.expect.applied) {
        expect(valueAtPath(request.body, item.wire), item.caseId).toEqual(item.value);
        expect(readWireHardeningDiagnostics(), item.caseId).toHaveLength(0);
      } else {
        // The builder's own fields already have values, so the test is that this write did not change them, not that they are absent.
        expect(valueAtPath(request.body, item.wire), item.caseId).not.toEqual(item.value);
        expect(readWireHardeningDiagnostics(), item.caseId).toEqual([
          { parameterId: 'temperature', wirePath: item.wire, reason: item.expect.reason },
        ]);
      }

      // The builder's own skeleton must survive untouched: a rejected write must not incidentally change model or messages.
      expect((request.body as Record<string, unknown>).model).toBe('fixture-chat');
      expect(Array.isArray((request.body as Record<string, unknown>).messages)).toBe(true);
      // Prototype pollution surface: neither Object.prototype nor a fresh object may grow a field because of one send.
      expect(Object.prototype).not.toHaveProperty('polluted');
      expect({} as Record<string, unknown>).not.toHaveProperty('polluted');
      expect(({}) as Record<string, unknown>).not.toHaveProperty('include_usage');
    });
  }

  it('leaves every wire path shipped by the real server metadata untouched', () => {
    const metadata = loadRequestShapeMetadata();
    const templates = metadata.profiles.generation?.templates ?? {};
    const paths = Object.values(templates).flatMap((template) => Object.values(template.wire ?? {}));
    expect(paths.length).toBeGreaterThan(0);
    for (const path of paths) {
      expect(wireRejectionReason(path), `real wire path ${path} must stay legal`).toBeNull();
    }
  });

  it('keeps a relay-synthesized profile wire inside the client constant table', () => {
    clearWireHardeningDiagnostics();
    // Simulate an extra key coming from a relay upstream or a server template; the client-side constant table only declares temperature.
    const restricted = restrictWireToDeclaredParameters({
      template: 'openai_chat_completions',
      wire: {
        temperature: 'temperature',
        smuggled_by_relay: '__proto__.polluted',
        also_smuggled: 'messages',
      },
      parameters: [{ id: 'temperature', support: 'unknown', source: 'user_declared' }],
    });
    expect(restricted.wire).toEqual({ temperature: 'temperature' });
    // An undeclared id never reaches the wire, and needs no diagnostic either, since it was never a parameter this client knows.
    expect(readWireHardeningDiagnostics()).toHaveLength(0);
  });

  it('records a diagnostic when a declared parameter carries an illegal path', () => {
    clearWireHardeningDiagnostics();
    const restricted = restrictWireToDeclaredParameters({
      template: 'openai_chat_completions',
      wire: { temperature: 'constructor.prototype.polluted' },
      parameters: [{ id: 'temperature', support: 'unknown', source: 'user_declared' }],
    });
    expect(restricted.wire).toEqual({});
    expect(readWireHardeningDiagnostics()).toEqual([
      { parameterId: 'temperature', wirePath: 'constructor.prototype.polluted', reason: 'blocked_segment' },
    ]);
  });

  it('drops an oversized json_schema instead of shipping it', () => {
    const profile: GenerationParameterProfile = {
      template: 'openai_chat_completions',
      wire: { json_schema: 'response_format' },
      parameters: [{ id: 'json_schema', support: 'supported', source: 'contract', valueSchema: 'json-schema' }],
    };
    const oversized = { type: 'object', title: 'x'.repeat(64 * 1024) };
    expect(() => applyGenerationParameters({}, {
      json_schema: { state: 'value', value: oversized },
    }, profile)).toThrow('json_schema exceeds 64 KiB');
  });
});

describe('profile-owned arrays', () => {
  it('preserves Anthropic builder tools when the production web profile contributes search', () => {
    const request = buildAnthropicRequest({ providerKind: 'anthropic', apiKey: 'key', modelID: 'claude', messages: [{ role: 'user', content: 'hi' }], tools: [{ type: 'function', function: { name: 'weather', description: 'weather', parameters: {} } }], options: { supportsWebSearch: true } }, null, { mergeParams: { tools: [{ type: 'web_search_20250305', name: 'web_search' }] } });
    expect(request.body.tools).toEqual([{ name: 'weather', description: 'weather', input_schema: {} }, { type: 'web_search_20250305', name: 'web_search' }]);
  });
  it('keeps builder tools while a profile contributes a distinct owned tool', () => {
    const body = { tools: [{ type: 'function', name: 'weather' }], plugins: [{ type: 'base', name: 'trace' }] };
    deepMerge(body, {
      tools: [{ type: 'web_search' }, { type: 'function', name: 'weather' }],
      plugins: [{ type: 'web', name: 'search' }, { type: 'base', name: 'trace' }],
    });
    expect(body.tools).toEqual([{ type: 'function', name: 'weather' }, { type: 'web_search' }]);
    expect(body.plugins).toEqual([{ type: 'base', name: 'trace' }, { type: 'web', name: 'search' }]);
  });
  it('does not duplicate an anonymous tool when key order differs', () => {
    const body = { tools: [{ type: 'web_search', config: { b: 2, a: 1 } }] };
    deepMerge(body, { tools: [{ config: { a: 1, b: 2 }, type: 'web_search' }] });
    expect(body.tools).toHaveLength(1);
  });
});

/** The profile for a malformed wire is produced by the production parse chain: server-shaped metadata through resolveGenerationProfile. */
function hostileParams(item: WireHardeningCase): RequestParams {
  const metadata = {
    version: 1,
    updatedAt: '2026-08-08T00:00:00Z',
    profiles: {
      reasoning: {},
      webSearch: {},
      imageGen: {},
      generation: {
        templates: {
          openai_chat_completions: {
            transport: 'openai_chat_completions',
            wire: { temperature: item.wire },
          },
        },
        parameters: { temperature: { group: 'sampling', valueSchema: 'number' } },
      },
    },
    providers: {},
  } as unknown as RuntimeMetadataResponse;

  const profile = resolveGenerationProfile(metadata, {
    template: 'openai_chat_completions',
    parameters: [{ id: 'temperature', support: 'supported', source: 'authoritative_metadata' }],
  });
  if (!profile) throw new Error(`${item.caseId} profile did not resolve`);
  expect(profile.wire.temperature).toBe(item.wire);

  return {
    providerKind: 'relay',
    apiKey: '',
    modelID: 'fixture-chat',
    messages: [{ role: 'user', content: 'hello' }],
    baseURL: 'https://contract.invalid/v1',
    options: {
      generationParameters: { temperature: { state: 'value', value: item.value } },
      generationProfile: profile,
    },
  };
}

function buildProductionRequest(item: ContractCase): ProviderRequest {
  const params: RequestParams = {
    providerKind: providerKind(item.intent.transport),
    apiKey: item.intent.authMode === 'none' ? '' : 'contract-test-key',
    modelID: item.intent.modelId,
    messages: [{ role: 'user', content: 'hello' }],
    baseURL: 'https://contract.invalid/v1',
    options: {
      generationParameters: { temperature: item.intent.override },
      generationProfile: generationProfile(item.intent.transport),
    },
  };

  switch (item.intent.transport) {
    case 'openai_chat_completions':
      return buildOpenAICompatibleRequest(params, null);
    case 'openai_responses':
      return buildGrokRequest(params, null, null, 'openai_responses');
    case 'anthropic_messages':
      return buildAnthropicRequest(params, null, null);
    case 'gemini_generate_content':
      return buildGeminiRequest(params, null, null, null);
  }
}

/**
 * Profiles are always produced by the production parse chain rather than hand-written by tests.
 *
 * The input is the server-shaped `models[...].profiles.generation` reference (a template plus a
 * list of parameter ids) together with the top-level `profiles.generation` schema from the
 * request shape contract fixture, parsed into a runtime profile by the production
 * `resolveGenerationProfile`. A hand-written profile would only prove that
 * `applyGenerationParameters` is self-consistent, not that the shape the server actually sends
 * is consumed, so drift such as a mismatched wire table or a mismatched parameter id would slip
 * through.
 *
 * Each transport's anchor model is one that really declares temperature under that template in
 * the fixture.
 */
const TRANSPORT_PROFILE_ANCHORS: Record<
  ContractCase['intent']['transport'],
  { providerKind: string; modelId: string }
> = {
  openai_chat_completions: { providerKind: 'openRouter', modelId: 'openai/gpt-5.2' },
  openai_responses: { providerKind: 'openAI', modelId: 'gpt-5-mini' },
  anthropic_messages: { providerKind: 'anthropic', modelId: 'claude-sonnet-4-6' },
  gemini_generate_content: { providerKind: 'gemini', modelId: 'gemini-3.1-pro-preview' },
};

function generationProfile(transport: ContractCase['intent']['transport']): GenerationParameterProfile {
  const metadata = loadRequestShapeMetadata();
  const anchor = TRANSPORT_PROFILE_ANCHORS[transport];
  const provider = metadata.providers[anchor.providerKind];
  const canonical = provider?.resolveMap?.[anchor.modelId] ?? anchor.modelId;
  const ref = provider?.models?.[canonical]?.profiles?.generation;
  const profile = resolveGenerationProfile(metadata, ref);
  if (!profile) {
    throw new Error(
      `request_shape_contract.v1.json has no generation profile for ${anchor.providerKind}/${anchor.modelId}`,
    );
  }
  if (profile.template !== transport || !profile.wire.temperature) {
    throw new Error(`the ${transport} anchor model profile does not match that transport: ${profile.template}`);
  }
  return profile;
}

function providerKind(transport: ContractCase['intent']['transport']): RequestParams['providerKind'] {
  switch (transport) {
    case 'openai_chat_completions':
      return 'relay';
    case 'openai_responses':
      return 'grok';
    case 'anthropic_messages':
      return 'anthropic';
    case 'gemini_generate_content':
      return 'gemini';
  }
}

function assertRequest(request: ProviderRequest, item: ContractCase): void {
  const headers = Object.fromEntries(
    Object.entries(request.headers).map(([name, value]) => [name.toLowerCase(), value]),
  );
  for (const name of item.expect.headersExclude ?? []) {
    expect(headers[name.toLowerCase()], `${item.caseId} header ${name}`).toBeUndefined();
  }
  for (const [name, expected] of Object.entries(item.expect.headersInclude ?? {})) {
    const actual = headers[name.toLowerCase()];
    if (expected === '*') expect(actual, `${item.caseId} header ${name}`).toBeTruthy();
    else expect(actual, `${item.caseId} header ${name}`).toEqual(expected);
  }
  for (const [key, expected] of Object.entries(item.expect.bodyIncludes ?? {})) {
    expect(valueAtPath(request.body, key), `${item.caseId} body ${key}`).toEqual(expected);
  }
  for (const key of item.expect.bodyExcludes ?? []) {
    expect(valueAtPath(request.body, key), `${item.caseId} body ${key}`).toBeUndefined();
  }
}

function valueAtPath(source: unknown, key: string): unknown {
  return key.split('.').reduce<unknown>((current, segment) => {
    if (current == null || typeof current !== 'object') return undefined;
    return (current as Record<string, unknown>)[segment];
  }, source);
}

function loadContract(): GenerationParameterContract {
  return JSON.parse(
    readFileSync(findSharedContract('generation_parameter_contract.v1.json'), 'utf8'),
  ) as GenerationParameterContract;
}

function loadRequestShapeMetadata(): RuntimeMetadataResponse {
  return (
    JSON.parse(readFileSync(findSharedContract('request_shape_contract.v1.json'), 'utf8')) as {
      metadata: RuntimeMetadataResponse;
    }
  ).metadata;
}

function findSharedContract(fileName: string): string {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'shared', 'model-contracts', fileName);
    if (existsSync(candidate)) return candidate;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${fileName} not found`);
    current = parent;
  }
}
