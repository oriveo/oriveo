import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as groqService from '../groq';

describe('Groq proxy integration', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('validateKey does not go through the proxy or the upstream to check a Groq key', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ valid: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await groqService.validateKey('gsk_test', 'https://api.groq.com/openai/v1');

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('syncs Groq models through /api/providers/models in the browser', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({
        data: [{ id: 'llama-4-scout', context_window: 131072 }],
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    const result = await groqService.syncModels('gsk_test', 'https://api.groq.com/openai/v1');

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/providers/models',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({
          providerKind: 'groq',
          apiKey: 'gsk_test',
          baseURL: 'https://api.groq.com/openai/v1',
        }),
      }),
    );
    expect(result.models[0]?.id).toBe('llama-4-scout');
  });
});
