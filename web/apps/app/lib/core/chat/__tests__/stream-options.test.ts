// @vitest-environment jsdom
//
// stream-options: the mergeRelayRuntime helper, plus buildProviderStreamOptions pass-through for
// non-relay providers. mergeRelayRuntime is a pure field mapping with no IO, so these tests feed
// it a runtime produced by the real resolveRelayModelRuntime.

import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { shouldReportProviderError } from '../error-reporting';
import { mapErrorKindKey } from '../../../utils/chat-stream-utils';
import { localizeProviderError } from '../../providers/error-i18n';
import { chatFailureTelemetry } from '../../telemetry/chat-failure';
import type { AIModel, Provider, StreamOptions } from '@oriveo/shared';
import { applyGenerationParameters } from '@oriveo/core/providers/request-builders/generation-parameters';
import {
  buildProviderStreamOptions,
  buildStreamOptionsFromIntent,
  filterGenerationParameterOverrides,
  mergeRelayRuntime,
  resolveGenerationProfileForModel,
} from '../stream-options';
import { generationParameterNegativeCacheTarget } from '../capability-evidence';
import { __resetMetadataClientForTest, __seedMetadataCacheForTest, initMetadata } from '../../metadata/metadata-client';
import { recordInputNegativeCache } from '../../capability/input-negative-cache';
import { resolveRelayModelRuntime } from '../../providers/relay-resolution';
import {
  buildRelayChatCompletionsBody,
  buildRelayResponsesBody,
} from '@oriveo/core/providers/relay-orchestrator';

function makeRelayProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'relay-1',
    kind: 'relay',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-relay',
    apiKeyPreview: '••',
    baseURLText: 'https://relay.example/v1',
    relayRequested: {
      transport: 'openai_chat_completions',
      serviceTier: 'flex',
      customUserAgent: 'MyAgent/1.0',
      headers: { 'x-extra': 'v' },
      webSearchToolName: 'web_search',
    },
    ...overrides,
  } as Provider;
}

function makeModel(overrides: Partial<AIModel> = {}): AIModel {
  return {
    name: 'model',
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    ...overrides,
  } as AIModel;
}

// The two cases below originally asserted `reasoning: undefined`. That behavior was changed
// deliberately: automatic must carry the tier intent downstream too, otherwise
// normalizeReasoningMode receives undefined and returns it unchanged, the profile's defaultLevel
// (which tier Auto injects) is never reached, and Auto falls back to the upstream default
// (DeepSeek defaults to high, measured at roughly 93s). See the comment above `hasOptions` in
// stream-options.ts for the rule.
// Failure card body localization at render time: reads the errors namespace of the production messages files.
function errorsOf(locale: string) {
  return JSON.parse(readFileSync(path.join(process.cwd(), 'messages', `${locale}.json`), 'utf8')).errors;
}
function tErrors(locale: string) {
  const errors = errorsOf(locale);
  return (key: string) => key.split('.').reduce((node, part) => node[part], errors) as unknown as string;
}

describe('buildStreamOptionsFromIntent (intent carrier)', () => {
  it('carries only the intent; a web intent without a profile is ultimately rejected by the facade request gate', () => {
    const model = makeModel({ capabilities: ['text', 'web', 'imageGeneration'] });
    expect(buildStreamOptionsFromIntent(model, 'automatic', true)).toEqual({
      reasoning: 'automatic', supportsImageGen: false, supportsWebSearch: true,
    });
  });

  it('enables web/imageGen only when the capability and its profile are both present', () => {
    const model = makeModel({
      capabilities: ['text', 'web', 'imageGeneration'],
      webSearchProfile: 'oai_web',
      imageGenProfile: 'openai_images',
    });
    expect(buildStreamOptionsFromIntent(model, 'automatic', true)).toEqual({
      reasoning: 'automatic',
      supportsImageGen: true,
      supportsWebSearch: true,
    });
  });

  it('keeps outbound options when a local generation override exists, even if every other intent is empty', () => {
    const model = makeModel();
    expect(buildStreamOptionsFromIntent(model, 'automatic', false, {
      temperature: { state: 'value', value: 0 },
    })).toEqual({
      reasoning: 'automatic',
      supportsImageGen: false,
      supportsWebSearch: false,
      generationParameters: { temperature: { state: 'value', value: 0 } },
    });
  });
});

describe('buildProviderStreamOptions E.27 ', () => {
  it('passes options through unchanged for a non-relay provider', () => {
    const provider = { id: 'p', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'k', apiKeyPreview: '' } as Provider;
    const options: StreamOptions = { reasoning: 'deep', supportsWebSearch: true };
    expect(buildProviderStreamOptions(provider, options)).toBe(options);
  });

  it('returns undefined for a non-relay provider with no options', () => {
    const provider = { id: 'p', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'k', apiKeyPreview: '' } as Provider;
    expect(buildProviderStreamOptions(provider)).toBeUndefined();
  });
});

describe('mergeRelayRuntime E.27 ', () => {
  it('maps the relayRequested fields and the supportsWebSearch argument', () => {
    const provider = makeRelayProvider();
    const runtime = resolveRelayModelRuntime(provider, null);

    const merged = mergeRelayRuntime(provider, runtime, { reasoning: 'deep' }, true);

    expect(merged.reasoning).toBe('deep'); // passed through from the base options
    expect(merged.relayServiceTier).toBe('flex');
    expect(merged.relayCustomUserAgent).toBe('MyAgent/1.0');
    expect(merged.relayHeaders).toEqual({ 'x-extra': 'v' });
    expect(merged.relayWebSearchToolName).toBe('web_search');
    expect(merged.supportsWebSearch).toBe(true);
    // relayImageToolModelID is always undefined here.
    expect(merged.relayImageToolModelID).toBeUndefined();
    // transport/authMode/root all come from the runtime resolved per (provider, model).
    expect(merged.relayTransport).toBe(runtime.transport);
    expect(merged.relayAuthMode).toBe(runtime.authMode);
    expect(merged.relayResolvedBaseURLText).toBe('https://relay.example/v1');
    expect(merged.relayResolvedAPIBaseURLIsExact).toBe(true);
  });

  it('connection-level reasoning is retired: for a stored reasoningEffort=high connection, Chat / Responses bodies carry only this turn\'s tier', () => {
    const messages = [{ role: 'user' as const, content: 'hi' }];
    for (const transport of ['openai_chat_completions', 'openai_responses'] as const) {
      const provider = makeRelayProvider({
        relayRequested: { transport, authMode: 'bearer', reasoningEffort: 'high' },
      } as Partial<Provider>);
      const runtime = resolveRelayModelRuntime(provider, null);
      const build = transport === 'openai_responses'
        ? (options: StreamOptions) => buildRelayResponsesBody('m', messages, options, null).body
        : (options: StreamOptions) => buildRelayChatCompletionsBody('m', messages, options).body;

      // This turn picks fast -> low: not overridden by the high stored on the connection.
      const fast = build(mergeRelayRuntime(provider, runtime, { reasoning: 'fast' }, false));
      // This turn is automatic -> no tier: the connection's high is not sent out.
      const automatic = build(mergeRelayRuntime(provider, runtime, { reasoning: 'automatic' }, false));
      if (transport === 'openai_responses') {
        expect(fast.reasoning).toEqual({ effort: 'low', summary: 'auto' });
        expect(automatic.reasoning).toEqual({ summary: 'auto' });
      } else {
        expect(fast.reasoning_effort).toBe('low');
        expect(automatic).not.toHaveProperty('reasoning_effort');
      }
    }
  });

  it('the protocol goes only through effectiveTransport: the provider-level relayResolvedTransport no longer participates, and the model\'s own protocol wins', () => {
    const provider = makeRelayProvider({ relayResolvedTransport: 'openai_responses' });
    const merged = mergeRelayRuntime(provider, resolveRelayModelRuntime(provider, null), undefined, false);
    expect(merged.relayTransport).toBe('openai_chat_completions');
    expect(merged.supportsWebSearch).toBe(false);
    const perModel = mergeRelayRuntime(
      provider,
      resolveRelayModelRuntime(provider, { relayTransport: 'anthropic_messages' }),
      undefined,
      false,
    );
    expect(perModel.relayTransport).toBe('anthropic_messages');
    expect(perModel.relayAuthMode).toBe('x_api_key');
    expect(perModel.relayHeaderProfile).toBe('anthropic_v2023_06_01');
  });

  it('passes the resolvedAPIBaseURL stored by discovery to the adapter as the exact runtime base URL', () => {
    const provider = makeRelayProvider({
      baseURLText: 'https://relay.example.com/input/v1',
      relayRequested: {
        transport: 'anthropic_messages',
        authMode: 'x_api_key',
        resolvedAPIBaseURL: 'https://relay.example.com/resolved-prefix',
      },
    });
    const options = buildProviderStreamOptions(provider);

    expect(options?.relayResolvedBaseURLText).toBe('https://relay.example.com/resolved-prefix');
    expect(options?.relayResolvedAPIBaseURLIsExact).toBe(true);
  });
});

/**
 * Image routing integration. The pure function itself is pinned by fixture tests
 * (core/relay-image-routing-fixtures.test.ts); this checks that the derived result really lands
 * in StreamOptions, i.e. that the fallback takes effect on the production path.
 */
describe('buildProviderStreamOptions - image routing derivation', () => {
  const imageGenOptions: StreamOptions = { supportsImageGen: true };

  function responsesProvider(models: AIModel[]): Provider {
    return makeRelayProvider({
      models,
      relayResolvedTransport: 'openai_responses',
      relayRequested: { transport: 'openai_responses' },
    } as Partial<Provider>);
  }

  it('a gpt-image-* current model switches the main model to a chat driver and demotes the image model to tool.model', () => {
    const chat = makeModel({ id: 'gpt-5.4', capabilities: ['text'], isDefault: true } as Partial<AIModel>);
    const image = makeModel({
      id: 'gpt-image-1',
      capabilities: ['text', 'imageGeneration'],
    } as Partial<AIModel>);
    const merged = buildProviderStreamOptions(responsesProvider([chat, image]), imageGenOptions, image);

    expect(merged?.relayDriverModelID).toBe('gpt-5.4');
    expect(merged?.relayImageToolModelID).toBe('gpt-image-1');
    // Responses  
    expect(merged?.relayStream).toBe(true);
  });

  it('a chat model stays the main model, leaving tool.model empty so the upstream default image model is used', () => {
    const chat = makeModel({
      id: 'gpt-5.4',
      capabilities: ['text', 'imageGeneration'],
      isDefault: true,
    } as Partial<AIModel>);
    const merged = buildProviderStreamOptions(responsesProvider([chat]), imageGenOptions, chat);

    expect(merged?.relayDriverModelID).toBe('gpt-5.4');
    expect(merged?.relayImageToolModelID).toBeUndefined();
  });

  it('a relay holding only image models throws "add a chat model first", which error-i18n can map', () => {
    const image = makeModel({
      id: 'gpt-image-1',
      capabilities: ['text', 'imageGeneration'],
      isDefault: true,
    } as Partial<AIModel>);

    expect(() => buildProviderStreamOptions(responsesProvider([image]), imageGenOptions, image))
      .toThrow('Please add a chat model to this relay before using image generation.');

    // Dedicated kind: not reported, telemetry maps to local_request_rejected, body is localized to errors.relay.missingChatDriverModel.
    let thrown: unknown;
    try {
      buildProviderStreamOptions(responsesProvider([image]), imageGenOptions, image);
    } catch (error) {
      thrown = error;
    }
    const pe = thrown as { kind?: string; message: string; relayGuidance?: boolean };
    expect(pe.kind).toBe('relayImageChatModelRequired');
    expect(pe.relayGuidance).toBe(true);
    expect(shouldReportProviderError(thrown)).toBe(false);
    expect(mapErrorKindKey(pe.kind)).toBe('requestFailed');
    expect(chatFailureTelemetry({ error: thrown, outputStarted: false, latencyMs: 0 }).error_code).toBe('local_request_rejected');
    expect(localizeProviderError(pe.message, tErrors('en'))).toBe(errorsOf('en').relay.missingChatDriverModel);
    expect(localizeProviderError(pe.message, tErrors('ja'))).toBe(errorsOf('ja').relay.missingChatDriverModel);
    expect(errorsOf('ja').relay.missingChatDriverModel).not.toBe(errorsOf('en').relay.missingChatDriverModel);
  });

  it('an Anthropic transport with an image model throws a friendly unsupported error rather than failing silently', () => {
    const image = makeModel({
      id: 'gpt-image-1',
      capabilities: ['text', 'imageGeneration'],
    } as Partial<AIModel>);
    const provider = makeRelayProvider({
      models: [image],
      relayResolvedTransport: 'anthropic_messages',
      relayRequested: { transport: 'anthropic_messages' },
    } as Partial<Provider>);

    expect(() => buildProviderStreamOptions(provider, imageGenOptions, image))
      .toThrow('Image generation is not available on this transport.');

    // Dedicated kind: not reported; the failure card title is "request failed" and the body is localized to errors.relay.imageRouteUnsupported.
    let thrown: unknown;
    try {
      buildProviderStreamOptions(provider, imageGenOptions, image);
    } catch (error) {
      thrown = error;
    }
    const pe = thrown as { kind?: string; message: string; relayGuidance?: boolean };
    expect(pe.kind).toBe('relayImageTransportUnsupported');
    expect(pe.relayGuidance).toBe(true);
    expect(shouldReportProviderError(thrown)).toBe(false);
    expect(mapErrorKindKey(pe.kind)).toBe('requestFailed');
    expect(chatFailureTelemetry({ error: thrown, outputStarted: false, latencyMs: 0 }).error_code).toBe('local_request_rejected');
    expect(localizeProviderError(pe.message, tErrors('en'))).toBe(
      'Image generation is not available on this protocol. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses or Chat Completions.',
    );
    expect(localizeProviderError(pe.message, tErrors('zh-Hans'))).toBe(
      '\u5f53\u524d\u534f\u8bae\u4e0d\u652f\u6301\u51fa\u56fe。\u8bf7\u6253\u5f00 \u4f9b\u5e94\u5546 → \u8fd9\u6761\u8fde\u63a5 → \u6a21\u578b\u5e93 → \u8fd9\u4e2a\u6a21\u578b → \u9ad8\u7ea7，\u628a\u534f\u8bae\u6539\u4e3a OpenAI Responses \u6216 Chat Completions。',
    );
  });

  it('a non-image model is left alone and produces no driver/tool fields', () => {
    const chat = makeModel({ id: 'gpt-5.4', capabilities: ['text'], isDefault: true } as Partial<AIModel>);
    const merged = buildProviderStreamOptions(responsesProvider([chat]), { supportsImageGen: false }, chat);

    expect(merged?.relayDriverModelID).toBeUndefined();
    expect(merged?.relayImageToolModelID).toBeUndefined();
  });

  it('a chat_completions transport routes to images_endpoint without substituting a chat driver', () => {
    const image = makeModel({
      id: 'gpt-image-1',
      capabilities: ['text', 'imageGeneration'],
    } as Partial<AIModel>);
    const chat = makeModel({ id: 'gpt-5.4', capabilities: ['text'], isDefault: true } as Partial<AIModel>);
    const merged = buildProviderStreamOptions(makeRelayProvider({ models: [chat, image] }), imageGenOptions, image);

    // The images endpoint passes the image model straight to /images/generations, so no chat driver is needed.
    expect(merged?.relayDriverModelID).toBeUndefined();
    expect(merged?.relayImageToolModelID).toBeUndefined();
  });
});

describe('filterGenerationParameterOverrides — parameterSupport three-valued gate (official connection)', () => {
  afterEach(() => {
    __resetMetadataClientForTest();
    localStorage.clear();
  });

  const officialProvider = {
    id: 'official-openai', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [],
    apiKey: 'fixture-only', apiKeyPreview: '',
  } as unknown as Provider;
  const officialModel = makeModel({
    id: 'param-model', name: 'param-model', transport: 'openai_chat_completions',
    generationProfile: {
      template: 'param_gate',
      parameters: [{ id: 'temperature', support: 'accepted', source: 'authoritative_metadata' }],
    },
  } as unknown as Partial<AIModel>);

  async function seed(parameterSupport?: Record<string, unknown>): Promise<void> {
    __resetMetadataClientForTest();
    await __seedMetadataCacheForTest({
      data: {
        version: 2,
        contractVersion: 1,
        updatedAt: '2026-10-19T00:00:00Z',
        profiles: {
          reasoning: {}, webSearch: {}, imageGen: {},
          generation: {
            parameters: {},
            templates: { param_gate: { transport: 'openai_chat_completions', wire: { temperature: 'temperature' } } },
          },
        },
        relayRuntimeConfig: { defaultTransport: 'openai_chat_completions' },
        providers: {
          openAI: {
            resolveMap: { 'param-model': 'param-model' },
            models: {
              'param-model': {
                canonicalModelId: 'param-model',
                transport: 'openai_chat_completions',
                // An old field saying supported does not count: the gate only reads parameterSupport.
                supportsTemperature: true,
                ...(parameterSupport ? { parameterSupport } : {}),
                profiles: {
                  generation: {
                    template: 'param_gate',
                    parameters: [{ id: 'temperature', support: 'accepted', source: 'authoritative_metadata' }],
                  },
                },
              },
            },
          },
        },
        providerConfigs: [],
      },
      timestamp: Date.now(),
    });
    await initMetadata();
  }

  function outboundBody(): Record<string, unknown> {
    const options = buildProviderStreamOptions(officialProvider, undefined, officialModel);
    const filtered = filterGenerationParameterOverrides(officialProvider, officialModel, {
      temperature: { state: 'value', value: 0.3 },
    }, options);
    const body: Record<string, unknown> = {};
    applyGenerationParameters(body, filtered, resolveGenerationProfileForModel(officialProvider, officialModel)!);
    return body;
  }

  it('parameterSupport.temperature unavailable -> no temperature outbound', async () => {
    await seed({ temperature: { state: 'unavailable', reasonCode: 'upstream_declared' } });
    expect(outboundBody()).not.toHaveProperty('temperature');
  });

  it('parameterSupport.temperature unknown -> sent as usual', async () => {
    await seed({ temperature: { state: 'unknown', reasonCode: 'catalog_silent' } });
    expect(outboundBody()).toMatchObject({ temperature: 0.3 });
  });

  it('a missing parameterSupport key is treated as unknown and sent as usual', async () => {
    await seed({ top_p: { state: 'unavailable' } });
    expect(outboundBody()).toMatchObject({ temperature: 0.3 });
  });

  it('a param:temperature negative cache hit -> the next request omits it; a changed verdict revision invalidates it', async () => {
    await seed({ temperature: { state: 'unknown', reasonCode: 'catalog_silent' } });
    const target = generationParameterNegativeCacheTarget(officialProvider, officialModel, undefined, 'temperature');
    expect(target?.key).toMatchObject({
      connectionId: 'official-openai', modelId: 'param-model', capabilityKey: 'param:temperature',
    });
    recordInputNegativeCache(target!.key, { signatureId: 'fixture.temperature_rejected', verdictRevision: target!.verdictRevision });
    expect(outboundBody()).not.toHaveProperty('temperature');

    await seed({ temperature: { state: 'auto_available' } });
    expect(outboundBody()).toMatchObject({ temperature: 0.3 });
  });
});

describe('buildProviderStreamOptions — param:thinking negative cache (official connection)', () => {
  afterEach(() => localStorage.clear());

  const anthropicProvider = {
    id: 'official-anthropic', kind: 'anthropic', status: { kind: 'connected' }, models: [], catalogModels: [],
    apiKey: 'fixture-only', apiKeyPreview: '',
  } as unknown as Provider;
  const claude = makeModel({ id: 'claude-fable-5', name: 'Claude Fable 5', transport: 'anthropic_messages' } as Partial<AIModel>);
  const options: StreamOptions = {
    reasoning: 'deep', supportsWebSearch: false,
    capabilityPreferences: { web: 'off', reasoningIntent: 'high' },
  } as StreamOptions;

  it('miss -> the reasoning tier goes out as usual', () => {
    const built = buildProviderStreamOptions(anthropicProvider, options, claude);
    expect(built?.reasoning).toBe('deep');
    expect(built?.capabilityPreferences?.reasoningIntent).toBe('high');
  });

  it('hit -> this request carries no thinking (both reasoning and reasoningIntent are removed), the rest as usual', () => {
    const target = generationParameterNegativeCacheTarget(anthropicProvider, claude, options, 'thinking');
    expect(target?.key).toMatchObject({ connectionId: 'official-anthropic', capabilityKey: 'param:thinking' });
    recordInputNegativeCache(target!.key, {
      signatureId: 'anthropic.thinking_type_not_supported', verdictRevision: target!.verdictRevision,
    });
    const built = buildProviderStreamOptions(anthropicProvider, options, claude);
    expect(built).not.toHaveProperty('reasoning');
    expect(built?.capabilityPreferences).toEqual({ web: 'off' });
    // The user's stored preference object is not rewritten.
    expect(options.reasoning).toBe('deep');
    expect(options.capabilityPreferences?.reasoningIntent).toBe('high');
  });
});
