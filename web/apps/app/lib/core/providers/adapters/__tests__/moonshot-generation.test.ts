// @vitest-environment jsdom

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import {
  __resetMetadataClientForTest,
  initMetadata,
} from '../../../metadata/metadata-client';
import {
  buildProviderStreamOptions,
  buildStreamOptionsFromIntent,
  filterGenerationParameterOverrides,
} from '../../../chat/stream-options';
import { sendMessageStream } from '../moonshot';
import type { StreamEvent } from '../../types';
import { resetUnsupportedParamCacheForTesting } from '@oriveo/core/providers/unsupported-param';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../capability-evidence-identity';
import { getActiveUIDSync } from '../../../../infra/storage/partition';

const METADATA = {
  version: 21,
  contractVersion: 1,
  updatedAt: '2026-08-09T00:00:00Z',
  profiles: {
    reasoning: {},
    webSearch: {},
    imageGen: {},
    generation: {
      parameters: {
        temperature: { group: 'sampling', valueSchema: 'number' },
        top_p: { group: 'sampling', valueSchema: 'number' },
        seed: { group: 'sampling', valueSchema: 'integer' },
      },
      templates: {
        openai_chat_completions: {
          transport: 'openai_chat',
          wire: { temperature: 'temperature', top_p: 'top_p', seed: 'seed' },
        },
      },
    },
  },
  providers: {
    moonshot: {
      displayName: 'Moonshot',
      defaultModelId: 'kimi-generation',
      resolveMap: { 'kimi-generation': 'kimi-generation' },
      models: {
        'kimi-generation': {
          canonicalModelId: 'kimi-generation',
          displayName: 'Kimi Generation',
          transport: 'openai_chat',
          capabilities: ['text'],
          profiles: {
            generation: {
              template: 'openai_chat_completions',
              revision: 'generation-r2',
              parameters: [
                { id: 'temperature', support: 'supported', source: 'authoritative_metadata' },
                { id: 'top_p', support: 'unknown', source: 'provider_metadata' },
                { id: 'seed', support: 'unsupported', source: 'authoritative_metadata' },
              ],
            },
          },
          // The generation support matrix has a single source of truth in
          // profiles.generation, and capability evidence is only authoritative for observed
          // capabilities such as tool_call. The server does the same: the lean view strips
          // `generation_parameter/*` candidates one by one, and the full view discards the
          // incoming ones and regenerates them from the profile matrix.
          // This fixture deliberately injects an operator candidate the server would never
          // send, claiming seed is available, and asserts it cannot put back a parameter the
          // profile disallows - locking the fail-closed direction.
          capabilityEvidenceView: {
            schema: 'capability-evidence-view/v1',
            candidates: [{
              key: 'generation_parameter/seed',
              support: 'supported',
              source: 'operator_override',
              grade: 'operator',
              scope: 'provider_model_transport',
              providerKind: 'moonshot',
              modelId: 'kimi-generation',
              transport: 'openai_chat',
              generationRevision: 'generation-r2',
            }],
          },
        },
      },
    },
  },
  providerConfigs: [],
};

const provider = {
  id: 'moonshot-cn',
  kind: 'moonshot',
  status: { kind: 'connected' },
  models: [],
  catalogModels: [],
  apiKey: 'sk-test',
  apiKeyPreview: 'sk-…test',
  baseURLText: 'https://api.moonshot.cn/v1',
} as Provider;

// Deliberately stale production selection object: the current HTTP metadata
// above has revision r2 and three parameters, while this persisted copy only
// knows the previous temperature declaration.
const persistedModel = {
  id: 'kimi-generation',
  name: 'Kimi Generation',
  capabilities: ['text'],
  reasoningModeAvailable: false,
  isAvailable: true,
  isDefault: true,
  priceTier: '',
  transport: 'openai_chat',
  generationProfile: {
    template: 'openai_chat_completions',
    revision: 'generation-r1',
    parameters: [{ id: 'temperature', support: 'supported', source: 'provider_metadata' }],
  },
} as AIModel;

function sseResponse(): Response {
  return new Response('data: [DONE]\n\n', {
    status: 200,
    headers: { 'Content-Type': 'text/event-stream' },
  });
}

async function drain(stream: ReadableStream<StreamEvent>): Promise<void> {
  const reader = stream.getReader();
  while (!(await reader.read()).done) {
    // Drain the production SSE stream so the request has completed.
  }
}

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
  __resetMetadataClientForTest();
  resetUnsupportedParamCacheForTesting();
  resetCapabilityEvidenceIdentitiesForTesting();
});

describe('Moonshot China direct generation parameters', () => {
  it('uses current normalized profile and writes only the app facade-filtered parameters', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(new Response(JSON.stringify(METADATA), {
        status: 200,
        headers: { 'Content-Type': 'application/json', ETag: '"metadata-r2"' },
      }))
      .mockResolvedValueOnce(sseResponse());
    await initMetadata();

    const requested = {
      temperature: { state: 'value' as const, value: 0.25 },
      top_p: { state: 'value' as const, value: 0.8 },
      seed: { state: 'value' as const, value: 7 },
    };
    const preliminary = buildProviderStreamOptions(
      provider,
      buildStreamOptionsFromIntent(persistedModel, 'automatic', false, requested),
      persistedModel,
    );
    const filtered = filterGenerationParameterOverrides(
      provider,
      persistedModel,
      requested,
      preliminary,
    );
    const finalOptions = buildProviderStreamOptions(
      provider,
      buildStreamOptionsFromIntent(persistedModel, 'automatic', false, filtered),
      persistedModel,
    );

    // `top_p` has support=unknown (no official documentation was found), so an explicitly
    // supplied 0.8 is sent as-is; asserting it was dropped would contradict the frozen
    // capability_evidence_contract.v1 `official.explicit.*` rule.
    // `seed` is unsupported in the profile matrix, which is a real conclusion, so it is
    // still not sent: this reverse assertion proves the relaxation was not implemented as
    // always-true. profiles.generation is the only source of truth, so the fixture
    // candidate above claiming seed is available must have no effect - otherwise it fails open.
    expect(filtered).toEqual({ temperature: requested.temperature, top_p: requested.top_p });
    expect(finalOptions?.generationProfile).toMatchObject({
      revision: 'generation-r2',
      wire: { temperature: 'temperature', top_p: 'top_p', seed: 'seed' },
    });

    const handle = sendMessageStream(
      provider.apiKey,
      persistedModel.id,
      [{ role: 'user', content: 'hello' }],
      provider.baseURLText!,
      finalOptions,
    );
    await drain(handle.stream);

    const request = fetchMock.mock.calls[1]?.[1];
    const body = JSON.parse(String(request?.body)) as Record<string, unknown>;
    expect(body.temperature).toBe(0.25);
    expect(body.top_p).toBe(0.8);
    expect(body.seed).toBeUndefined();
  });

  // The negative cache is retired: executeWithUnsupportedParamSelfHeal
  // (`packages/core/src/providers/unsupported-param.ts`) no longer pre-strips parameters and
  // no longer scans error bodies to retry silently; `markUnsupportedParamDropped` has no
  // production caller left in the workspace. A deterministic 400 offers only an explicit
  // user-initiated resend. The assertion is therefore inverted to the new semantics: even a
  // complete connection identity may not rewrite generation parameters the user filled in.
  // The identity is still injected (the capabilityIdentity assertion below is unchanged, as
  // telemetry and recovery partitioning still need it), but it is no longer a stripping switch.
  it('does not pre-strip with a complete identity: explicitly supplied parameters are sent on every message', async () => {
    resetUnsupportedParamCacheForTesting();
    const bodies: Array<Record<string, unknown>> = [];
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (_url, init) => {
      const raw = (init as RequestInit | undefined)?.body;
      if (raw === undefined) {
        return new Response(JSON.stringify(METADATA), {
          status: 200,
          headers: { 'Content-Type': 'application/json', ETag: '"metadata-r2"' },
        });
      }
      bodies.push(JSON.parse(String(raw)) as Record<string, unknown>);
      return bodies.length === 1
        ? new Response('does not support parameter temperature', { status: 400 })
        : sseResponse();
    });
    await initMetadata();
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);

    const requested = { temperature: { state: 'value' as const, value: 0.25 } };
    const options = buildProviderStreamOptions(
      provider,
      buildStreamOptionsFromIntent(persistedModel, 'automatic', false, requested),
      persistedModel,
    );
    expect(options?.capabilityIdentity).toMatchObject({
      connectionInstanceId: provider.id,
      metadataRevision: '"metadata-r2"',
      // The generationRevision for an official provider comes from the model profile revision, not an ETag.
      generationRevision: 'generation-r2',
    });

    for (let attempt = 0; attempt < 2; attempt += 1) {
      await drain(sendMessageStream(
        provider.apiKey,
        persistedModel.id,
        [{ role: 'user', content: 'hello' }],
        provider.baseURLText!,
        options,
      ).stream);
    }

    // One leg per message (no silent third retry), and temperature is never quietly dropped:
    // the first message being rejected with a 400 only surfaces the error to the user, and
    // does not authorize rewriting the second request.
    expect(bodies.map((body) => body.temperature)).toEqual([0.25, 0.25]);
    fetchMock.mockRestore();
  });
});
