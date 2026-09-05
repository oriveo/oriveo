import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import type { ReasoningMode } from '@oriveo/shared/pure-types';
import { buildProviderRequest } from '../dispatch';
import type { RuntimeMetadataResponse } from '../runtime';
import type { GenerationParameterOverrides, ProviderRequest, RequestParams } from '../types';

interface RequestShapeContract {
  version: number;
  metadata: RuntimeMetadataResponse;
  cases: RequestShapeCase[];
  generationProviderKindUniverse: string[];
  generationOutboundExemptions: Array<{ providerKind: string; reason: string }>;
}

interface RequestShapeCase {
  caseId: string;
  intent: {
    providerKind: RequestParams['providerKind'];
    modelId: string;
    reasoningMode?: ReasoningMode;
    webSearch?: boolean;
    imageGen?: boolean;
    /** Generation parameter intent set in the panel; the production dispatch resolves the profile and hands it to the production builder. */
    generationOverrides?: GenerationParameterOverrides;
  };
  expect: RequestShapeExpectation;
}

interface RequestShapeExpectation {
  endpointPath: string;
  headersInclude?: Record<string, unknown>;
  queryExcludes?: string[];
  bodyIncludes?: Record<string, unknown>;
  bodyExcludes?: string[];
}

describe('request_shape_contract.v1', () => {
  const contract = loadContract();

  it('loads fixture v1', () => {
    expect(contract.version).toBe(1);
    expect(contract.metadata.version).toBe(1001);
    expect(contract.cases.map((item) => item.caseId)).toEqual([
      'grok.responses.no_profile_deep',
      'grok.chat.reasoning.fast',
      'grok.responses.web_reasoning.deep',
      'openai.responses.reasoning.deep',
      'openai.responses.automatic_no_injection',
      'openai.responses.web.balanced',
      'openai.responses_xhigh.max',
      'openai.responses_pro.max',
      'openai.responses_pro.fast_clamps_to_no_injection',
      'openai.chat.search_api_web_no_injection',
      'openai.images.route',
      'grok.images.route',
      'anthropic.reasoning_web.deep',
      'anthropic.adaptive_max.max',
      'anthropic.adaptive.deep',
      'anthropic.automatic_no_thinking',
      'gemini.reasoning_web_image.deep',
      'gemini.budget.fast',
      'gemini.level_pro.balanced',
      'gemini.web.automatic',
      'gemini.gemma.deep',
      'gemini.web_retrieval.automatic',
      'deepseek.thinking.fast_disabled',
      'deepseek.thinking.balanced',
      'deepseek.thinking.max',
      'deepseek.automatic_uses_default_level',
      'deepseek_pro.thinking.balanced',
      'moonshot.k3.thinking.deep',
      'grok.responses.effort.balanced',
      'grok45.chat.effort.fast',
      'moonshot.thinking.fast_disabled',
      'moonshot.web_thinking.balanced',
      'mistral.thinking.fast_none',
      'mistral.thinking.deep',
      'mistral.automatic_no_injection',
      'mistral.medium.reasoning_cap_gate_no_injection',
      'qwen.hybrid.max',
      'qwen.web.automatic',
      'qwen.images.route',
      'qwen.images.upstream_default_size',
      'zhipu.thinking.fast_disabled',
      'minimax.m3.thinking.balanced',
      'zhipu.web.automatic',
      'zhipu.images.route',
      'minimax.chat.no_profile',
      'minimax.images.route',
      'siliconflow.thinking.deep',
      'siliconflow.images.route',
      'openrouter.reasoning_web_clamp.max',
      'openrouter.or.max',
      'openrouter.low_high.balanced_clamps_to_fast',
      'openrouter.image.modalities',
      'groq.reasoning.fast',
      'groq.no_profile_no_injection',
      'together.gpt_oss.reasoning.deep',
      'together.no_profile_no_injection',
      'together.images.route',
      'together.images.no_n_variant',
      'fireworks.reasoning.balanced',
      'openai.generation.responses_wire',
      'anthropic.generation.messages_wire',
      'gemini.generation.generate_content_wire',
      'openrouter.generation.chat_wire',
      'grok.generation.chat_wire',
      'deepseek.generation.chat_wire',
      'mistral.generation.chat_wire',
      'groq.generation.chat_wire',
      'together.generation.chat_wire',
      'fireworks.generation.chat_wire',
      'minimax.generation.chat_wire',
      'zhipu.generation.chat_wire',
      'qwen.generation.chat_wire',
      'moonshot.generation.chat_wire',
      'siliconflow.generation.chat_wire',
    ]);
  });

  for (const contractCase of contract.cases) {
    it(`${contractCase.caseId} matches core request builder`, async () => {
      const request = await buildProviderRequest(
        makeRequestParams(contractCase),
        async () => contract.metadata,
      );

      if (hasLegacyModelControlIntent(contractCase)) {
        // v1 has no capabilityRuntime exact recipe. It is still the regression source for
        // endpoint/header/query/image shapes, but a legacy profile must not be used to prove that
        // model controls configure themselves. The production builder has to treat intents with no
        // exact runtime as dormant: identical in shape to the same model requested with automatic,
        // web=false and no generation override.
        const baseline = await buildProviderRequest(
          makeNoAutomaticModelControlRequestParams(contractCase),
          async () => contract.metadata,
        );
        expect(requestWireShape(request)).toEqual(requestWireShape(baseline));
      } else {
        assertProviderRequestMatches(request, contractCase.expect);
      }
    });
  }

  // Completeness guard: every imageGen profile needs its own dispatch case. One provider can have
  // several request shapes, so coverage cannot be judged per provider.
  it('every imageGen profile has a dispatch case', () => {
    const covered = new Set<string>();
    for (const contractCase of contract.cases) {
      if (!contractCase.intent.imageGen) continue;
      const provider = contract.metadata.providers?.[contractCase.intent.providerKind];
      const canonical = provider?.resolveMap?.[contractCase.intent.modelId];
      const profile = canonical ? provider?.models?.[canonical]?.profiles?.imageGen : undefined;
      if (profile) covered.add(profile);
    }
    for (const profile of Object.keys(contract.metadata.profiles?.imageGen ?? {})) {
      expect(covered.has(profile), `imageGen profile ${profile} has no dispatch case`).toBe(true);
    }
  });

  // Structural guard: every kind in ProviderKind must either have a generation case that really
  // sends the user's value upstream, or be listed in generationOutboundExemptions with a reason.
  // This is what catches a panel that is visible and writable while injecting nothing outbound,
  // a state that once passed all four layers of tests green on OpenRouter.
  it('every ProviderKind either ships generation parameters or is explicitly exempt', () => {
    const covered = new Set(
      contract.cases
        .filter((item) => item.intent.generationOverrides)
        .map((item) => item.intent.providerKind as string),
    );
    const exempt = new Map(
      contract.generationOutboundExemptions.map((item) => [item.providerKind, item.reason]),
    );
    expect(contract.generationProviderKindUniverse.length).toBeGreaterThan(0);
    for (const kind of contract.generationProviderKindUniverse) {
      const reason = exempt.get(kind);
      if (reason != null) {
        expect(reason.length, `exempting ${kind} requires a written reason`).toBeGreaterThan(20);
        expect(covered.has(kind), `${kind} is both exempt and has an outbound case, which contradicts itself`).toBe(false);
        continue;
      }
      expect(covered.has(kind), `${kind} has neither a generation outbound case nor an exemption`).toBe(true);
    }
    for (const kind of exempt.keys()) {
      expect(
        contract.generationProviderKindUniverse.includes(kind),
        `exempted ${kind} is not part of ProviderKind`,
      ).toBe(true);
    }
  });

  // Field consumption guard: every parameter id a generation case covers must really appear in that
  // model profile's parameters and have a matching wire entry in the template. Otherwise the case
  // asserts against a field the server never sends, and passing proves nothing.
  it('every generation case only overrides parameters its model profile actually declares', () => {
    for (const contractCase of contract.cases) {
      const overrides = contractCase.intent.generationOverrides;
      if (!overrides) continue;
      const provider = contract.metadata.providers?.[contractCase.intent.providerKind];
      const canonical = provider?.resolveMap?.[contractCase.intent.modelId]
        ?? contractCase.intent.modelId;
      const ref = provider?.models?.[canonical]?.profiles?.generation;
      expect(ref?.template, `${contractCase.caseId} model has no generation profile`).toBeTruthy();
      const wire = contract.metadata.profiles?.generation?.templates?.[ref!.template!]?.wire ?? {};
      const declared = new Set((ref?.parameters ?? []).map((entry) => entry.id));
      for (const key of Object.keys(overrides)) {
        expect(declared.has(key), `${contractCase.caseId} overrides ${key}, which the profile does not declare`).toBe(true);
        expect(wire[key], `${contractCase.caseId} template has no wire path for ${key}`).toBeTruthy();
      }
    }
  });

  // Field consumption guard: every key of an imageGen case's profile.requestDefaults must be
  // consumed by a bodyIncludes assertion, either at the top level or nested under parameters.<key>,
  // to catch drift where the server sends a field the client builder never reads.
  it('every imageGen case consumes its profile requestDefaults', () => {
    for (const contractCase of contract.cases) {
      if (!contractCase.intent.imageGen) continue;
      const provider = contract.metadata.providers?.[contractCase.intent.providerKind];
      const profileName = provider?.models?.[contractCase.intent.modelId]?.profiles?.imageGen;
      if (!profileName) continue;
      const defaults = contract.metadata.profiles?.imageGen?.[profileName]?.requestDefaults ?? {};
      const bodyIncludes = contractCase.expect.bodyIncludes ?? {};
      for (const key of Object.keys(defaults)) {
        const consumed = Object.keys(bodyIncludes).some((p) => p === key || p.endsWith(`.${key}`));
        expect(consumed, `${contractCase.caseId} requestDefaults.${key} is not consumed by bodyIncludes`).toBe(
          true,
        );
      }
    }
  });
});

function loadContract(): RequestShapeContract {
  const contractPath = findContractPath();
  return JSON.parse(readFileSync(contractPath, 'utf8')) as RequestShapeContract;
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

function makeRequestParams(contractCase: RequestShapeCase): RequestParams {
  return {
    providerKind: contractCase.intent.providerKind,
    apiKey: 'contract-test-key',
    modelID: contractCase.intent.modelId,
    messages: [{ role: 'user', content: 'hello' }],
    options: {
      reasoning: contractCase.intent.reasoningMode,
      supportsWebSearch: contractCase.intent.webSearch,
      supportsImageGen: contractCase.intent.imageGen,
      // Pass the intent only, meaning the values set in the panel. The profile is resolved by the
      // production dispatch through resolveGenerationProfile from the fixture metadata; tests never
      // hand-write a profile, because a hand-written one only proves applyGenerationParameters is
      // correct, not that the profile actually served is consumed.
      ...(contractCase.intent.generationOverrides
        ? { generationParameters: contractCase.intent.generationOverrides }
        : {}),
    },
  };
}

function hasLegacyModelControlIntent(contractCase: RequestShapeCase): boolean {
  return (
    contractCase.intent.webSearch === true
    || contractCase.intent.generationOverrides != null
    || (contractCase.intent.imageGen !== true && contractCase.intent.reasoningMode != null)
  );
}

function makeNoAutomaticModelControlRequestParams(contractCase: RequestShapeCase): RequestParams {
  return {
    providerKind: contractCase.intent.providerKind,
    apiKey: 'contract-test-key',
    modelID: contractCase.intent.modelId,
    messages: [{ role: 'user', content: 'hello' }],
    options: {
      reasoning: 'automatic',
      supportsWebSearch: false,
      // image generation is a route choice, not one of R3's dormant automatic controls.
      supportsImageGen: contractCase.intent.imageGen,
    },
  };
}

function requestWireShape(request: ProviderRequest): unknown {
  return {
    url: request.url,
    headers: request.headers,
    body: request.body,
    ...(request.fallback ? { fallback: requestWireShape(request.fallback) } : {}),
  };
}

function assertProviderRequestMatches(
  request: ProviderRequest,
  expectation: RequestShapeExpectation,
): void {
  const url = new URL(request.url);
  expect(url.pathname).toBe(expectation.endpointPath);

  const headers = Object.fromEntries(
    Object.entries(request.headers).map(([key, value]) => [key.toLowerCase(), value]),
  );
  for (const [key, expected] of Object.entries(expectation.headersInclude ?? {})) {
    const actual = headers[key.toLowerCase()];
    if (expected === '*') {
      expect(actual, `header ${key}`).toBeTruthy();
    } else {
      expect(actual, `header ${key}`).toBe(expected);
    }
  }

  for (const key of expectation.queryExcludes ?? []) {
    expect(url.searchParams.has(key), `query ${key}`).toBe(false);
  }

  for (const [pathKey, expected] of Object.entries(expectation.bodyIncludes ?? {})) {
    const actual = valueAtPath(request.body, pathKey);
    if (expected === '*') {
      expect(actual, `body ${pathKey}`).not.toBeUndefined();
    } else {
      expect(actual, `body ${pathKey}`).toEqual(expected);
    }
  }

  for (const pathKey of expectation.bodyExcludes ?? []) {
    expect(valueAtPath(request.body, pathKey), `body ${pathKey}`).toBeUndefined();
  }
}

function valueAtPath(source: unknown, pathKey: string): unknown {
  return pathKey.split('.').reduce<unknown>((current, segment) => {
    if (current == null) return undefined;
    if (Array.isArray(current)) {
      const index = Number(segment);
      return Number.isInteger(index) ? current[index] : undefined;
    }
    if (typeof current === 'object') {
      return (current as Record<string, unknown>)[segment];
    }
    return undefined;
  }, source);
}
