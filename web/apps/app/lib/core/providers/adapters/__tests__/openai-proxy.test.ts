import { beforeEach, describe, expect, it, vi } from 'vitest';

// Force USE_PROXY = true: at module top level under Vitest, typeof window === 'undefined'
vi.mock('../../proxy-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../proxy-client')>();
  return { ...actual, USE_PROXY: true };
});

// metadata-client mock - buildCatalogModel calls resolveCatalogModel internally
vi.mock('../../../metadata/metadata-client', () => ({
  initMetadata: vi.fn().mockResolvedValue(undefined),
  getProviderDefaultModelId: vi.fn().mockReturnValue('gpt-4o'),
  listProviderModelIds: vi.fn().mockReturnValue([]),
  resolveCatalogModel: vi.fn().mockReturnValue(null),
}));

import * as openAIService from '../openai';

describe('OpenAI proxy integration', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('validateKey does not verify the OpenAI key through the proxy or the upstream', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ valid: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await openAIService.validateKey('sk-test');

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('syncs OpenAI models through /api/providers/models in the browser', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({
        data: [{ id: 'gpt-4o' }],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    const result = await openAIService.syncModels('sk-test');

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/providers/models',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({
          providerKind: 'openAI',
          apiKey: 'sk-test',
        }),
      }),
    );
    expect(result.models[0]?.id).toBe('gpt-4o');
  });

  it('validateKey only rejects an empty key, it never verifies the key upstream', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ valid: false, error: 'Invalid API key' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await expect(openAIService.validateKey('   ')).rejects.toThrow('Missing API key.');
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it('validateKey is unaffected by an upstream network failure', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('Failed to fetch'));

    await expect(openAIService.validateKey('sk-test')).resolves.toBeUndefined();
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it('syncModels throws an invalidKey error when the proxy returns 401', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await expect(openAIService.syncModels('sk-bad')).rejects.toMatchObject({
      kind: 'invalidKey',
    });
  });
});
