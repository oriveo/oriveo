import { describe, expect, it } from 'vitest';

import { buildProviderRequest } from '../dispatch';
import type { RuntimeMetadataResponse } from '../runtime';
import type { RequestParams } from '../types';

describe('image requestDefaults', () => {
  it.each([
    {
      providerKind: 'openAI' as const,
      modelId: 'gpt-image-test',
      profileName: 'oai_images',
      profile: {
        route: 'images_api',
        requestDefaults: { size: '512x512', n: 2, response_format: 'url' },
      },
      expected: {
        size: '512x512',
        n: 2,
        response_format: 'url',
      },
    },
    {
      providerKind: 'qwen' as const,
      modelId: 'qwen-image-test',
      profileName: 'qwen_images',
      profile: {
        route: 'dashscope_multimodal',
        requestDefaults: { size: '720*1280', n: 2, prompt_extend: false },
      },
      expected: {
        'parameters.size': '720*1280',
        'parameters.n': 2,
        'parameters.prompt_extend': false,
      },
    },
    {
      providerKind: 'zhipu' as const,
      modelId: 'cogview-test',
      profileName: 'zhipu_images',
      profile: {
        route: 'images_api',
        requestDefaults: { size: '768x1344' },
      },
      expected: {
        size: '768x1344',
      },
    },
    {
      providerKind: 'miniMax' as const,
      modelId: 'minimax-image-test',
      profileName: 'mm_images',
      profile: {
        route: 'minimax_image_generation',
        requestDefaults: { response_format: 'url', n: 3 },
      },
      expected: {
        response_format: 'url',
        n: 3,
      },
    },
    {
      providerKind: 'siliconFlow' as const,
      modelId: 'sf-image-test',
      profileName: 'sf_images',
      profile: {
        route: 'images_api',
        requestDefaults: { size: '512x1024' },
      },
      expected: {
        size: '512x1024',
      },
    },
    {
      providerKind: 'togetherAI' as const,
      modelId: 'black-forest-labs/FLUX.1-schnell',
      profileName: 'together_images',
      profile: {
        route: 'images_api',
        requestDefaults: { size: '1024x1024', n: 1 },
      },
      expected: {
        size: '1024x1024',
        n: 1,
      },
    },
    {
      // together_images_no_n (gemini-3-pro-image): Together answers 400
      // "n is not supported for this model", so requestDefaults omits n and the body must not carry it.
      providerKind: 'togetherAI' as const,
      modelId: 'google/gemini-3-pro-image',
      profileName: 'together_images_no_n',
      profile: {
        route: 'images_api',
        requestDefaults: { size: '1024x1024' },
      },
      expected: {
        size: '1024x1024',
        n: undefined,
      },
    },
    {
      // grok-imagine-image and -quality (aliased -pro): xAI rejects size with a 400, so only the
      // {n, response_format} from requestDefaults is sent and the body must contain no size.
      providerKind: 'grok' as const,
      modelId: 'grok-imagine-image',
      profileName: 'grok_images',
      profile: {
        route: 'images_api',
        requestDefaults: { n: 1, response_format: 'b64_json' },
      },
      expected: {
        n: 1,
        response_format: 'b64_json',
        size: undefined,
      },
    },
  ])('$providerKind image builder consumes profile requestDefaults', async (item) => {
    const metadata = makeMetadata(item.providerKind, item.modelId, item.profileName, item.profile);
    const request = await buildProviderRequest(
      {
        providerKind: item.providerKind,
        apiKey: 'test-key',
        modelID: item.modelId,
        messages: [{ role: 'user', content: 'draw a cube' }],
        options: { supportsImageGen: true },
      } satisfies RequestParams,
      async () => metadata,
    );

    for (const [pathKey, expected] of Object.entries(item.expected)) {
      expect(valueAtPath(request.body, pathKey), pathKey).toBe(expected);
    }
  });

  it('grok image model routes to /images/generations without size (regression)', async () => {
    // Two regressions at once: (1) grok image models once missed their route and were sent to
    // /chat/completions, which xAI answers with 400 "image model not available on this endpoint";
    // (2) grok_images once carried size, which xAI answers with 400 "Argument not supported: size".
    // Together these were why grok image generation kept failing.
    const metadata = makeMetadata('grok', 'grok-imagine-image-pro', 'grok_images', {
      route: 'images_api',
      requestDefaults: { n: 1, response_format: 'b64_json' },
    });
    const request = await buildProviderRequest(
      {
        providerKind: 'grok',
        apiKey: 'test-key',
        modelID: 'grok-imagine-image-pro',
        messages: [{ role: 'user', content: 'generate any image for me' }],
        options: { supportsImageGen: true },
      } satisfies RequestParams,
      async () => metadata,
    );

    expect(request.url.endsWith('/images/generations'), request.url).toBe(true);
    expect(request.responseAdapter).toBe('openai_images_api');
    expect((request.body as Record<string, unknown>).size).toBeUndefined();
    expect((request.body as Record<string, unknown>).model).toBe('grok-imagine-image-pro');
    expect((request.body as Record<string, unknown>).prompt).toBe('generate any image for me');
  });

  it('together image model routes to /images/generations (regression)', async () => {
    // Regression: togetherAI once shared the generic builder with groq/fireworks/mistral, which
    // passes no imageGenProfile, so all 27 image models were sent to /chat/completions and upstream
    // replied "Image inference is not supported on this endpoint. Please use /images/generations
    // instead".
    const metadata = makeMetadata('togetherAI', 'black-forest-labs/FLUX.1-dev', 'together_images', {
      route: 'images_api',
      requestDefaults: { size: '1024x1024', n: 1 },
    });
    const request = await buildProviderRequest(
      {
        providerKind: 'togetherAI',
        apiKey: 'test-key',
        modelID: 'black-forest-labs/FLUX.1-dev',
        messages: [{ role: 'user', content: 'draw a cat' }],
        options: { supportsImageGen: true },
      } satisfies RequestParams,
      async () => metadata,
    );

    expect(request.url).toBe('https://api.together.xyz/v1/images/generations');
    // Together returns data[].url, and those signed URLs expire, so the adapter with the downloader must convert them to data URLs.
    expect(request.responseAdapter).toBe('siliconflow_images_api');
    expect((request.body as Record<string, unknown>).model).toBe('black-forest-labs/FLUX.1-dev');
    expect((request.body as Record<string, unknown>).prompt).toBe('draw a cat');
    expect((request.body as Record<string, unknown>).stream).toBeUndefined();
  });

  it('together no_n profile omits n from the body', async () => {
    const metadata = makeMetadata('togetherAI', 'google/gemini-3-pro-image', 'together_images_no_n', {
      route: 'images_api',
      requestDefaults: { size: '1024x1024' },
    });
    const request = await buildProviderRequest(
      {
        providerKind: 'togetherAI',
        apiKey: 'test-key',
        modelID: 'google/gemini-3-pro-image',
        messages: [{ role: 'user', content: 'draw a cube' }],
        options: { supportsImageGen: true },
      } satisfies RequestParams,
      async () => metadata,
    );

    expect(request.url).toBe('https://api.together.xyz/v1/images/generations');
    expect(request.body).toEqual({
      size: '1024x1024',
      model: 'google/gemini-3-pro-image',
      prompt: 'draw a cube',
    });
  });

  it('new OpenAI-compatible provider inherits images_api without provider wiring', async () => {
    const metadata = makeMetadata('fireworksAI', 'future-image-model', 'future_images', {
      route: 'images_api',
      requestDefaults: { size: '1024x1024' },
    });
    const request = await buildProviderRequest(
      {
        providerKind: 'fireworksAI',
        apiKey: 'test-key',
        modelID: 'future-image-model',
        messages: [{ role: 'user', content: 'draw a cube' }],
        options: { supportsImageGen: true },
      } satisfies RequestParams,
      async () => metadata,
    );

    expect(request.url).toBe('https://api.fireworks.ai/inference/v1/images/generations');
    expect(request.responseAdapter).toBe('siliconflow_images_api');
    expect(request.body).toEqual({
      size: '1024x1024',
      model: 'future-image-model',
      prompt: 'draw a cube',
    });
    expect(request.body).not.toHaveProperty('messages');
    expect(request.body).not.toHaveProperty('stream');
    expect(request.body).not.toHaveProperty('n');
    expect(request.body).not.toHaveProperty('response_format');
  });

  it.each([
    ['openAI', 'openai_images_api'],
    ['grok', 'openai_images_api'],
    ['zhipu', 'openai_images_api'],
    ['siliconFlow', 'siliconflow_images_api'],
    ['togetherAI', 'siliconflow_images_api'],
  ] as const)('%s keeps its existing images response adapter', async (providerKind, expectedAdapter) => {
    const metadata = makeMetadata(providerKind, 'adapter-test-image', 'adapter_images', {
      route: 'images_api',
      requestDefaults: {},
    });
    const request = await buildProviderRequest(
      {
        providerKind,
        apiKey: 'test-key',
        modelID: 'adapter-test-image',
        messages: [{ role: 'user', content: 'draw' }],
        options: { supportsImageGen: true },
      } satisfies RequestParams,
      async () => metadata,
    );

    expect(request.responseAdapter).toBe(expectedAdapter);
  });

  it('together image model without a known route fails loud (no silent chat fallback)', async () => {
    const metadata = makeMetadata('togetherAI', 'broken-image-model', 'together_images_broken', {
      requestDefaults: { size: '1024x1024' },
    });

    await expect(
      buildProviderRequest(
        {
          providerKind: 'togetherAI',
          apiKey: 'test-key',
          modelID: 'broken-image-model',
          messages: [{ role: 'user', content: 'draw a cube' }],
          options: { supportsImageGen: true },
        } satisfies RequestParams,
        async () => metadata,
      ),
    ).rejects.toThrow(/route is missing or unknown/);
  });

  it('official image intent without a profile fails loud before chat fallback', async () => {
    await expect(
      buildProviderRequest(
        {
          providerKind: 'mistral',
          apiKey: 'test-key',
          modelID: 'future-image-model',
          messages: [{ role: 'user', content: 'draw' }],
          options: { supportsImageGen: true },
        } satisfies RequestParams,
        async () => null,
      ),
    ).rejects.toThrow(/route is missing or unknown/);
  });

  it('unknown image route fails loud before any provider chat builder runs', async () => {
    const metadata = makeMetadata('fireworksAI', 'future-image-model', 'future_images', {
      route: 'future_images_v2',
      requestDefaults: {},
    });

    await expect(
      buildProviderRequest(
        {
          providerKind: 'fireworksAI',
          apiKey: 'test-key',
          modelID: 'future-image-model',
          messages: [{ role: 'user', content: 'draw' }],
          options: { supportsImageGen: true },
        } satisfies RequestParams,
        async () => metadata,
      ),
    ).rejects.toThrow(/route is missing or unknown/);
  });

  it('provider-specific image route assigned to the wrong provider fails loud', async () => {
    const metadata = makeMetadata('fireworksAI', 'broken-image-model', 'broken_images', {
      route: 'dashscope_multimodal',
      requestDefaults: {},
    });

    await expect(
      buildProviderRequest(
        {
          providerKind: 'fireworksAI',
          apiKey: 'test-key',
          modelID: 'broken-image-model',
          messages: [{ role: 'user', content: 'draw' }],
          options: { supportsImageGen: true },
        } satisfies RequestParams,
        async () => metadata,
      ),
    ).rejects.toThrow(/invalid for fireworksAI/);
  });

  it('relay without an official image profile keeps its chat route', async () => {
    const request = await buildProviderRequest(
      {
        providerKind: 'relay',
        apiKey: 'test-key',
        modelID: 'relay-image-model',
        baseURL: 'https://relay.example/v1',
        messages: [{ role: 'user', content: 'draw' }],
        options: { supportsImageGen: true },
      } satisfies RequestParams,
      async () => null,
    );

    expect(request.url).toBe('https://relay.example/v1/chat/completions');
    expect(request.body).toHaveProperty('stream', true);
  });

  it('together text model keeps the chat leg untouched', async () => {
    // The generic builder shared by groq / fireworksAI / mistral: behavior must not change when there is no imageGen profile.
    const metadata: RuntimeMetadataResponse = {
      version: 1001,
      updatedAt: '2026-08-05T00:00:00Z',
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: {
        togetherAI: {
          resolveMap: { 'openai/gpt-oss-120b': 'openai/gpt-oss-120b' },
          models: {
            'openai/gpt-oss-120b': {
              canonicalModelId: 'openai/gpt-oss-120b',
              capabilities: ['text'],
            },
          },
        },
      },
    };

    const request = await buildProviderRequest(
      {
        providerKind: 'togetherAI',
        apiKey: 'test-key',
        modelID: 'openai/gpt-oss-120b',
        messages: [{ role: 'user', content: 'hello' }],
      } satisfies RequestParams,
      async () => metadata,
    );

    expect(request.url).toBe('https://api.together.xyz/v1/chat/completions');
    expect(request.responseAdapter).toBeUndefined();
    expect((request.body as Record<string, unknown>).stream).toBe(true);
  });
});

function makeMetadata(
  providerKind: RequestParams['providerKind'],
  modelId: string,
  profileName: string,
  profile: Record<string, unknown>,
): RuntimeMetadataResponse {
  return {
    version: 1001,
    updatedAt: '2026-07-04T00:00:00Z',
    profiles: {
      reasoning: {},
      webSearch: {},
      imageGen: {
        [profileName]: profile,
      },
    },
    providers: {
      [providerKind]: {
        resolveMap: { [modelId]: modelId },
        models: {
          [modelId]: {
            canonicalModelId: modelId,
            capabilities: ['imageGeneration'],
            profiles: { imageGen: profileName },
          },
        },
      },
    },
  };
}

function valueAtPath(source: unknown, pathKey: string): unknown {
  return pathKey.split('.').reduce<unknown>((current, segment) => {
    if (current == null) return undefined;
    if (typeof current === 'object' && !Array.isArray(current)) {
      return (current as Record<string, unknown>)[segment];
    }
    return undefined;
  }, source);
}
