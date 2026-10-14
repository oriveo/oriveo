// E2-DISPATCH-01: the protocol of an official provider is decided by metadata providerConfigs[].apiProtocol.
// Through the production buildProviderRequest: MiniMax with anthropic -> Messages shape + MiniMax's own auth;
// equal to the native family / missing / unknown -> the original per-provider builder is unchanged.
import { describe, expect, it } from 'vitest';
import { buildProviderRequest } from '../dispatch';
import type { RuntimeMetadataResponse } from '../runtime';

function metadataWith(apiProtocol: string | undefined, extra: Partial<RuntimeMetadataResponse> = {}): RuntimeMetadataResponse {
  return {
    version: 1,
    updatedAt: '2026-10-10T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    providers: {
      miniMax: {
        transport: { baseUrl: 'https://api.minimax.io/anthropic', endpoints: {} },
        resolveMap: { 'MiniMax-M2.7': 'MiniMax-M2.7' },
        models: { 'MiniMax-M2.7': { capabilities: ['text'] } },
      },
    },
    providerConfigs: [{ kind: 'miniMax', ...(apiProtocol !== undefined ? { apiProtocol } : {}) }],
    ...extra,
  } as unknown as RuntimeMetadataResponse;
}

const params = {
  providerKind: 'miniMax' as const,
  apiKey: 'sk-minimax',
  modelID: 'MiniMax-M2.7',
  messages: [
    { role: 'system' as const, content: 'be brief' },
    { role: 'user' as const, content: 'hello' },
  ],
  stream: true,
};

describe('E2-DISPATCH-01 official providers dispatch by apiProtocol', () => {
  it('miniMax with apiProtocol=anthropic: Messages shape, MiniMax auth (Bearer), no x-api-key', async () => {
    const request = await buildProviderRequest(params, async () => metadataWith('anthropic'));
    expect(request.url).toBe('https://api.minimax.io/anthropic/v1/messages');
    expect(request.headers.Authorization).toBe('Bearer sk-minimax');
    expect(request.headers['anthropic-version']).toBe('2023-06-01');
    expect(request.headers).not.toHaveProperty('x-api-key');
    expect(request.body).toMatchObject({
      model: 'MiniMax-M2.7',
      stream: true,
      system: 'be brief',
      messages: [{ role: 'user', content: [{ type: 'text', text: 'hello' }] }],
    });
    expect(typeof request.body.max_tokens).toBe('number');
    // Dialect fields of the native MiniMax builder are not carried over to another protocol.
    expect(request.body).not.toHaveProperty('reasoning_split');
    expect(request.responseAdapter).toBeUndefined();
  });

  it('anthropic but the base URL is not in the trusted table: the delivered base URL is not used, falls back to the built-in default host', async () => {
    const metadata = metadataWith('anthropic');
    (metadata.providers.miniMax as { transport: { baseUrl: string } }).transport.baseUrl = 'https://evil.example/anthropic';
    const request = await buildProviderRequest(params, async () => metadata);
    expect(new URL(request.url).hostname).toBe('api.minimax.io');
    expect(request.url.endsWith('/messages')).toBe(true);
  });

  it('tool-role messages are not carried over: consistent with the Relay streaming path (whose message types are only user / assistant / system)', async () => {
    const request = await buildProviderRequest({
      ...params,
      messages: [
        { role: 'user', content: 'weather?' },
        { role: 'assistant', content: '', tool_calls: [{ id: 'c1', type: 'function', function: { name: 'w', arguments: '{}' } }] },
        { role: 'tool', content: 'sunny', tool_call_id: 'c1' },
        { role: 'user', content: 'thanks' },
      ],
    }, async () => metadataWith('anthropic'));
    const roles = (request.body.messages as { role: string }[]).map((message) => message.role);
    expect(roles).toEqual(['user', 'assistant', 'user']);
    expect(JSON.stringify(request.body)).not.toContain('tool_call');
  });

  it.each([['openai_compatible'], ['openai'], [undefined], ['made_up_protocol']])(
    'apiProtocol=%s: uses the original MiniMax builder (Chat shape, reasoning_split)',
    async (apiProtocol) => {
      const request = await buildProviderRequest(params, async () => metadataWith(apiProtocol));
      expect(request.url.endsWith('/chat/completions')).toBe(true);
      expect(request.body.reasoning_split).toBe(true);
      expect(request.responseAdapter).toBe('minimax_chat_stream');
    },
  );
});
