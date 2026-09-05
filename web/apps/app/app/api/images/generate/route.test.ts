import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// proxy.example.com is an RFC 2606 reserved test domain and does not resolve in a real environment
// (NXDOMAIN), so the SSRF guard's DNS check would fail closed with a 403. DNS resolution is mocked
// to a fixed public address here so the guard's protocol, port, private-literal and public-domain
// checks still run through the real code, without depending on real network resolution.
//
// The guard's own behavior (403 for unreachable or private addresses, including DNS rebinding) is
// covered by ssrf-guard.test.ts. This file adds one 403 assertion for a private IP literal (see
// "rejects requests to forbidden addresses" below), because a literal IP is blocked before DNS
// resolution and is therefore unaffected by the DNS mock, which proves the guard is live in this route.
const dnsMocks = vi.hoisted(() => ({
  resolve4: vi.fn(async () => ['203.0.113.10']),
  resolve6: vi.fn(async () => {
    throw Object.assign(new Error('ENODATA'), { code: 'ENODATA' });
  }),
  lookup: vi.fn(async () => [{ address: '203.0.113.10', family: 4 }]),
}));

vi.mock('node:dns/promises', () => ({
  default: dnsMocks,
  ...dnsMocks,
}));

import { POST } from './route';

const fetchMock = vi.fn();

function buildRequest(body: unknown): Request {
  return new Request('http://localhost/api/images/generate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

describe('/api/images/generate', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.stubGlobal('fetch', fetchMock);
    fetchMock.mockReset();
  });

  it('rejects requests without an API key or prompt', async () => {
    const response = await POST(
      buildRequest({ apiKey: '', prompt: '' }) as never,
    );

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({ error: 'Missing required fields' });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('forwards image generation requests to the configured upstream endpoint', async () => {
    fetchMock.mockResolvedValue(
      new Response(
        JSON.stringify({
          data: [{ b64_json: 'image-data' }],
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const response = await POST(
      buildRequest({
        apiKey: 'sk-openai',
        prompt: 'draw a cat',
        quality: 'hd',
        style: 'vivid',
        baseURL: 'https://proxy.example.com/v1',
      }) as never,
    );

    expect(fetchMock).toHaveBeenCalledWith(
      'https://proxy.example.com/v1/images/generations',
      expect.objectContaining({
        method: 'POST',
        headers: expect.objectContaining({
          Authorization: 'Bearer sk-openai',
          'Content-Type': 'application/json',
        }),
      }),
    );
    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body))).toEqual({
      model: 'dall-e-3',
      prompt: 'draw a cat',
      n: 1,
      size: '1024x1024',
      response_format: 'b64_json',
      quality: 'hd',
      style: 'vivid',
    });
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      data: [{ b64_json: 'image-data' }],
    });
  });

  it('merges requestDefaults without allowing model or prompt override', async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ data: [{ b64_json: 'image-data' }] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await POST(
      buildRequest({
        apiKey: 'sk-openai',
        model: 'dall-e-3',
        prompt: 'draw a cat',
        requestDefaults: {
          size: '512x512',
          n: 2,
          response_format: 'url',
          model: 'bad-model',
          prompt: 'bad prompt',
        },
      }) as never,
    );

    expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body))).toEqual({
      model: 'dall-e-3',
      prompt: 'draw a cat',
      n: 2,
      size: '512x512',
      response_format: 'url',
    });
  });

  it('returns the upstream error text and status when OpenAI rejects the request', async () => {
    fetchMock.mockResolvedValue(
      new Response('quota exceeded', { status: 429 }),
    );

    const response = await POST(
      buildRequest({ apiKey: 'sk-openai', prompt: 'draw a cat' }) as never,
    );

    expect(response.status).toBe(429);
    await expect(response.json()).resolves.toEqual({ error: 'quota exceeded' });
  });

  it('maps fetch failures to a 502 proxy error', async () => {
    fetchMock.mockRejectedValue(new Error('network down'));

    const response = await POST(
      buildRequest({ apiKey: 'sk-openai', prompt: 'draw a cat' }) as never,
    );

    expect(response.status).toBe(502);
    await expect(response.json()).resolves.toEqual({ error: 'Failed to generate image' });
  });

  it('rejects requests to forbidden addresses (SSRF guard stays live in this route)', async () => {
    const response = await POST(
      buildRequest({
        apiKey: 'sk-openai',
        prompt: 'draw a cat',
        // Cloud metadata address literal: blocked before DNS resolution, so the DNS mock at the top of this file does not apply.
        baseURL: 'https://169.254.169.254/v1',
      }) as never,
    );

    expect(response.status).toBe(403);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
