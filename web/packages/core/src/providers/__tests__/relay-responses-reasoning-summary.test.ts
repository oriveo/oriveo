/**
 * The `reasoning.summary` contract for Relay Responses, plus evidence for an explicit
 * rejection.
 *
 * Two things have to be proven together, or this default should not be on:
 *  1. Web relay sends `summary:'auto'` as a matter of course, since without it the upstream
 *     never emits `response.reasoning_summary_text.delta` and web users never see the
 *     reasoning trace.
 *  2. When a relay really does reject summary, the original body and error must be raised;
 *     scanning the body and silently dropping the parameter to retry is not allowed.
 */
import { beforeEach, describe, expect, it } from 'vitest';
import { sendRelayStream, type RelayOrchestratorDeps } from '../relay-orchestrator';
import { fetchRelayRequest } from '../relay-stream';
import {
  resetUnsupportedParamCacheForTesting,
  setUnsupportedParamPatterns,
} from '../unsupported-param';
import type { StreamEvent, StreamOptions } from '../types';
import type { UpstreamTransport } from '../../ports';

/**
 * The real shape of the 400 OpenAI returns when it rejects summary for an unverified
 * organization: the word `summary` does not appear anywhere, so a pure capture-group
 * pattern can never extract the parameter name and the published fixed parameter name is
 * the only fallback.
 */
const ORG_UNVERIFIED_400 = JSON.stringify({
  error: {
    message: 'Your organization must be verified to generate reasoning summaries.',
    type: 'invalid_request_error',
    param: null,
    code: null,
  },
});

/** Fixed parameter name pattern published by admin. */
const FIXED_PARAM_PATTERN = [
  { pattern: 'must be verified to generate reasoning summaries', flags: 'i', param: 'reasoning.summary' },
];

const SSE_OK = 'event: response.output_text.delta\ndata: {"delta":"hi"}\n\ndata: [DONE]\n\n';

function sseResponse(): Response {
  return new Response(SSE_OK, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
}

/** An upstream that returns 400 once and 200 afterwards, recording each outbound body for assertions. */
function rejectSummaryOnce(bodies: Record<string, unknown>[]): UpstreamTransport {
  return {
    fetch: async (_url, init) => {
      bodies.push(JSON.parse(String(init.body)) as Record<string, unknown>);
      return bodies.length === 1
        ? new Response(ORG_UNVERIFIED_400, { status: 400 })
        : sseResponse();
    },
  };
}

function relayDeps(transport: UpstreamTransport): RelayOrchestratorDeps {
  return {
    transport,
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
}

async function drain(stream: ReadableStream<StreamEvent>): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  const reader = stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    events.push(value);
  }
  return events;
}

async function outboundBodies(
  options: StreamOptions,
  transport: UpstreamTransport,
  bodies: Record<string, unknown>[],
  baseURL = 'https://relay.example/v1',
): Promise<Record<string, unknown>[]> {
  const handle = sendRelayStream(
    'sk-test',
    'gpt-5.6-sol',
    [{ role: 'user', content: 'hello' }],
    baseURL,
    options,
    relayDeps(transport),
  );
  await drain(handle.stream);
  return bodies;
}

/**
 * Connection identity value object injected by the client (`StreamOptions.capabilityIdentity`).
 * core cannot read localStorage or the metadata ETag, so these six fields have to be
 * injected; the remaining four (providerKind / modelID / transport / endpointFingerprint)
 * are derived by the production orchestration from the real request, and the test does not
 * assemble the scope itself.
 */
const INJECTED_IDENTITY = {
  partitionId: 'uid-1',
  connectionInstanceId: 'relay-conn-1',
  connectionGeneration: 'gen-1',
  credentialEpoch: 'epoch-1',
  metadataRevision: 'W/"metadata-1"',
  generationRevision: 'W/"generation-1"',
} as const;

const RESPONSES_OPTIONS: StreamOptions = {
  relayTransport: 'openai_responses',
  relayAuthMode: 'bearer',
  reasoning: 'deep',
};

beforeEach(() => {
  resetUnsupportedParamCacheForTesting();
});

describe('relay Responses always sends reasoning.summary', () => {
  it('sends effort and summary together when a reasoning level is explicit', async () => {
    const bodies: Record<string, unknown>[] = [];
    await outboundBodies(
      { relayTransport: 'openai_responses', relayAuthMode: 'bearer', reasoning: 'deep' },
      { fetch: async (_url, init) => { bodies.push(JSON.parse(String(init.body))); return sseResponse(); } },
      bodies,
    );
    expect(bodies[0].reasoning).toEqual({ effort: 'high', summary: 'auto' });
  });

  it('automatic mode still sends summary and leaves effort to the model', async () => {
    const bodies: Record<string, unknown>[] = [];
    await outboundBodies(
      { relayTransport: 'openai_responses', relayAuthMode: 'bearer', reasoning: 'automatic' },
      { fetch: async (_url, init) => { bodies.push(JSON.parse(String(init.body))); return sseResponse(); } },
      bodies,
    );
    expect(bodies[0].reasoning).toEqual({ summary: 'auto' });
  });

  it('never injects reasoning.summary into non-Responses relay shapes', async () => {
    for (const transport of ['openai_chat_completions', 'anthropic_messages', 'gemini_generate_content'] as const) {
      const bodies: Record<string, unknown>[] = [];
      await outboundBodies(
        { relayTransport: transport, relayAuthMode: 'bearer', reasoning: 'deep' },
        { fetch: async (_url, init) => { bodies.push(JSON.parse(String(init.body))); return sseResponse(); } },
        bodies,
      );
      expect(JSON.stringify(bodies[0])).not.toContain('"summary"');
    }
  });
});

describe('a relay that rejects summary must not trigger a silent request rewrite', () => {
  it('fetchRelayRequest: returns the 400 unchanged and sends exactly once', async () => {
    setUnsupportedParamPatterns(FIXED_PARAM_PATTERN);
    const bodies: Record<string, unknown>[] = [];
    const response = await fetchRelayRequest(
      {
        url: 'https://relay.example/v1/responses',
        headers: {},
        body: { model: 'gpt-5.6-sol', stream: true, reasoning: { effort: 'high', summary: 'auto' } },
      },
      undefined,
      rejectSummaryOnce(bodies),
    );

    expect(response.status).toBe(400);
    expect(bodies).toHaveLength(1);
    expect(bodies[0].reasoning).toEqual({ effort: 'high', summary: 'auto' });
  });

  it('an existing connection identity does not pre-strip summary from the next message', async () => {
    setUnsupportedParamPatterns(FIXED_PARAM_PATTERN);
    const bodies: Record<string, unknown>[] = [];
    const transport = rejectSummaryOnce(bodies);
    const options: StreamOptions = { ...RESPONSES_OPTIONS, capabilityIdentity: INJECTED_IDENTITY };

    // The first message keeps the original 400; nothing is learned from the error body.
    await outboundBodies(options, transport, bodies);
    expect(bodies[0].reasoning).toEqual({ effort: 'high', summary: 'auto' });

    // The second message still carries the user setting; the test upstream then returns 200.
    await outboundBodies(options, transport, bodies);
    expect(bodies).toHaveLength(2);
    expect(bodies[1].reasoning).toEqual({ effort: 'high', summary: 'auto' });

    // A different relay was not affected and still sends summary by default.
    await outboundBodies(options, transport, bodies, 'https://other-relay.example/v1');
    expect(bodies[2].reasoning).toEqual({ effort: 'high', summary: 'auto' });
  });

  it('with no connection identity every message keeps its original fields and sends a single leg', async () => {
    setUnsupportedParamPatterns(FIXED_PARAM_PATTERN);
    const bodies: Record<string, unknown>[] = [];
    const transport = rejectSummaryOnce(bodies);

    await outboundBodies(RESPONSES_OPTIONS, transport, bodies);
    await outboundBodies(RESPONSES_OPTIONS, transport, bodies);

    expect(bodies).toHaveLength(2);
    expect(bodies[1].reasoning).toEqual({ effort: 'high', summary: 'auto' });
  });

  it('end to end: a rejected first Responses streaming request produces an error event', async () => {
    setUnsupportedParamPatterns(FIXED_PARAM_PATTERN);
    const bodies: Record<string, unknown>[] = [];
    const handle = sendRelayStream(
      'sk-test',
      'gpt-5.6-sol',
      [{ role: 'user', content: 'hello' }],
      'https://relay.example/v1',
      { relayTransport: 'openai_responses', relayAuthMode: 'bearer', reasoning: 'deep' },
      relayDeps(rejectSummaryOnce(bodies)),
    );
    const events = await drain(handle.stream);

    expect(bodies).toHaveLength(1);
    expect(bodies[0].reasoning).toEqual({ effort: 'high', summary: 'auto' });
    expect(events.some((event) => event.type === 'error')).toBe(true);
  });
});
