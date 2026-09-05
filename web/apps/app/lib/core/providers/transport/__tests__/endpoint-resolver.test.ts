/**
 * Unit tests for the three-level EndpointResolver priority and {model} placeholder replacement
 */

import { describe, expect, it, beforeEach } from 'vitest';
import type { Provider } from '@oriveo/shared';
import {
  resolveEndpoint,
  applyEndpointPlaceholders,
} from '../endpoint-resolver';
import { __resetMetadataClientForTest } from '../../../metadata/metadata-client';

function fakeProvider(baseURLText?: string): Provider {
  return {
    id: 'p1',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: '',
    apiKeyPreview: '',
    baseURLText,
  };
}

describe('resolveEndpoint priority order', () => {
  beforeEach(() => {
    __resetMetadataClientForTest();
  });

  it('1. a user-configured baseURLText overrides both the catalog and the built-in fallback', () => {
    const url = resolveEndpoint(fakeProvider('https://my-proxy.com'), 'openAI', 'chat', {
      metadataOverride: {
        baseUrl: 'https://api.openai.com',
        endpoints: { chat: '/v1/chat/completions' },
      },
    });
    expect(url).toBe('https://my-proxy.com/v1/chat/completions');
  });

  it('does not append /v1 again when baseURLText already contains it', () => {
    const url = resolveEndpoint(fakeProvider('https://api.openai.com/v1'), 'openAI', 'chat', {
      metadataOverride: {
        baseUrl: 'https://api.openai.com',
        endpoints: { chat: '/v1/chat/completions' },
      },
    });
    expect(url).toBe('https://api.openai.com/v1/chat/completions');
  });

  it('does not duplicate the path for an OpenAI-compatible API root such as Groq /openai/v1', () => {
    const url = resolveEndpoint(fakeProvider('https://api.groq.com/openai/v1'), 'groq', 'chat', {
      metadataOverride: {
        baseUrl: 'https://api.groq.com',
        endpoints: { chat: '/openai/v1/chat/completions' },
      },
    });
    expect(url).toBe('https://api.groq.com/openai/v1/chat/completions');
  });

  it('moves Qwen from a compatible-mode baseURL to the native DashScope endpoint', () => {
    const url = resolveEndpoint(
      fakeProvider('https://dashscope-intl.aliyuncs.com/compatible-mode/v1'),
      'qwen',
      'chat',
      {
        metadataOverride: {
          baseUrl: 'https://dashscope-intl.aliyuncs.com',
          endpoints: { chat: '/api/v1/services/aigc/text-generation/generation' },
        },
      },
    );
    expect(url).toBe(
      'https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/text-generation/generation',
    );
  });

  it('2. the catalog applies when the user has configured nothing', () => {
    const url = resolveEndpoint(null, 'openAI', 'chat', {
      metadataOverride: {
        baseUrl: 'https://api.openai.com',
        endpoints: { chat: '/v2/messages' },
      },
    });
    expect(url).toBe('https://api.openai.com/v2/messages');
  });

  it('accepts an official provider catalog baseUrl only when it is on the allowlist, falling back to the built-in constant otherwise', () => {
    const url = resolveEndpoint(null, 'openAI', 'chat', {
      metadataOverride: {
        baseUrl: 'https://evil.example',
        endpoints: { chat: '/v9/steal' },
      },
    });
    expect(url).toBe('https://api.openai.com/v9/steal');
  });

  it('accepts the international SiliconFlow catalog baseUrl because it is on the official allowlist', () => {
    const url = resolveEndpoint(null, 'siliconFlow', 'chat', {
      metadataOverride: {
        baseUrl: 'https://api.siliconflow.com',
        endpoints: { chat: '/v1/chat/completions' },
      },
    });
    expect(url).toBe('https://api.siliconflow.com/v1/chat/completions');
  });

  it('does not apply the official catalog allowlist to a user-supplied baseURL', () => {
    const url = resolveEndpoint(fakeProvider('https://proxy.example'), 'openAI', 'chat', {
      metadataOverride: {
        baseUrl: 'https://evil.example',
        endpoints: { chat: '/v1/chat/completions' },
      },
    });
    expect(url).toBe('https://proxy.example/v1/chat/completions');
  });

  it('3. built-in fallback when both the user value and the catalog are missing', () => {
    const url = resolveEndpoint(null, 'openAI', 'chat', { metadataOverride: null });
    // Built-in fallback: https://api.openai.com + /v1/chat/completions
    expect(url).toBe('https://api.openai.com/v1/chat/completions');
  });

  // The built-in fallback table is the only safety net when the catalog is entirely absent, and it matches
  // the server defaultTransport contract entry by entry. Independent copies of it drifted before, sending
  // four providers to a 404 and qwen to a deprecated endpoint.
  it('produces final URLs that match the server defaultTransport contract entry by entry', () => {
    const fallbackUrl = (kind: string, endpoint: 'chat' | 'images' = 'chat') =>
      resolveEndpoint(null, kind, endpoint, { metadataOverride: null });

    expect(fallbackUrl('openRouter')).toBe('https://openrouter.ai/api/v1/chat/completions');
    expect(fallbackUrl('groq')).toBe('https://api.groq.com/openai/v1/chat/completions');
    expect(fallbackUrl('fireworksAI')).toBe('https://api.fireworks.ai/inference/v1/chat/completions');
    expect(fallbackUrl('zhipu')).toBe('https://open.bigmodel.cn/api/paas/v4/chat/completions');
    expect(fallbackUrl('qwen')).toBe(
      'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    );
    expect(fallbackUrl('miniMax')).toBe('https://api.minimax.io/v1/chat/completions');
    // MiniMax image generation uses its own endpoint; the OpenAI-shaped /v1/images/generations does not exist there
    expect(fallbackUrl('miniMax', 'images')).toBe('https://api.minimax.io/v1/image_generation');
  });

  it('replaces the {model} placeholder (Gemini)', () => {
    const url = resolveEndpoint(null, 'gemini', 'chat', {
      metadataOverride: null,
      modelID: 'gemini-2.5-flash',
    });
    expect(url).toBe(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse',
    );
  });

  it('still replaces the placeholder under a user-defined baseURL', () => {
    const url = resolveEndpoint(fakeProvider('https://my-gemini-proxy.com'), 'gemini', 'chat', {
      metadataOverride: null,
      modelID: 'gemini-pro',
    });
    expect(url).toBe(
      'https://my-gemini-proxy.com/v1beta/models/gemini-pro:streamGenerateContent?alt=sse',
    );
  });

  it('runs a modelID with special characters through encodeURIComponent', () => {
    const out = applyEndpointPlaceholders('/v1/models/{model}:stream', { model: 'gemini@1' });
    expect(out).toBe('/v1/models/gemini%401:stream');
  });

  it('prefixes a base URL with https:// automatically', () => {
    const url = resolveEndpoint(fakeProvider('api.foo.com'), 'openAI', 'chat', {
      metadataOverride: null,
    });
    expect(url).toBe('https://api.foo.com/v1/chat/completions');
  });

  it('throws when the base URL is missing', () => {
    expect(() =>
      resolveEndpoint(null, 'unknown-provider-kind', 'chat', { metadataOverride: null }),
    ).toThrow();
  });

  it('accepts a metadataOverride passed directly as the 4th argument when it hits an official allowed domain', () => {
    const url = resolveEndpoint(null, 'openAI', 'chat', {
      baseUrl: 'https://api.openai.com',
      endpoints: { chat: '/v1/chat' },
    });
    expect(url).toBe('https://api.openai.com/v1/chat');
  });

  it('still enforces the official allowlist for a metadataOverride passed as the 4th argument', () => {
    const url = resolveEndpoint(null, 'openAI', 'chat', {
      baseUrl: 'https://compat.com',
      endpoints: { chat: '/v1/chat' },
    });
    expect(url).toBe('https://api.openai.com/v1/chat');
  });

  it('falls back when the 4th argument is null', () => {
    const url = resolveEndpoint(null, 'openAI', 'chat', null);
    expect(url).toBe('https://api.openai.com/v1/chat/completions');
  });
});
