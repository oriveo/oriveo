// When the relay orchestrator maps an in-stream error frame to an error event it carries the raw error.type / code / status from the JSON,
// so failure telemetry can report upstream_error_type through the allowlist (JSON fields only, never scanned from body text).
import { describe, expect, it } from 'vitest';
import { sendRelayStream } from '../relay-orchestrator';
import type { StreamEvent } from '../types';
import type { RelayTransport } from '@oriveo/shared/pure-types';

const sse = (...frames: string[]) => new Response(frames.map((frame) => `${frame}\n\n`).join(''), {
  status: 200, headers: { 'Content-Type': 'text/event-stream' },
});

async function errorEventOf(relayTransport: RelayTransport, response: Response): Promise<StreamEvent | undefined> {
  const handle = sendRelayStream('relay-secret-key', 'model-a', [{ role: 'user', content: 'hi' }], 'https://relay.example', {
    reasoningMode: 'automatic', relayTransport, relayAuthMode: 'bearer', relayStream: true,
  } as never, {
    transport: { fetch: async () => response as never },
    buildFetchArgs: (url: string, headers: Record<string, string>) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  } as never);
  const reader = handle.stream.getReader();
  const events: StreamEvent[] = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    events.push(value);
  }
  return events.find((event) => event.type === 'error');
}

describe('upstreamErrorType of relay in-stream error frames', () => {
  it('Responses response.failed carries error.code', async () => {
    const event = await errorEventOf('openai_responses', sse(
      'event: response.failed\ndata: {"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"boom"}}}',
    ));
    expect(event).toMatchObject({ type: 'error', streamErrorFrame: true, upstreamErrorType: 'server_error' });
  });

  it('a Gemini in-stream error carries error.status (lowercase)', async () => {
    const event = await errorEventOf('gemini_generate_content', sse(
      'data: {"error":{"code":429,"message":"Resource has been exhausted","status":"RESOURCE_EXHAUSTED"}}',
    ));
    expect(event).toMatchObject({ type: 'error', streamErrorFrame: true, upstreamErrorType: 'resource_exhausted' });
  });

  it('is omitted when error is a plain string', async () => {
    const event = await errorEventOf('openai_responses', sse(
      'event: error\ndata: {"type":"error","error":"plain text failure"}',
    ));
    expect(event?.type).toBe('error');
    expect(event && 'upstreamErrorType' in event).toBe(false);
  });
});
