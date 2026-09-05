import 'fake-indexeddb/auto';
// @vitest-environment jsdom

// Regression: for a **relay that does not match the official catalog** (a local engine, or an
// ordinary cloud relay whose model id is not in the official catalog), the values set in the panel
// have to actually appear in the JSON sent upstream.

// This file deliberately walks the whole production chain and synthesizes neither StreamOptions nor
// a profile:
//   production write through saveGenerationParameterOverrides (what the panel save uses)
//     -> production merge through resolveGenerationParameterOverrides
//     -> production assembly through buildStreamOptionsFromIntent
//     -> production relay merge through buildProviderStreamOptions (where the chain used to break)
//     -> production relay request build through sendRelayStream (the real relay send path)
//   and the assertions only look at the final body captured by the transport.

// The profiles also come from production resolution: relayGenerationProfile /
// engineGenerationProfile read template.wire out of the production metadata cache, so the test only
// prepares metadata fixtures and never hand-writes a profile object.

import { beforeEach, afterEach, describe, expect, it } from 'vitest';
import type { AIModel, Provider, ReasoningMode } from '@oriveo/shared';
import { sendRelayStream, type RelayOrchestratorDeps } from '@oriveo/core/providers/relay-orchestrator';
import {
  __seedMetadataCacheForTest,
  __resetMetadataClientForTest,
  initMetadata,
} from '../../metadata/metadata-client';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../stream-options';
import {
  generationParameterProfileFingerprint,
  resolveGenerationParameterOverrides,
  saveGenerationParameterOverrides,
} from '../generation-parameter-settings';

const METADATA_FIXTURE = {
  version: 1,
  contractVersion: 1,
  updatedAt: '2026-08-08T00:00:00Z',
  profiles: {
    reasoning: {},
    webSearch: {},
    imageGen: {},
    generation: {
      parameters: {
        temperature: { group: 'sampling', valueSchema: 'number', portability: 'portable' },
        max_output_tokens: { group: 'budget', valueSchema: 'integer', portability: 'portable' },
        top_k: { group: 'sampling', valueSchema: 'integer', portability: 'engine_scoped' },
      },
      templates: {
        openai_chat_completions: {
          transport: 'openai_chat_completions',
          wire: { temperature: 'temperature', max_output_tokens: 'max_tokens', top_k: 'top_k' },
        },
        vllm_extra_body: {
          transport: 'openai_chat_completions',
          wire: { temperature: 'temperature', top_k: 'extra_body.top_k' },
        },
      },
    },
  },
  providers: {},
  providerConfigs: [],
};

function makeRelayProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'relay-d34',
    kind: 'relay',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-relay',
    apiKeyPreview: '••',
    baseURLText: 'https://relay.example/v1',
    relayRequested: { transport: 'openai_chat_completions' },
    ...overrides,
  } as Provider;
}

/** A relay model that misses the official catalog: the absent `generationProfile` is exactly the trigger. */
function makeUnmatchedRelayModel(): AIModel {
  return {
    id: 'my-private-model',
    name: 'my-private-model',
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
  } as AIModel;
}

/** Hand production StreamOptions to the production relay send path and capture the body it really sends. */
async function outboundBody(
  provider: Provider,
  options: ReturnType<typeof buildProviderStreamOptions>,
  modelID: string,
): Promise<Record<string, unknown>> {
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
    modelID,
    [{ role: 'user', content: 'hello' }],
    provider.baseURLText,
    { ...options, relayStream: false },
    deps,
  );
  await handle.stream.getReader().read();
  expect(captured, 'the production relay send path issued no request').toBeDefined();
  return captured!;
}

/** Panel save -> send chain read back -> production StreamOptions (the first four links are all production code). */
function panelToStreamOptions(
  provider: Provider,
  model: AIModel,
  values: Parameters<typeof saveGenerationParameterOverrides>[1],
  reasoningMode: ReasoningMode = 'automatic',
) {
  const scope = {
    providerId: provider.id,
    modelId: model.id,
    profileFingerprint: generationParameterProfileFingerprint(provider, model),
  };
  saveGenerationParameterOverrides(scope, values);
  const resolved = resolveGenerationParameterOverrides({ ...scope, reasoningMode });
  const raw = buildStreamOptionsFromIntent(model, reasoningMode, false, resolved);
  return buildProviderStreamOptions(provider, raw, model);
}

describe('relay panel values still go out without a metadata profile', () => {
  beforeEach(async () => {
    localStorage.clear();
    __resetMetadataClientForTest();
    await __seedMetadataCacheForTest({ data: METADATA_FIXTURE, timestamp: Date.now() });
    await initMetadata();
  });

  afterEach(() => {
    __resetMetadataClientForTest();
    localStorage.clear();
  });

  it('mergeRelayRuntime assigns the local template profile to generationProfile instead of flattening it into top-level keys', () => {
    const provider = makeRelayProvider();
    const model = makeUnmatchedRelayModel();
    const options = panelToStreamOptions(provider, model, {
      temperature: { state: 'value', value: 0.25 },
    });

    expect(options?.generationProfile?.template).toBe('openai_chat_completions');
    // The broken form shows up as template/wire/parameters becoming top-level StreamOptions keys.
    expect(options).not.toHaveProperty('template');
    expect(options).not.toHaveProperty('wire');
    expect(options).not.toHaveProperty('parameters');
  });

  it('ordinary cloud relay whose model misses the official catalog: panel values appear in the body the production builder emits', async () => {
    const provider = makeRelayProvider();
    const model = makeUnmatchedRelayModel();
    const options = panelToStreamOptions(provider, model, {
      temperature: { state: 'value', value: 0.25 },
      max_output_tokens: { state: 'value', value: 512 },
    });

    const body = await outboundBody(provider, options, model.id);
    expect(body).toMatchObject({ temperature: 0.25, max_tokens: 512 });
  });

  it('local engine (vLLM): the engine template extra_body wire reaches the body as well', async () => {
    const provider = makeRelayProvider({
      relayRequested: { transport: 'openai_chat_completions', engineProfile: 'vllm' },
    } as Partial<Provider>);
    const model = makeUnmatchedRelayModel();
    const options = panelToStreamOptions(provider, model, {
      top_k: { state: 'value', value: 40 },
    });

    expect(options?.generationProfile?.template).toBe('vllm_extra_body');
    const body = await outboundBody(provider, options, model.id);
    expect(body).toMatchObject({ extra_body: { top_k: 40 } });
  });

  it('local engine (Open WebUI): on a bearer connection the parameters still enter the chat body through the local engine profile', async () => {
    const provider = makeRelayProvider({
      relayRequested: { transport: 'openai_chat_completions', engineProfile: 'openwebui', authMode: 'bearer' },
    } as Partial<Provider>);
    const model = makeUnmatchedRelayModel();
    const options = panelToStreamOptions(provider, model, {
      temperature: { state: 'value', value: 0.3 },
      max_output_tokens: { state: 'value', value: 64 },
    });

    expect(options?.generationProfile?.template).toBe('openai_chat_completions');
    const body = await outboundBody(provider, options, model.id);
    expect(body).toMatchObject({ temperature: 0.3, max_tokens: 64 });
  });

  it('negative control: with no template in metadata nothing is injected and no wire is invented', async () => {
    // The production relayGenerationProfile reads template.wire from metadata, and a missing template returns undefined.
    __resetMetadataClientForTest();
    await __seedMetadataCacheForTest({
      data: { ...METADATA_FIXTURE, profiles: { ...METADATA_FIXTURE.profiles, generation: { parameters: {}, templates: {} } } },
      timestamp: Date.now(),
    });
    await initMetadata();

    const provider = makeRelayProvider();
    const model = makeUnmatchedRelayModel();
    const options = panelToStreamOptions(provider, model, {
      temperature: { state: 'value', value: 0.25 },
    });

    expect(options?.generationProfile).toBeUndefined();
    const body = await outboundBody(provider, options, model.id);
    expect(body).not.toHaveProperty('temperature');
  });

  it('negative control: a parameter absent from the profile wire does not go out, so the assertion is not a set-anything-and-it-arrives shell', async () => {
    const provider = makeRelayProvider();
    const model = makeUnmatchedRelayModel();
    const options = panelToStreamOptions(provider, model, {
      temperature: { state: 'value', value: 0.25 },
      // seed is in the ids table of relayGenerationProfile, but this metadata template's wire gives it no mapping.
      seed: { state: 'value', value: 7 },
    });

    const body = await outboundBody(provider, options, model.id);
    expect(body).toMatchObject({ temperature: 0.25 });
    expect(body).not.toHaveProperty('seed');
  });
});

// A connection-scope reasoning default has to actually go out, with the priority order
// explicit session reasoning chip > connection-level reasoning default > profile default.
// The assertions look at the body the production relay send path really emits, not an intermediate state.
describe('outbound behavior and priority of the connection scope reasoning default', () => {
  beforeEach(async () => {
    localStorage.clear();
    __resetMetadataClientForTest();
    await __seedMetadataCacheForTest({
        data: {
          ...METADATA_FIXTURE,
          profiles: {
            ...METADATA_FIXTURE.profiles,
            generation: {
              parameters: {
                reasoning_effort: { group: 'reasoning', valueSchema: 'enum', enumValues: ['low', 'high'] },
                temperature: { group: 'sampling', valueSchema: 'number' },
              },
              templates: {
                openai_chat_completions: {
                  transport: 'openai_chat_completions',
                  wire: { reasoning_effort: 'reasoning_effort', temperature: 'temperature' },
                },
              },
            },
          },
        },
        timestamp: Date.now(),
      });
    await initMetadata();
  });

  afterEach(() => {
    __resetMetadataClientForTest();
    localStorage.clear();
  });

  it('chip left on Auto: the connection-level reasoning default appears in the final body', async () => {
    const provider = makeRelayProvider();
    const model = makeUnmatchedRelayModel();
    const options = panelToStreamOptions(provider, model, {
      reasoning_effort: { state: 'value', value: 'high' },
      temperature: { state: 'value', value: 0.3 },
    }, 'automatic');

    const body = await outboundBody(provider, options, model.id);
    expect(body).toMatchObject({ reasoning_effort: 'high', temperature: 0.3 });
  });

  it('chip set explicitly: the whole connection-level reasoning default yields, while non-reasoning parameters still go out', async () => {
    const provider = makeRelayProvider();
    const model = makeUnmatchedRelayModel();
    // Connection default low, chip set to deep: the body has to carry the chip level, not low.
    const options = panelToStreamOptions(provider, model, {
      reasoning_effort: { state: 'value', value: 'low' },
      temperature: { state: 'value', value: 0.3 },
    }, 'deep');

    const body = await outboundBody(provider, options, model.id);
    expect(body).toMatchObject({ temperature: 0.3 });
    // The generation parameter channel must not overwrite the chip: in the production builder
    // applyRelayGenerationParameters runs **after** the reasoning_effort injection, so both channels producing a value would invert the priority.
    expect(body.reasoning_effort).not.toBe('low');
    expect(body.reasoning_effort).toBeTruthy();

    // Negative control: with the same connection default and the chip on Auto, low must go out,
    // proving the assertion above is not a shell hiding the fact that connection-level reasoning never ships at all.
    localStorage.removeItem('oriveo.guest.generation-parameter-settings.v1');
    const autoOptions = panelToStreamOptions(provider, model, {
      reasoning_effort: { state: 'value', value: 'low' },
    }, 'automatic');
    expect(await outboundBody(provider, autoOptions, model.id)).toMatchObject({ reasoning_effort: 'low' });
  });
});
