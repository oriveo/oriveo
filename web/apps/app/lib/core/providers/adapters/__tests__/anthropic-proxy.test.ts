import { beforeEach, describe, expect, it, vi } from 'vitest';

// Force USE_PROXY = true; at the top level of a Vitest module, typeof window === 'undefined'.
vi.mock('../../proxy-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../proxy-client')>();
  return { ...actual, USE_PROXY: true };
});

// metadata-client mock: buildCatalogModel calls resolveCatalogModel internally.
vi.mock('../../../metadata/metadata-client', () => ({
  initMetadata: vi.fn().mockResolvedValue(undefined),
  getProviderDefaultModelId: vi.fn().mockReturnValue('claude-sonnet-4-20250514'),
  listProviderModelIds: vi.fn().mockReturnValue([]),
  resolveCatalogModel: vi.fn().mockReturnValue(null),
}));

import * as anthropicService from '../anthropic';

describe('Anthropic proxy integration', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('validateKey checks an Anthropic key without going through the proxy or the upstream', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ valid: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await anthropicService.validateKey('sk-ant-test');

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('syncs Anthropic models through /api/providers/models in the browser', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({
        data: [{ id: 'claude-sonnet-4-20250514' }],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    const result = await anthropicService.syncModels('sk-ant-test');

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/providers/models',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({
          providerKind: 'anthropic',
          apiKey: 'sk-ant-test',
        }),
      }),
    );
    expect(result.models[0]?.id).toBe('claude-sonnet-4-20250514');
  });

  it('validateKey rejects only an empty key', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ valid: false, error: 'Invalid API key' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await expect(anthropicService.validateKey('   ')).rejects.toThrow('Missing API key.');
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it('validateKey is unaffected by upstream network failures', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new TypeError('Failed to fetch'));

    await expect(anthropicService.validateKey('sk-ant-test')).resolves.toBeUndefined();
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it('syncModels throws an invalidKey error when the proxy returns 401', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await expect(anthropicService.syncModels('sk-ant-bad')).rejects.toMatchObject({
      kind: 'invalidKey',
    });
  });
});
