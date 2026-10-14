import { describe, expect, it } from 'vitest';

import {
  applyDirectCustomHeaders,
  applyRelayPromptCacheKey,
  relayPromptCacheKey,
} from '../relay-adapter';
import { CODEX_CLIENT_VERSION_FALLBACK, resolveCodexClientVersion } from '../relay-codex-identity';
import { resolveRelayCodexClientVersion } from '../relay-runtime-support';
import type { RelayRuntimeConfig } from '../../ports';
import { buildRelayResponsesBody, buildRelayStreamRequest, type RelayMessages } from '../relay-orchestrator';
import type { StreamOptions } from '../types';

// Some relays decide whether the client is Codex solely by whether the request body has prompt_cache_key, and return 403 if it is missing.
// The expected values are identical on all three platforms; changing them here amounts to changing the contract.

const deps = {
  buildFetchArgs: (
    url: string,
    directHeaders: Record<string, string>,
    config: Parameters<typeof applyDirectCustomHeaders>[1],
  ) => ({ url, headers: applyDirectCustomHeaders(directHeaders, config, () => 'uuid') }),
  getRelayRuntimeConfig: () => null,
};

const firstTurn: RelayMessages = [
  { role: 'system', content: 'You are a golden fixture.' },
  { role: 'user', content: 'Hello' },
];
const secondTurn: RelayMessages = [
  ...firstTurn,
  { role: 'assistant', content: 'Hi there.' },
  { role: 'user', content: 'Summarize in one word.' },
];

function chat(messages: RelayMessages, options: StreamOptions) {
  const request = buildRelayStreamRequest('sk-test', 'golden-relay-model', messages, 'https://relay.example.com', options, deps);
  return { headers: request.headers, body: JSON.parse(request.body) as Record<string, unknown> };
}

describe('Relay Responses prompt_cache_key', () => {
  it('three expected values of the cache key pure function', () => {
    expect(relayPromptCacheKey('golden-relay-model', 'You are a golden fixture.', 'Hello'))
      .toBe('2290bbc6e2bae08a11ede516e419f3c6');
    expect(relayPromptCacheKey('gpt-6-sol', '', 'ping')).toBe('cd6af1a9ab51099a01ed5bf53656a023');
    expect(relayPromptCacheKey('m', '', '\u4f60\u597d 👋')).toBe('c1417132a678c57242b1b6476f059be0');
  });

  it('Relay Responses chat request body contains prompt_cache_key, with the same value on the second turn of one conversation', () => {
    const first = chat(firstTurn, { relayTransport: 'openai_responses' });
    const second = chat(secondTurn, { relayTransport: 'openai_responses', relayStream: false });
    expect(first.body.prompt_cache_key).toBe('2290bbc6e2bae08a11ede516e419f3c6');
    expect(second.body.prompt_cache_key).toBe(first.body.prompt_cache_key);
  });

  it('multi-part text of the first user message is concatenated directly in order, images not counted', () => {
    const { body } = chat([
      { role: 'user', content: [
        { type: 'text', text: '\u4f60\u597d' },
        { type: 'image_url', image_url: { url: 'data:image/png;base64,AAAA' } },
        { type: 'text', text: ' 👋' },
      ] },
    ], { relayTransport: 'openai_responses' });
    expect(body.model).toBe('golden-relay-model');
    expect(body.prompt_cache_key).toBe(relayPromptCacheKey('golden-relay-model', '', '\u4f60\u597d 👋'));
  });

  it('prompt_cache_key is absent when the Codex identity is off', () => {
    const off = chat(firstTurn, { relayTransport: 'openai_responses', relayCodexCompatIdentity: false });
    expect('prompt_cache_key' in off.body).toBe(false);
    expect(off.headers.Originator).toBeUndefined();
    // A connection without auth likewise does not inject identity headers, so the request body does not carry it either.
    const none = chat(firstTurn, { relayTransport: 'openai_responses', relayAuthMode: 'none' });
    expect('prompt_cache_key' in none.body).toBe(false);
    expect(none.headers.Originator).toBeUndefined();
  });

  it('Relay Chat Completions / Anthropic / Gemini request bodies do not contain it', () => {
    for (const relayTransport of ['openai_chat_completions', 'anthropic_messages', 'gemini_generate_content'] as const) {
      const { body } = chat(firstTurn, { relayTransport });
      expect('prompt_cache_key' in body, relayTransport).toBe(false);
    }
  });

  it('a user-written prompt_cache_key already in the request body is not overwritten', () => {
    const body: Record<string, unknown> = { model: 'm', prompt_cache_key: 'user-key' };
    applyRelayPromptCacheKey(body, { transport: 'openai_responses', authMode: 'bearer' }, firstTurn);
    expect(body.prompt_cache_key).toBe('user-key');
  });

  it('UA is codex_cli_rs/0.162.1 (Oriveo Web; Node.js)', () => {
    const { headers } = chat(firstTurn, { relayTransport: 'openai_responses' });
    expect(headers['User-Agent']).toBe('codex_cli_rs/0.162.1 (Oriveo Web; Node.js)');
    const custom = chat(firstTurn, { relayTransport: 'openai_responses', relayCustomUserAgent: 'My UA' });
    expect(custom.headers['User-Agent']).toBe('My UA');
    expect(custom.body.prompt_cache_key).toBe('2290bbc6e2bae08a11ede516e419f3c6');
  });
});

describe('official providers switched to the constructor shared with Responses', () => {
  it('buildRelayResponsesBody itself does not write prompt_cache_key (added only at the Relay exit by the identity criterion)', () => {
    const { body } = buildRelayResponsesBody('golden-relay-model', firstTurn, { relayStream: true }, null);
    expect('prompt_cache_key' in body).toBe(false);
  });
});

describe('version number of the Codex identity UA', () => {
  const userAgent = (codexClientVersion: unknown) => applyDirectCustomHeaders(
    {},
    { apiKey: 'sk-test', transport: 'openai_responses', authMode: 'bearer', codexClientVersion: codexClientVersion as string },
    () => 'uuid',
  )['User-Agent'];
  const runtime = (rule: Record<string, unknown>) =>
    ({ transportRules: { openai_responses: rule } }) as unknown as RelayRuntimeConfig;

  it('a valid delivered version -> UA uses the delivered value', () => {
    const version = resolveRelayCodexClientVersion(runtime({ codexClientVersion: '0.170.3' }));
    expect(version).toBe('0.170.3');
    expect(userAgent(version)).toBe('codex_cli_rs/0.170.3 (Oriveo Web; Node.js)');
  });

  it('delivered value missing / "latest" / "0.170.0-alpha.1" / a string with newlines -> UA uses 0.162.1', () => {
    expect(CODEX_CLIENT_VERSION_FALLBACK).toBe('0.162.1');
    expect(resolveRelayCodexClientVersion(null)).toBe('0.162.1');
    expect(resolveRelayCodexClientVersion(runtime({}))).toBe('0.162.1');
    expect(resolveRelayCodexClientVersion({ version: 'partial' } as unknown as RelayRuntimeConfig)).toBe('0.162.1');
    for (const invalid of [undefined, '', 'latest', '0.170.0-alpha.1', '0.170.0\n', '0.170.0\r\nX-Injected: 1', ' 0.170.0', '1234567.0.0', 170]) {
      expect(resolveRelayCodexClientVersion(runtime({ codexClientVersion: invalid })), String(invalid)).toBe('0.162.1');
      expect(resolveCodexClientVersion(invalid), String(invalid)).toBe('0.162.1');
      // An unvalidated value fed straight into the direct-connection config is still never spliced into request headers.
      expect(userAgent(invalid), String(invalid)).toBe('codex_cli_rs/0.162.1 (Oriveo Web; Node.js)');
    }
  });
});
