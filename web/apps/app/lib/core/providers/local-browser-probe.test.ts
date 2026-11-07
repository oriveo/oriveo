import { beforeEach, describe, expect, it, vi } from 'vitest';
import { connectLocalEngineInBrowser, fingerprintLocalEngineInBrowser, probeLocalEngineInBrowser } from './local-browser-probe';

const mocks = vi.hoisted(() => ({ sendMessageStream: vi.fn() }));

vi.mock('./adapters/relay', () => ({
  sendMessageStream: (...args: unknown[]) => mocks.sendMessageStream(...args),
}));

describe('probeLocalEngineInBrowser', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    mocks.sendMessageStream.mockReset();
    Object.defineProperty(navigator, 'permissions', {
      configurable: true,
      value: { query: vi.fn().mockResolvedValue({ state: 'granted' }) },
    });
  });

  it('accepts an explicit remote_https local-engine endpoint on the production browser probe path', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      expect(String(input)).toBe('https://engine.example/api/tags');
      expect(init).toMatchObject({ method: 'GET', credentials: 'omit', redirect: 'manual' });
      return new Response(JSON.stringify({ models: [] }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    });

    // The assertion reads the object returned by the production probe, proving the local engine flow accepts the HTTPS variant as an input.
    const result = await probeLocalEngineInBrowser({
      engine: 'ollama',
      endpoint: 'https://engine.example',
      securityMode: 'remote_https',
    });

    expect(result).toEqual({
      state: 'ready',
      failure: undefined,
      endpoint: 'https://engine.example',
      statusCode: 200,
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('allows only a .local special-use name and leaves the resolved-address check to browser LNA', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      expect(String(input)).toBe('http://engine.local:11434/api/tags');
      expect(init).toMatchObject({
        method: 'GET',
        credentials: 'omit',
        redirect: 'manual',
      });
      expect(init).not.toHaveProperty('targetAddressSpace');
      return new Response(JSON.stringify({ models: [] }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    });

    // This is the object produced by the production browser probe. If the browser resolves that
    // name to a non-local address, WICG LNA rejects the fetch after the connection is made and
    // this layer only sees cors_blocked, so the address space check cannot be bypassed.
    const result = await probeLocalEngineInBrowser({
      engine: 'ollama',
      endpoint: 'http://engine.local:11434',
      securityMode: 'local_http',
    });

    expect(result).toMatchObject({ state: 'ready', endpoint: 'http://engine.local:11434' });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('fails closed before fetch when Open WebUI has no bearer key, over HTTPS and local HTTP alike', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch');

    await expect(probeLocalEngineInBrowser({
      engine: 'openwebui',
      endpoint: 'https://openwebui.example',
      securityMode: 'remote_https',
    })).resolves.toMatchObject({ state: 'unreachable', failure: 'credential_required' });

    await expect(probeLocalEngineInBrowser({
      engine: 'openwebui',
      endpoint: 'http://127.0.0.1:3000',
      securityMode: 'local_http',
    })).resolves.toMatchObject({ state: 'unreachable', failure: 'credential_required' });

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('lets Open WebUI send its bearer key over loopback local HTTP', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      expect(String(input)).toBe('http://127.0.0.1:3000/api/models');
      expect(new Headers(init?.headers).get('authorization')).toBe('Bearer openwebui-secret');
      return new Response(JSON.stringify({ data: [{ id: 'fixture-model' }] }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    });

    await expect(probeLocalEngineInBrowser({
      engine: 'openwebui',
      endpoint: 'http://127.0.0.1:3000',
      securityMode: 'local_http',
      apiKey: 'openwebui-secret',
    })).resolves.toMatchObject({ state: 'ready', endpoint: 'http://127.0.0.1:3000' });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('sends Bearer on every request of a keyed non-Open WebUI engine over local HTTP, including generation', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      expect(new Headers(init?.headers).get('authorization')).toBe('Bearer ollama-secret');
      const body = String(input).endsWith('/api/tags')
        ? { models: [{ name: 'qwen2.5:0.5b' }] }
        : { capabilities: ['completion'] };
      return new Response(JSON.stringify(body), { status: 200, headers: { 'content-type': 'application/json' } });
    });
    mocks.sendMessageStream.mockReturnValue({
      abort: vi.fn(),
      stream: new ReadableStream<string>({
        start(controller) {
          controller.enqueue('ok');
          controller.close();
        },
      }),
    });

    const result = await connectLocalEngineInBrowser({
      engine: 'ollama',
      endpoint: 'http://127.0.0.1:11434',
      securityMode: 'local_http',
      apiKey: ' ollama-secret ',
    });

    expect(result).toMatchObject({ state: 'ready', generationVerified: true });
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(mocks.sendMessageStream).toHaveBeenCalledWith(
      'ollama-secret',
      'qwen2.5:0.5b',
      expect.any(Array),
      'http://127.0.0.1:11434/v1',
      expect.objectContaining({ relayAuthMode: 'bearer', relaySecurityMode: 'local_http' }),
    );
  });

  it('carries Bearer on all five fingerprint GETs only when a key is given', async () => {
    const seen: Array<string | null> = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (_input, init) => {
      seen.push(new Headers(init?.headers).get('authorization'));
      return new Response('{}', { status: 404, headers: { 'content-type': 'application/json' } });
    });

    await fingerprintLocalEngineInBrowser({ endpoint: 'http://127.0.0.1:8080', securityMode: 'local_http', apiKey: 'fp-secret' });
    expect(seen).toEqual(Array(5).fill('Bearer fp-secret'));

    seen.length = 0;
    await fingerprintLocalEngineInBrowser({ endpoint: 'http://127.0.0.1:8080', securityMode: 'local_http' });
    expect(seen).toEqual(Array(5).fill(null));
  });

  it('uses the Open WebUI bearer key on every direct request and the production chat stream', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      expect(String(input)).toBe('https://openwebui.example/api/models');
      expect(new Headers(init?.headers).get('authorization')).toBe('Bearer openwebui-secret');
      return new Response(JSON.stringify({
        data: [{ id: 'fixture-model', name: 'Fixture model' }],
        models: [{ id: 'fixture-model', name: 'Duplicate compatibility row' }],
      }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    });
    mocks.sendMessageStream.mockReturnValue({
      abort: vi.fn(),
      stream: new ReadableStream<string>({
        start(controller) {
          controller.enqueue('ok');
          controller.close();
        },
      }),
    });

    const result = await connectLocalEngineInBrowser({
      engine: 'openwebui',
      endpoint: 'https://openwebui.example',
      securityMode: 'remote_https',
      apiKey: 'openwebui-secret',
    });

    expect(result).toMatchObject({
      state: 'ready',
      generationVerified: true,
      modelIDs: ['fixture-model'],
      apiBaseURL: 'https://openwebui.example/api',
    });
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(mocks.sendMessageStream).toHaveBeenCalledWith(
      'openwebui-secret',
      'fixture-model',
      expect.any(Array),
      'https://openwebui.example/api',
      expect.objectContaining({
        relayAuthMode: 'bearer',
        relaySecurityMode: 'remote_https',
        relayStream: false,
        relayMaxOutputTokens: 1,
      }),
    );
  });

  it('keeps the Ollama introspection request CORS-safelisted for browser LAN access', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input);
      if (url.endsWith('/api/tags')) {
        return new Response(JSON.stringify({ models: [{ name: 'qwen2.5:0.5b' }] }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        });
      }
      expect(url).toBe('http://127.0.0.1:11434/api/show');
      expect(init?.method).toBe('POST');
      expect(new Headers(init?.headers).has('content-type')).toBe(false);
      expect(init?.body).toBe(JSON.stringify({ model: 'qwen2.5:0.5b' }));
      return new Response(JSON.stringify({ capabilities: ['completion'] }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    });
    mocks.sendMessageStream.mockReturnValue({
      abort: vi.fn(),
      stream: new ReadableStream<string>({
        start(controller) {
          controller.enqueue('ok');
          controller.close();
        },
      }),
    });

    const result = await connectLocalEngineInBrowser({
      engine: 'ollama',
      endpoint: 'http://127.0.0.1:11434',
      securityMode: 'local_http',
    });

    expect(result).toMatchObject({ state: 'ready', generationVerified: true });
    expect(fetchMock).toHaveBeenCalledTimes(3);
    for (const call of fetchMock.mock.calls) expect(new Headers(call[1]?.headers).has('authorization')).toBe(false);
    expect(mocks.sendMessageStream).toHaveBeenCalledWith(
      '',
      'qwen2.5:0.5b',
      expect.any(Array),
      'http://127.0.0.1:11434/v1',
      expect.objectContaining({ relayAuthMode: 'none' }),
    );
  });

  it('excludes LM Studio embedding rows from the selectable chat catalog', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async () => new Response(
      JSON.stringify({
        data: [
          { id: 'chat-model', type: 'llm', state: 'loaded' },
          { id: 'embedding-model', type: 'embeddings', state: 'not-loaded' },
        ],
      }),
      {
        status: 200,
        headers: { 'content-type': 'application/json' },
      },
    ));
    mocks.sendMessageStream.mockReturnValue({
      abort: vi.fn(),
      stream: new ReadableStream<string>({
        start(controller) {
          controller.enqueue('ok');
          controller.close();
        },
      }),
    });

    const result = await connectLocalEngineInBrowser({
      engine: 'lmstudio',
      endpoint: 'http://127.0.0.1:1234',
      securityMode: 'local_http',
    });

    expect(result.modelIDs).toEqual(['chat-model']);
    expect(result.models.map((model) => model.id)).toEqual(['chat-model']);
    expect(mocks.sendMessageStream).toHaveBeenCalledWith(
      '',
      'chat-model',
      expect.any(Array),
      'http://127.0.0.1:1234/v1',
      expect.any(Object),
    );
  });

  it('reports an Open WebUI bearer rejection without attempting catalog or generation requests', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({ detail: 'Invalid token' }), {
      status: 401,
      headers: { 'content-type': 'application/json' },
    }));

    const result = await connectLocalEngineInBrowser({
      engine: 'openwebui',
      endpoint: 'https://openwebui.example',
      securityMode: 'remote_https',
      apiKey: 'wrong-secret',
    });

    expect(result).toMatchObject({
      state: 'unreachable',
      failure: 'authentication_rejected',
      statusCode: 401,
      generationVerified: false,
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(mocks.sendMessageStream).not.toHaveBeenCalled();
  });
});
