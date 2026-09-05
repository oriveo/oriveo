import { afterEach, describe, expect, it, vi } from 'vitest';

vi.mock('../desktop-stream', () => ({ IS_DESKTOP: true }));

import { pingRelay } from '../ping-relay';

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

const input = {
  baseURL: 'https://relay.example.com',
  apiKey: 'draft-relay-secret',
  plaintextKey: 'draft-relay-secret',
  modelID: 'gpt-4o',
  relayRequested: { transport: 'openai_chat_completions' as const, authMode: 'bearer' as const },
};

describe('pingRelay desktop bridge', () => {
  it('a new draft passes plaintextKey to main exactly once, and only a valid result succeeds', async () => {
    const validate = vi.fn(async () => ({ result: 'valid' as const, status: 200 }));
    vi.stubGlobal('window', { oriveo: { chat: {}, provider: { validate } } });

    await expect(pingRelay(input)).resolves.toMatchObject({ probedEndpoint: 'POST /chat/completions' });
    expect(validate).toHaveBeenCalledWith(expect.objectContaining({
      apiKeyRef: 'draft-relay-secret', plaintextKey: 'draft-relay-secret',
    }));
  });

  it('rejects when the bridge answers unverified, and never treats it as Connected', async () => {
    const validate = vi.fn(async () => ({ result: 'unverified' as const, status: 200 }));
    vi.stubGlobal('window', { oriveo: { chat: {}, provider: { validate } } });

    await expect(pingRelay(input)).rejects.toMatchObject({ kind: 'network' });
    expect(validate).toHaveBeenCalledOnce();
  });
});
