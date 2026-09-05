import { describe, it, expect } from 'vitest';
// The request builders live in @oriveo/core; the web and desktop clients import the same ones.
import {
  buildQwenRequest,
  resolveDashScopeCompatibleChatURL,
} from '@oriveo/core/providers/request-builders/qwen';
import type { RequestParams } from '@oriveo/core/providers/request-builders/types';

/* ── A. Qwen adapter -- model filtering ───────
 *
 * Catalog filtering belongs to the backend metadata; the client takes no part in deciding what
 * counts as a chat model. Regression coverage for that lives in
 * `apps/app/lib/core/providers/__tests__/build-official-enabled-models.test.ts` and
 * `official-provider-registration.test.ts`.
 */

/* ── B. URL transformation — image gen endpoint ───────── */

describe('Qwen image gen URL transformation', () => {
  // Mirrors the URL rewriting in buildQwenRequest.
  function transformImageURL(baseURL: string): string {
    return baseURL.replace(
      /\/compatible-mode\/v1$/,
      '/api/v1/services/aigc/multimodal-generation/generation',
    );
  }

  it('converts the Singapore (intl) endpoint', () => {
    expect(transformImageURL('https://dashscope-intl.aliyuncs.com/compatible-mode/v1'))
      .toBe('https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation');
  });

  it('converts the Beijing endpoint', () => {
    expect(transformImageURL('https://dashscope.aliyuncs.com/compatible-mode/v1'))
      .toBe('https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation');
  });

  it('converts the Hong Kong endpoint', () => {
    expect(transformImageURL('https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1'))
      .toBe('https://cn-hongkong.dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation');
  });

  it('converts the Virginia (US) endpoint', () => {
    expect(transformImageURL('https://dashscope-us.aliyuncs.com/compatible-mode/v1'))
      .toBe('https://dashscope-us.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation');
  });

  it('leaves a non-standard URL unchanged', () => {
    const url = 'https://custom-endpoint.example.com/v1';
    expect(transformImageURL(url)).toBe(url);
  });
});

/* ── C. DashScope image response parsing ──────────────── */

describe('Qwen image response parsing', () => {
  // Mirrors the extraction in adaptQwenImagesResponse.
  interface DashScopeImagePayload {
    output?: {
      choices?: Array<{
        message?: {
          content?: Array<{ image?: string }>;
        };
      }>;
    };
    usage?: { input_tokens?: number; output_tokens?: number };
  }

  function extractImageURL(payload: DashScopeImagePayload): string | undefined {
    return payload.output?.choices?.[0]?.message?.content?.[0]?.image;
  }

  it('extracts the image URL from a normal response', () => {
    const payload: DashScopeImagePayload = {
      output: {
        choices: [{
          message: {
            content: [{ image: 'https://example.com/img.png' }],
          },
        }],
      },
    };
    expect(extractImageURL(payload)).toBe('https://example.com/img.png');
  });

  it('returns undefined when output is missing', () => {
    expect(extractImageURL({})).toBeUndefined();
  });

  it('returns undefined when choices is missing', () => {
    expect(extractImageURL({ output: {} })).toBeUndefined();
  });

  it('returns undefined when choices is an empty array', () => {
    expect(extractImageURL({ output: { choices: [] } })).toBeUndefined();
  });

  it('returns undefined when content is an empty array', () => {
    const payload: DashScopeImagePayload = {
      output: {
        choices: [{
          message: { content: [] },
        }],
      },
    };
    expect(extractImageURL(payload)).toBeUndefined();
  });

  it('returns undefined when message is missing', () => {
    const payload: DashScopeImagePayload = {
      output: {
        choices: [{}],
      },
    };
    expect(extractImageURL(payload)).toBeUndefined();
  });

  it('parses the usage information', () => {
    const payload: DashScopeImagePayload = {
      output: {
        choices: [{
          message: { content: [{ image: 'https://example.com/img.png' }] },
        }],
      },
      usage: { input_tokens: 100, output_tokens: 200 },
    };
    expect(payload.usage?.input_tokens).toBe(100);
    expect(payload.usage?.output_tokens).toBe(200);
    const total = (payload.usage?.input_tokens ?? 0) + (payload.usage?.output_tokens ?? 0);
    expect(total).toBe(300);
  });
});

/* ── D. Qwen region configuration ─────────────────────── */

describe('Qwen region configuration', () => {
  // Matches FALLBACK_QWEN_REGIONS in provider-config-catalog.ts: the native DashScope origins.
  // A region base carries no /compatible-mode/v1, matching the native chat path, which is what
  // stops a 404 after picking a region.
  const QWEN_REGIONS = [
    { id: 'sg', label: 'Singapore (International)', baseURL: 'https://dashscope-intl.aliyuncs.com' },
    { id: 'bj', label: 'Beijing (China Mainland)', baseURL: 'https://dashscope.aliyuncs.com' },
    { id: 'hk', label: 'Hong Kong', baseURL: 'https://cn-hongkong.dashscope.aliyuncs.com' },
    { id: 'us', label: 'Virginia (US)', baseURL: 'https://dashscope-us.aliyuncs.com' },
  ];

  it('has four regions', () => {
    expect(QWEN_REGIONS).toHaveLength(4);
  });

  it('has the right region ids', () => {
    const ids = QWEN_REGIONS.map((r) => r.id);
    expect(ids).toEqual(['sg', 'bj', 'hk', 'us']);
  });

  it('defaults to sg, the first entry', () => {
    expect(QWEN_REGIONS[0].id).toBe('sg');
  });

  it('gives every region a native origin, with no compatible-mode/v1, which would collide with the native path and 404', () => {
    for (const region of QWEN_REGIONS) {
      expect(region.baseURL).not.toMatch(/\/compatible-mode/);
      // Scheme and host only, no path.
      expect(new URL(region.baseURL).pathname).toBe('/');
    }
  });

  it('uses the dashscope-intl domain for sg', () => {
    expect(QWEN_REGIONS[0].baseURL).toBe('https://dashscope-intl.aliyuncs.com');
  });

  it('uses the main dashscope domain for bj', () => {
    expect(QWEN_REGIONS[1].baseURL).toBe('https://dashscope.aliyuncs.com');
  });

  it('uses the cn-hongkong subdomain for hk', () => {
    expect(QWEN_REGIONS[2].baseURL).toBe('https://cn-hongkong.dashscope.aliyuncs.com');
  });

  it('uses the dashscope-us domain for us', () => {
    expect(QWEN_REGIONS[3].baseURL).toBe('https://dashscope-us.aliyuncs.com');
  });
});

/* ── E. Qwen compatible endpoint URL normalization ───────────────────────── */

describe('resolveDashScopeCompatibleChatURL', () => {
  it('normalizes a native origin base to the compatible endpoint', () => {
    expect(resolveDashScopeCompatibleChatURL('https://dashscope-intl.aliyuncs.com'))
      .toBe('https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions');
  });

  it('does not repeat the prefix on a base that already contains /compatible-mode/v1', () => {
    expect(resolveDashScopeCompatibleChatURL('https://dashscope.aliyuncs.com/compatible-mode/v1'))
      .toBe('https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions');
  });

  it('strips a leftover native generation path back to the origin before appending the compatible endpoint', () => {
    expect(
      resolveDashScopeCompatibleChatURL(
        'https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/text-generation/generation',
      ),
    ).toBe('https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions');
  });

  it('sends a custom proxy (non-dashscope host) to the standard /chat/completions without compatible-mode', () => {
    expect(resolveDashScopeCompatibleChatURL('https://proxy.example.com/v1'))
      .toBe('https://proxy.example.com/v1/chat/completions');
  });

  it('keeps a URL that already ends in chat/completions unchanged', () => {
    expect(resolveDashScopeCompatibleChatURL('https://relay.io/v1/chat/completions'))
      .toBe('https://relay.io/v1/chat/completions');
  });
});

/* ── F. Qwen text chat builder (OpenAI compatible) ──────────── */

describe('buildQwenRequest text chat (OpenAI compatible)', () => {
  const baseParams = {
    providerKind: 'qwen',
    apiKey: 'sk-test',
    modelID: 'qwen3.6-flash',
    messages: [{ role: 'user', content: 'hi' }],
    baseURL: 'https://dashscope-intl.aliyuncs.com',
    options: {},
  } as unknown as RequestParams;

  it('text goes to the compatible endpoint with a standard OpenAI body and no native input or adapter', () => {
    const req = buildQwenRequest(baseParams, null, null, null);
    expect(req.url).toBe('https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions');
    expect(req.body.stream).toBe(true);
    expect(req.body.messages).toBeDefined();
    expect(req.body.input).toBeUndefined();
    expect(req.responseAdapter).toBeUndefined();
  });

  it('injects reasoning enable_thinking at the top level, not nested under parameters', () => {
    const req = buildQwenRequest(
      baseParams,
      { enable_thinking: true, thinking_budget: 1024 },
      null,
      null,
    );
    expect(req.body.enable_thinking).toBe(true);
    expect(req.body.thinking_budget).toBe(1024);
    expect(req.body.parameters).toBeUndefined();
  });

  it('flattens a reasoning value nested under native parameters to the top level', () => {
    const req = buildQwenRequest(
      baseParams,
      { parameters: { enable_thinking: true, thinking_budget: 4096 } },
      null,
      null,
    );
    expect(req.body.enable_thinking).toBe(true);
    expect(req.body.thinking_budget).toBe(4096);
    expect(req.body.parameters).toBeUndefined();
  });

  it('injects webSearch enable_search at the top level', () => {
    const params = {
      ...baseParams,
      options: { supportsWebSearch: true },
    } as unknown as RequestParams;
    const req = buildQwenRequest(params, null, { mergeParams: { enable_search: true } }, null);
    expect(req.body.enable_search).toBe(true);
  });

  it('images still go to the native multimodal endpoint with the qwen_images_api adapter', () => {
    const params = {
      ...baseParams,
      messages: [{ role: 'user', content: 'draw a fox' }],
    } as unknown as RequestParams;
    const req = buildQwenRequest(params, null, null, { route: 'dashscope_multimodal' });
    expect(req.url).toContain('/api/v1/services/aigc/multimodal-generation/generation');
    expect(req.responseAdapter).toBe('qwen_images_api');
  });
});
