/**
 * Additional request body integration points: every assertion reads the real request body produced
 * by a production path (official dispatch and the three Relay transports). Panel parameters stay,
 * the additional body wins on name clashes, and protected fields are rejected locally with no
 * request sent.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { AdditionalBodyRejectedError } from '../additional-body';
import { buildProviderRequest } from '../dispatch';
import type { RuntimeMetadataResponse } from '../runtime';
import type { GenerationParameterProfile } from '../types';
import { sendRelayStream, type RelayOrchestratorDeps } from '../../relay-orchestrator';
import type { StreamOptions } from '../../types';

const profile = (template: string): GenerationParameterProfile => ({
  template,
  wire: { max_output_tokens: 'max_tokens', temperature: 'temperature', top_p: 'top_p', top_k: 'top_k' },
  parameters: [
    { id: 'max_output_tokens', support: 'supported', source: 'test', valueSchema: 'integer', range: { min: 1 } },
    { id: 'temperature', support: 'supported', source: 'test', valueSchema: 'number', range: { min: 0, max: 1 } },
    { id: 'top_p', support: 'supported', source: 'test', valueSchema: 'number', range: { min: 0, max: 1 } },
    { id: 'top_k', support: 'supported', source: 'test', valueSchema: 'integer', range: { min: 0 } },
  ],
});

const panel = {
  temperature: { state: 'value', value: 0.5 },
  top_p: { state: 'value', value: 0.9 },
} as const;
const ADDITIONAL = '{"temperature": 0.1, "metadata": {"user_id": "u-1"}, "chat_template_kwargs": {"enable_thinking": false}}';

function expectMerged(body: Record<string, unknown>): void {
  expect(body.temperature).toBe(0.1);
  expect(body.top_p).toBe(0.9);
  expect(body.metadata).toEqual({ user_id: 'u-1' });
  expect(body.chat_template_kwargs).toEqual({ enable_thinking: false });
}

describe('official path (dispatch buildProviderRequest)', () => {
  const metadata = async () => loadJSON<{ metadata: RuntimeMetadataResponse }>('request_shape_contract.v1.json').metadata;

  it('Anthropic: additional fields are merged last, panel parameters stay, and the additional body wins on name clashes', async () => {
    const request = await buildProviderRequest({
      providerKind: 'anthropic', apiKey: 'k', modelID: 'claude-sonnet-4-6', baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hello' }],
      options: { generationProfile: profile('anthropic_messages'), generationParameters: panel, additionalBody: { raw: ADDITIONAL } },
    }, metadata);
    expectMerged(request.body);
    expect(request.body.model).toBe('claude-sonnet-4-6');
    expect(request.body.messages).toEqual([{ role: 'user', content: 'hello' }]);
  });

  it('protected fields are rejected locally: throws AdditionalBodyRejectedError with a safe code', async () => {
    const error = await buildProviderRequest({
      providerKind: 'anthropic', apiKey: 'k', modelID: 'claude-sonnet-4-6', baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hello' }],
      options: { additionalBody: { raw: '{"system": "override", "top_k": 1}' } },
    }, metadata).catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(AdditionalBodyRejectedError);
    expect((error as AdditionalBodyRejectedError).code).toBe('additional_body_rejected:protected_field:system');
  });
});

describe('last step of the Relay transports', () => {
  for (const transport of ['openai_chat_completions', 'anthropic_messages', 'llamacpp_native'] as const) {
    it(`${transport}: additional fields are merged and panel parameters stay`, async () => {
      const template = transport === 'anthropic_messages' ? 'anthropic_messages' : 'openai_chat';
      const { bodies } = await relaySend({
        relayTransport: transport,
        generationProfile: profile(template), generationParameters: panel, additionalBody: { raw: ADDITIONAL },
      });
      expect(bodies).toHaveLength(1);
      expectMerged(bodies[0]!);
    });
  }

  it('protected fields are rejected locally and no request is sent', async () => {
    for (const transport of ['openai_chat_completions', 'anthropic_messages', 'llamacpp_native'] as const) {
      const sent: Record<string, unknown>[] = [];
      const outcome = await relaySend({ relayTransport: transport, additionalBody: { raw: '{"messages": []}' } }, sent)
        .catch((caught: unknown) => caught);
      expect(outcome).toBeInstanceOf(AdditionalBodyRejectedError);
      expect((outcome as AdditionalBodyRejectedError).code).toBe('additional_body_rejected:protected_field:messages');
      expect(sent, transport).toHaveLength(0);
    }
  });
});

async function relaySend(
  options: Partial<StreamOptions>,
  bodies: Record<string, unknown>[] = [],
): Promise<{ bodies: Record<string, unknown>[] }> {
  const deps: RelayOrchestratorDeps = {
    transport: {
      fetch: async (_url, init) => {
        bodies.push(JSON.parse(String(init.body)) as Record<string, unknown>);
        return new Response('{}', { status: 200 });
      },
    },
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
  const handle = sendRelayStream('sk-relay', 'local-model', [{ role: 'user', content: 'hello' }], 'https://relay.example/v1',
    { relayStream: false, ...options } as StreamOptions, deps);
  const reader = handle.stream.getReader();
  while (!(await reader.read()).done) { /* drain the whole stream */ }
  return { bodies };
}

function loadJSON<T>(fileName: string): T {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'shared', 'model-contracts', fileName);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${fileName} not found`);
    current = parent;
  }
}
