import { beforeEach, describe, expect, it, vi } from 'vitest';

// Force USE_PROXY = true, since typeof window === 'undefined' at module top level under Vitest.
vi.mock('../../proxy-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../proxy-client')>();
  return { ...actual, USE_PROXY: true };
});

// metadata-client mock: buildCatalogModel calls resolveCatalogModel internally.
vi.mock('../../../metadata/metadata-client', () => ({
  initMetadata: vi.fn().mockResolvedValue(undefined),
  getProviderDefaultModelId: vi.fn().mockReturnValue('gemini-2.5-flash'),
  listProviderModelIds: vi.fn().mockReturnValue([]),
  resolveCatalogModel: vi.fn().mockReturnValue(null),
}));

import * as geminiService from '../gemini';

describe('Gemini proxy integration', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('validateKey does not call the proxy or upstream to check a Gemini key', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ valid: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await geminiService.validateKey('AIza_test');

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('syncs Gemini models through /api/providers/models in a browser environment', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({
        data: [{ id: 'gemini-2.5-flash' }],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    const result = await geminiService.syncModels('AIza_test');

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/providers/models',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({
          providerKind: 'gemini',
          apiKey: 'AIza_test',
        }),
      }),
    );
    expect(result.models[0]?.id).toBe('gemini-2.5-flash');
  });

  it('validateKey rejects only an empty key', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ valid: false, error: 'Invalid API key' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await expect(geminiService.validateKey('   ')).rejects.toThrow('Missing API key.');
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it('validateKey is unaffected by an upstream network error', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('Failed to fetch'));

    await expect(geminiService.validateKey('AIza_test')).resolves.toBeUndefined();
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it('syncModels throws an invalidKey error when the proxy returns 401', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await expect(geminiService.syncModels('AIza_bad')).rejects.toMatchObject({
      kind: 'invalidKey',
    });
  });
});
