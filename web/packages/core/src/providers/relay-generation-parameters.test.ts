import { describe, expect, it } from 'vitest';
import { sendRelayStream } from './relay-orchestrator';
import type { RelayOrchestratorDeps } from './relay-orchestrator';
import type { StreamOptions } from './types';

async function outboundBody(
  transport: NonNullable<StreamOptions['relayTransport']>,
  profile: NonNullable<StreamOptions['generationProfile']>,
  generationParameters: NonNullable<StreamOptions['generationParameters']>,
): Promise<Record<string, unknown>> {
  let captured: Record<string, unknown> | undefined;
  const deps: RelayOrchestratorDeps = {
    transport: {
      fetch: async (_url, init) => {
        captured = JSON.parse(String(init.body)) as Record<string, unknown>;
        return new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), { status: 200 });
      },
    },
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
  const handle = sendRelayStream('key', 'model-a', [{ role: 'user', content: 'hello' }], 'https://relay.example', {
    relayTransport: transport,
    relayAuthMode: 'bearer',
    relayStream: false,
    generationProfile: profile,
    generationParameters,
  }, deps);
  await handle.stream.getReader().read();
  expect(captured).toBeDefined();
  return captured!;
}

describe('relay generation parameter profile injection', () => {
  it('all four protocols send only what the metadata profile wire map declares', async () => {
    await expect(outboundBody('openai_chat_completions', {
      template: 'openai_chat_completions',
      wire: { temperature: 'temperature' },
      parameters: [{ id: 'temperature', support: 'supported', source: 'catalog' }],
    }, { temperature: { state: 'value', value: 0 } })).resolves.toMatchObject({ temperature: 0 });

    await expect(outboundBody('openai_responses', {
      template: 'openai_responses',
      wire: { max_output_tokens: 'max_output_tokens' },
      parameters: [{ id: 'max_output_tokens', support: 'supported', source: 'catalog' }],
    }, { max_output_tokens: { state: 'value', value: 128 } })).resolves.toMatchObject({ max_output_tokens: 128 });

    await expect(outboundBody('anthropic_messages', {
      template: 'anthropic_messages',
      wire: { stop: 'stop_sequences' },
      parameters: [{ id: 'stop', support: 'supported', source: 'catalog' }],
    }, { stop: { state: 'value', value: ['END'] } })).resolves.toMatchObject({ stop_sequences: ['END'] });

    await expect(outboundBody('gemini_generate_content', {
      template: 'gemini_generate_content',
      wire: { top_p: 'generationConfig.topP' },
      parameters: [{ id: 'top_p', support: 'supported', source: 'catalog' }],
    }, { top_p: { state: 'value', value: 0.8 } })).resolves.toMatchObject({
      generationConfig: expect.objectContaining({ topP: 0.8 }),
    });
  });

  it('injects nothing without a profile, even when the user has local defaults', async () => {
    const body = await outboundBody('openai_chat_completions', {
      template: 'empty', wire: {}, parameters: [],
    }, { temperature: { state: 'value', value: 0.4 } });
    expect(body).not.toHaveProperty('temperature');
  });

  it('llama.cpp native transport posts to /completion, vLLM non-standard fields go into extra_body only', async () => {
    const llama = await outboundBody('llamacpp_native', {
      template: 'llamacpp_native',
      wire: { max_output_tokens: 'n_predict', temperature: 'temperature' },
      parameters: [
        { id: 'max_output_tokens', support: 'accepted_unverified', source: 'engine_profile' },
        { id: 'temperature', support: 'accepted_unverified', source: 'engine_profile' },
      ],
    }, {
      max_output_tokens: { state: 'value', value: 32 },
      temperature: { state: 'value', value: 0 },
    });
    expect(llama).toMatchObject({ prompt: 'user: hello', n_predict: 32, temperature: 0 });
    expect(llama).not.toHaveProperty('model');

    const vllm = await outboundBody('openai_chat_completions', {
      template: 'vllm_extra_body',
      wire: { top_k: 'extra_body.top_k', min_p: 'extra_body.min_p' },
      parameters: [
        { id: 'top_k', support: 'accepted_unverified', source: 'engine_profile' },
        { id: 'min_p', support: 'accepted_unverified', source: 'engine_profile' },
      ],
    }, {
      top_k: { state: 'value', value: 40 },
      min_p: { state: 'value', value: 0.05 },
    });
    expect(vllm).toMatchObject({ extra_body: { top_k: 40, min_p: 0.05 } });
    expect(vllm).not.toHaveProperty('top_k');
  });
});
