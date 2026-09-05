import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import type { ReasoningMode } from '@oriveo/shared/pure-types';
import { providerDefaults } from '@oriveo/config';
import { buildProviderRequest } from '../dispatch';
import type { RuntimeMetadataResponse } from '../runtime';
import type { GenerationParameterOverrides, ProviderRequest, RequestParams } from '../types';

/**
 * Regression guard for endpoint shape variants. A live catalog once shipped the
 * "baseUrl=bare origin + endpoints=full path" shape, dispatch handed the bare origin straight to the
 * builder, which joined a short path onto it, and 9 providers hit an endpoint missing its version
 * segment. The shared contract fixture only carried the normalized shape (baseUrl with the version
 * segment), so the harness stayed green and hid the gap.
 *
 * This test rewrites the metadata transport of every shared fixture into the full-path shape, reruns
 * all contract cases and asserts endpointPath matches the normalized shape exactly: the same contract
 * must reach the same upstream endpoint under either shape.
 */

interface ContractCase {
  caseId: string;
  intent: {
    providerKind: RequestParams['providerKind'];
    modelId: string;
    reasoningMode?: ReasoningMode;
    webSearch?: boolean;
    imageGen?: boolean;
    generationOverrides?: GenerationParameterOverrides;
  };
  expect: { endpointPath: string };
}

interface ContractFile {
  version: number;
  metadata: RuntimeMetadataResponse;
  cases: ContractCase[];
}

function findContractPath(): string {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'shared', 'model-contracts', 'request_shape_contract.v1.json');
    if (existsSync(candidate)) return candidate;
    const parent = path.dirname(current);
    if (parent === current) throw new Error('request_shape_contract.v1.json not found');
    current = parent;
  }
}

function loadContract(): ContractFile {
  return JSON.parse(readFileSync(findContractPath(), 'utf8')) as ContractFile;
}

/**
 * Normalized shape -> full-path shape:
 * baseUrl drops back to a bare origin and its former path prefix is merged into each endpoint.
 * Example: baseUrl=https://api.openai.com/v1 + chat=/chat/completions
 *   → baseUrl=https://api.openai.com + chat=/v1/chat/completions
 */
function toFullPathShape(metadata: RuntimeMetadataResponse): RuntimeMetadataResponse {
  const clone = JSON.parse(JSON.stringify(metadata)) as RuntimeMetadataResponse;
  for (const provider of Object.values(clone.providers ?? {})) {
    const transport = provider.transport;
    if (!transport?.baseUrl) continue;
    const url = new URL(transport.baseUrl);
    const basePath = url.pathname.replace(/\/+$/, '');
    if (!basePath || basePath === '/') continue;
    transport.baseUrl = url.origin;
    if (transport.endpoints) {
      for (const [key, value] of Object.entries(transport.endpoints)) {
        if (typeof value === 'string' && value.startsWith('/')) {
          (transport.endpoints as Record<string, string>)[key] = `${basePath}${value}`;
        }
      }
    }
  }
  return clone;
}

function makeRequestParams(contractCase: ContractCase): RequestParams {
  return {
    providerKind: contractCase.intent.providerKind,
    apiKey: 'contract-test-key',
    modelID: contractCase.intent.modelId,
    messages: [{ role: 'user', content: 'hello' }],
    options: {
      reasoning: contractCase.intent.reasoningMode,
      supportsWebSearch: contractCase.intent.webSearch,
      supportsImageGen: contractCase.intent.imageGen,
      ...(contractCase.intent.generationOverrides
        ? { generationParameters: contractCase.intent.generationOverrides }
        : {}),
    },
  };
}

function hasLegacyModelControlIntent(contractCase: ContractCase): boolean {
  return (
    contractCase.intent.webSearch === true
    || contractCase.intent.generationOverrides != null
    || (contractCase.intent.imageGen !== true && contractCase.intent.reasoningMode != null)
  );
}

function makeNoAutomaticModelControlRequestParams(contractCase: ContractCase): RequestParams {
  return {
    providerKind: contractCase.intent.providerKind,
    apiKey: 'contract-test-key',
    modelID: contractCase.intent.modelId,
    messages: [{ role: 'user', content: 'hello' }],
    options: {
      reasoning: 'automatic',
      supportsWebSearch: false,
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

describe('transport shape variants (v27 full-path form)', () => {
  const contract = loadContract();
  const fullPathMetadata = toFullPathShape(contract.metadata);

  for (const contractCase of contract.cases) {
    it(`${contractCase.caseId} resolves same endpointPath under full-path transport`, async () => {
      const normalizedRequest = await buildProviderRequest(
        makeRequestParams(contractCase),
        async () => contract.metadata,
      );
      const fullPathRequest = await buildProviderRequest(
        makeRequestParams(contractCase),
        async () => fullPathMetadata,
      );
      expect(fullPathRequest).toEqual(normalizedRequest);

      if (hasLegacyModelControlIntent(contractCase)) {
        const baseline = await buildProviderRequest(
          makeNoAutomaticModelControlRequestParams(contractCase),
          async () => fullPathMetadata,
        );
        expect(requestWireShape(fullPathRequest)).toEqual(requestWireShape(baseline));
      } else {
        // image-only and no-model-control v1 cases remain authoritative shape evidence.
        expect(new URL(fullPathRequest.url).pathname).toBe(contractCase.expect.endpointPath);
      }
    });
  }

  it('unknown endpoint shape falls back to providerDefaults instead of mis-joining', async () => {
    // Real incident shape: the catalog shipped miniMax the native protocol endpoint
    // /v1/text/chatcompletion_v2, which does not match the builder's OpenAI-compatible semantics.
    // Expected fail-safe: ignore that transport, fall back to the correct built-in providerDefaults
    // endpoint, and never assemble a wrong URL.
    const broken = JSON.parse(JSON.stringify(contract.metadata)) as RuntimeMetadataResponse;
    const miniMax = broken.providers?.miniMax;
    if (!miniMax?.transport) throw new Error('fixture missing miniMax transport');
    miniMax.transport.baseUrl = 'https://api.minimax.io';
    miniMax.transport.endpoints = { chat: '/v1/text/chatcompletion_v2' } as never;

    const request = await buildProviderRequest(
      makeRequestParams({
        caseId: 'minimax.failsafe',
        intent: { providerKind: 'miniMax', modelId: 'MiniMax-M2.5', reasoningMode: 'deep' as ReasoningMode },
        expect: { endpointPath: '' },
      }),
      async () => broken,
    );

    const expected = new URL(`${providerDefaults.miniMax.defaultBaseURL}/chat/completions`);
    expect(new URL(request.url).pathname).toBe(expected.pathname);
  });
});
