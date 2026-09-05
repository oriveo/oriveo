/**
 * Relay custom request fields must actually go out on the wire.
 *
 * Relay does not go through the `/api/chat/stream` dispatch, so `options.customFragments` has to be
 * handled inside `relay-orchestrator`. Without that the whole chain is a fake entry point: the
 * editor says "enabled", the panel says "the preference above will not be sent", both are false, no
 * custom field reaches the request, and fail-closed never applies either.
 *
 * Authority: only the `generation` owner, and only the exact local transport profile. Everything
 * else fails closed.
 */
import { describe, expect, it } from 'vitest';
import { sendRelayStream, type RelayOrchestratorDeps } from '../relay-orchestrator';
import type { StreamOptions } from '../types';

const generationProfile = {
  template: 'openai_chat',
  wire: { temperature: 'temperature', topP: 'top_p' },
  parameters: {},
} as unknown as NonNullable<StreamOptions['generationProfile']>;

describe('relay custom request fields', () => {
  it('a declared leaf really is written into the outbound body', async () => {
    const body = await outboundBody({
      generationProfile,
      customFragments: { generation: { raw: '{"top_p":0.25}' } },
    });
    expect(body.top_p).toBe(0.25);
    // Coexists with the existing typed injection: custom fields only fill their own leaves and do not displace others.
    expect(body.model).toBe('my-private-model');
  });

  it('a path the profile does not declare fails closed: the request is never sent rather than downgraded', async () => {
    await expect(outboundBody({
      generationProfile,
      customFragments: { generation: { raw: '{"frequency_penalty":1}' } },
    })).rejects.toThrow(/Safe custom fragment rejected/);
  });

  it('custom selected with empty content also fails closed, matching the dispatch verdict', async () => {
    await expect(outboundBody({
      generationProfile,
      customFragments: { generation: { raw: '   ' } },
    })).rejects.toThrow(/Safe custom fragment rejected/);
  });

  it('with no local profile, no compatible body shape is guessed and the request fails closed', async () => {
    await expect(outboundBody({
      customFragments: { generation: { raw: '{"top_p":0.25}' } },
    })).rejects.toThrow('Safe custom fragment rejected: unknown_owned_path');
  });

  it('relay recognizes only the generation owner: web / reasoning have no local authority and fail closed', async () => {
    for (const owner of ['web', 'reasoning'] as const) {
      await expect(outboundBody({
        generationProfile,
        customFragments: { [owner]: { raw: '{"top_p":0.25}' } },
      })).rejects.toThrow('Safe custom fragment rejected: unknown_owned_path');
    }
  });

  it('with no custom fields configured this path changes not a single byte', async () => {
    const body = await outboundBody({ generationProfile });
    expect(body.top_p).toBeUndefined();
  });
});

/** Run the **production** relay send path and capture the body that actually goes out, rather than duplicating the body assembly. */
async function outboundBody(options: Partial<StreamOptions>): Promise<Record<string, unknown>> {
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
  const handle = sendRelayStream(
    'sk-relay',
    'my-private-model',
    [{ role: 'user', content: 'hello' }],
    'https://relay.example/v1',
    { ...options, relayStream: false, relayTransport: 'openai_chat_completions' } as StreamOptions,
    deps,
  );
  const events: Array<{ type: string; error?: string }> = [];
  const reader = handle.stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    events.push(value as { type: string; error?: string });
  }
  const failure = events.find((event) => event.type === 'error');
  // On this path fail-closed shows up as an error event (the request was never sent); turn it back into an exception so it can be asserted.
  if (failure) throw new Error(failure.error ?? 'relay stream error');
  expect(captured, 'the production relay send path issued no request').toBeDefined();
  return captured!;
}
