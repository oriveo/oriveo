// @vitest-environment jsdom
//
// stream-options: the mergeRelayRuntime helper, plus buildProviderStreamOptions pass-through for
// non-relay providers. mergeRelayRuntime is a pure field mapping with no IO, so these tests feed
// it a runtime produced by the real resolveRelayRuntimeFields.

import { describe, expect, it } from 'vitest';
import type { AIModel, Provider, StreamOptions } from '@oriveo/shared';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent, mergeRelayRuntime } from '../stream-options';
import { resolveRelayRuntimeFields } from '../../providers/relay-resolution';

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
    const runtime = resolveRelayRuntimeFields({
      baseURLText: provider.baseURLText,
      relayRequested: provider.relayRequested,
    });

    const merged = mergeRelayRuntime(provider, runtime, { reasoning: 'deep' }, true);

    expect(merged.reasoning).toBe('deep'); // passed through from the base options
    expect(merged.relayServiceTier).toBe('flex');
    expect(merged.relayCustomUserAgent).toBe('MyAgent/1.0');
    expect(merged.relayHeaders).toEqual({ 'x-extra': 'v' });
    expect(merged.relayWebSearchToolName).toBe('web_search');
    expect(merged.supportsWebSearch).toBe(true);
    // relayImageToolModelID is always undefined here.
    expect(merged.relayImageToolModelID).toBeUndefined();
    // transport and authMode fall back to the values resolved from the runtime.
    expect(merged.relayTransport).toBe(runtime.relayResolvedTransport);
    expect(merged.relayAuthMode).toBe(runtime.relayResolvedAuthMode);
  });

  it('prefers relayResolved* already resolved on the provider over the runtime values', () => {
    const provider = makeRelayProvider({ relayResolvedTransport: 'openai_responses' });
    const runtime = resolveRelayRuntimeFields({
      baseURLText: provider.baseURLText,
      relayRequested: provider.relayRequested,
    });
    const merged = mergeRelayRuntime(provider, runtime, undefined, false);
    expect(merged.relayTransport).toBe('openai_responses');
    expect(merged.supportsWebSearch).toBe(false);
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
