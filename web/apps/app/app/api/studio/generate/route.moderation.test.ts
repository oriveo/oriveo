// @vitest-environment node
/**
 * POST /api/studio/generate runs without content moderation: even with a moderation
 * endpoint that would deny and a moderation key set, the route never calls the moderation service
 * and forwards to the upstream once after the SSRF check; production without a
 * key does not fail closed either.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { repoRoot } from '../../../../../../test-support/repo-root';

const ROOT = repoRoot();
// Shared contracts directory name, spelled by code point to keep this file ASCII.
const CONTRACTS = resolve(ROOT, 'shared', 'model-contracts');
const normalization = JSON.parse(
  readFileSync(resolve(CONTRACTS, 'image_param_normalization.v1.json'), 'utf8'),
) as { profiles: Record<string, Record<string, unknown>> };

const MODERATION_URL = 'https://moderation.example.com/v1/moderation/prompt';
const BASE_URL = 'https://8.8.8.8/v1';
const UPSTREAM_URL = `${BASE_URL}/images/generations`;

function u32be(value: number): number[] {
  return [(value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff];
}

const OUTPUT = Uint8Array.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
  ...u32be(13), 0x49, 0x48, 0x44, 0x52,
  ...u32be(16), ...u32be(16),
  8, 6, 0, 0, 0, 0, 0, 0, 0,
]);

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

function buildRequest(): Request {
  const form = new FormData();
  form.append(
    'request',
    JSON.stringify({
      providerKind: 'openai',
      apiKey: 'test-key',
      baseURL: BASE_URL,
      modelId: 'gpt-image-2',
      profile: normalization.profiles.openai_gpt_image,
      operation: 'generate',
      prompt: { userPrompt: 'a red apple', references: [] },
      params: {},
      advanced: null,
      images: [],
    }),
  );
  return new Request('http://localhost/api/studio/generate', {
    method: 'POST',
    body: form,
    headers: { 'x-forwarded-for': '192.0.2.44' },
  });
}

async function loadRoute() {
  vi.resetModules();
  const rateLimit = await import('../../chat/stream/rate-limit');
  rateLimit.__resetRateLimitForTests();
  return import('./route');
}

async function resultOf(response: Response): Promise<Record<string, unknown>> {
  expect(response.status).toBe(200);
  const text = await response.text();
  const match = /event: result\ndata: (.*)\n\n$/.exec(text);
  if (!match) throw new Error(`no trailing result frame in ${JSON.stringify(text)}`);
  return JSON.parse(match[1]!) as Record<string, unknown>;
}

/** Fakes the moderation service with the given reply and counts upstream calls. */
function fakeFetch(moderation: () => Response) {
  const calls = { moderation: [] as unknown[], upstream: 0 };
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = String(input);
    if (url === MODERATION_URL) {
      calls.moderation.push(JSON.parse(String(init?.body)));
      return moderation();
    }
    if (url === UPSTREAM_URL) {
      calls.upstream += 1;
      return jsonResponse({ created: 1, data: [{ b64_json: Buffer.from(OUTPUT).toString('base64') }] });
    }
    throw new Error(`unexpected fetch ${url}`);
  });
  return calls;
}

describe('/api/studio/generate without content moderation', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.stubEnv('CREEM_MODERATION_BASE_URL', '');
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
  });

  it('does not call the moderation service and forwards to the upstream once', async () => {
    vi.stubEnv('CREEM_MODERATION_API_KEY', 'creem_test_key');
    const calls = fakeFetch(() => jsonResponse({ decision: 'deny' }));
    const { POST } = await loadRoute();

    const result = await resultOf(await POST(buildRequest()));

    expect(calls.moderation).toEqual([]);
    expect(calls.upstream).toBe(1);
    expect(result).toMatchObject({ status: 'completed', errorKind: null, delivered: 1 });
  });

  it('does not fail closed without a moderation key in production', async () => {
    vi.stubEnv('NODE_ENV', 'production');
    vi.stubEnv('CREEM_MODERATION_API_KEY', '');
    const calls = fakeFetch(() => jsonResponse({ decision: 'deny' }));
    const { POST } = await loadRoute();

    const result = await resultOf(await POST(buildRequest()));

    expect(calls.moderation).toEqual([]);
    expect(calls.upstream).toBe(1);
    expect(result).toMatchObject({ status: 'completed', errorKind: null, delivered: 1 });
  });
});
