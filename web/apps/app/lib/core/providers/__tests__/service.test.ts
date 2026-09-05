import { beforeEach, describe, expect, it, vi } from 'vitest';
import { sendStream, validateProviderKey } from '../service';

describe('provider service proxy streaming', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('streaming chat in the browser goes through the /api/chat/stream proxy', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('data: [DONE]\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }),
    );

    const handle = sendStream(
      'groq',
      'gsk_test',
      'llama-4-scout',
      [{ role: 'user', content: 'hello' }],
      'https://api.groq.com/openai/v1',
    );

    const reader = handle.stream.getReader();
    const { value } = await reader.read();

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/chat/stream',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({
          providerKind: 'groq',
          apiKey: 'gsk_test',
          modelID: 'llama-4-scout',
          messages: [{ role: 'user', content: 'hello' }],
          baseURL: 'https://api.groq.com/openai/v1',
          options: undefined,
        }),
      }),
    );
    expect(value).toEqual({ type: 'done' });
  });

  it('the Kimi mainland China endpoint is called directly from the browser, avoiding an unreachable outbound path from the production server', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('data: [DONE]\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }),
    );

    const handle = sendStream(
      'moonshot',
      'sk-kimi-cn',
      'kimi-k2.6',
      [{ role: 'user', content: 'hello' }],
      'https://api.moonshot.cn/v1',
    );

    const reader = handle.stream.getReader();
    const { value } = await reader.read();

    expect(fetchMock).toHaveBeenCalledWith(
      'https://api.moonshot.cn/v1/chat/completions',
      expect.objectContaining({
        method: 'POST',
        headers: expect.objectContaining({
          Authorization: 'Bearer sk-kimi-cn',
        }),
      }),
    );
    expect(fetchMock).not.toHaveBeenCalledWith(
      '/api/chat/stream',
      expect.anything(),
    );
    expect(value).toEqual({ type: 'done' });
  });

  it('a public relay endpoint is reverse-proxied through the server in the browser and carries no first-party credentials', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('data: {"choices":[{"delta":{"content":"hi"}}]}\n\ndata: [DONE]\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }),
    );

    const handle = sendStream(
      'relay',
      'sk_test',
      'gpt-4o',
      [{ role: 'user', content: 'hello' }],
      'https://relay.example.com/v1',
    );

    const reader = handle.stream.getReader();
    const { value } = await reader.read();

    // A public relay does not allow CORS for browsers, so the request goes through /api/relay/forward with the upstream address and credentials in custom headers
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/relay/forward',
      expect.objectContaining({
        method: 'POST',
        credentials: 'omit',
        headers: expect.objectContaining({
          'X-Relay-Upstream-URL': 'https://relay.example.com/v1/chat/completions',
        }),
      }),
    );
    // A relay never borrows the /api/chat/stream route used by official providers
    expect(fetchMock).not.toHaveBeenCalledWith(
      '/api/chat/stream',
      expect.anything(),
    );
    expect(value).toEqual({ type: 'delta', content: 'hi' });
  });

  it('relay key validation uses /api/providers/validate in the browser', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ valid: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await validateProviderKey('relay', 'sk_test', 'https://relay.example.com/v1');

    expect(fetchMock).toHaveBeenCalledWith(
      '/api/providers/validate',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({
          providerKind: 'relay',
          apiKey: 'sk_test',
          baseURL: 'https://relay.example.com/v1',
        }),
      }),
    );
    expect(fetchMock).not.toHaveBeenCalledWith(
      'https://relay.example.com/v1/models',
      expect.anything(),
    );
  });
});
