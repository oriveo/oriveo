import { describe, it, expect } from 'vitest';
import { parseSSELines, createSSEStream } from '../sse-parser';
import type { StreamEvent } from '../../core/providers/adapters/openrouter-types';

/* ── parseSSELines ─────────────────────────────────── */

describe('parseSSELines', () => {
  it('parses the standard data-only format', () => {
    const raw = 'data: {"text":"hello"}\n\ndata: {"text":"world"}\n\n';
    const entries = parseSSELines(raw);
    expect(entries).toEqual([
      { event: null, data: '{"text":"hello"}' },
      { event: null, data: '{"text":"world"}' },
    ]);
  });

  it('parses the Anthropic format with an event type', () => {
    const raw = [
      'event: message_start',
      'data: {"type":"message_start"}',
      '',
      'event: content_block_delta',
      'data: {"type":"content_block_delta","delta":{"text":"hi"}}',
      '',
    ].join('\n');
    const entries = parseSSELines(raw);
    expect(entries).toEqual([
      { event: 'message_start', data: '{"type":"message_start"}' },
      { event: 'content_block_delta', data: '{"type":"content_block_delta","delta":{"text":"hi"}}' },
    ]);
  });

  it('skips SSE comments, which start with :', () => {
    const raw = ': this is a comment\ndata: {"ok":true}\n\n';
    const entries = parseSSELines(raw);
    expect(entries).toEqual([{ event: null, data: '{"ok":true}' }]);
  });

  it('skips lines that are neither data nor event', () => {
    const raw = 'id: 123\nretry: 5000\ndata: {"ok":true}\n\n';
    const entries = parseSSELines(raw);
    expect(entries).toEqual([{ event: null, data: '{"ok":true}' }]);
  });

  it('resets the event type on a blank line', () => {
    const raw = [
      'event: message_start',
      'data: {"type":"message_start"}',
      '',
      'data: {"type":"no_event"}',
      '',
    ].join('\n');
    const entries = parseSSELines(raw);
    expect(entries[0].event).toBe('message_start');
    expect(entries[1].event).toBeNull();
  });

  it('returns an empty array for an empty string', () => {
    expect(parseSSELines('')).toEqual([]);
  });

  it('treats the [DONE] token as ordinary data', () => {
    const raw = 'data: [DONE]\n\n';
    const entries = parseSSELines(raw);
    expect(entries).toEqual([{ event: null, data: '[DONE]' }]);
  });
});

/* ── createSSEStream ───────────────────────────────── */

/** Build a mock SSE Response. */
function mockSSEResponse(chunks: string[], ok = true, status = 200): Response {
  const encoder = new TextEncoder();
  let chunkIndex = 0;

  const body = new ReadableStream<Uint8Array>({
    pull(ctrl) {
      if (chunkIndex < chunks.length) {
        ctrl.enqueue(encoder.encode(chunks[chunkIndex]));
        chunkIndex++;
      } else {
        ctrl.close();
      }
    },
  });

  return {
    ok,
    status,
    body,
    text: async () => 'error body',
    headers: new Headers(),
  } as unknown as Response;
}

/** Read every StreamEvent from the stream. */
async function collectEvents(stream: ReadableStream<StreamEvent>): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  const reader = stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    events.push(value);
  }
  return events;
}

describe('createSSEStream', () => {
  it('parses OpenAI-style SSE and converts it through parseChunk', async () => {
    const res = mockSSEResponse([
      'data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n',
      'data: {"choices":[{"delta":{"content":" World"}}]}\n\n',
      'data: [DONE]\n\n',
    ]);

    const parseChunk = (_event: string | null, data: string): StreamEvent | null => {
      const chunk = JSON.parse(data);
      const content = chunk.choices?.[0]?.delta?.content;
      if (content) return { type: 'delta', content };
      return null;
    };

    const events = await collectEvents(createSSEStream(res, parseChunk));
    expect(events).toEqual([
      { type: 'delta', content: 'Hello' },
      { type: 'delta', content: ' World' },
      { type: 'done' },
    ]);
  });

  it('handles Anthropic-style SSE with an event type', async () => {
    const res = mockSSEResponse([
      'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":10}}}\n\n',
      'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}\n\n',
      'event: message_stop\ndata: {"type":"message_stop"}\n\n',
    ]);

    const parseChunk = (eventType: string | null, data: string): StreamEvent | null => {
      const event = JSON.parse(data);
      switch (eventType ?? event.type) {
        case 'content_block_delta':
          return { type: 'delta', content: event.delta.text };
        case 'message_stop':
          return { type: 'done' };
        default:
          return null;
      }
    };

    const events = await collectEvents(createSSEStream(res, parseChunk, { doneToken: undefined }));
    // message_stop returns done, and the end of the stream enqueues another done.
    expect(events[0]).toEqual({ type: 'delta', content: 'Hi' });
    expect(events[1]).toEqual({ type: 'done' });
  });

  it('turns a non-ok response into an error event', async () => {
    const res = {
      ok: false,
      status: 502,
      body: null,
      text: async () => JSON.stringify({
        error: 'connect ETIMEDOUT [upstream: https://relay.example.com/v1/chat/completions]',
      }),
      headers: new Headers(),
    } as unknown as Response;
    const events = await collectEvents(createSSEStream(res, () => null));
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe('error');
    if (events[0].type === 'error') {
      expect(events[0].errorKind).toBe('upstream');
      expect(events[0].errorDetail).toBe('connect ETIMEDOUT [upstream: https://relay.example.com/v1/chat/completions]');
    }
  });

  it('reports a non-SyntaxError thrown by parseChunk as errorKind=upstream rather than swallowing it as network noise', async () => {
    const res = mockSSEResponse(['data: {"valid":"json"}\n\n']);
    const parseChunk = (): StreamEvent | null => {
      // Stand in for a real bug such as a missing-field NPE or a failed type assertion, which is not a SyntaxError.
      throw new TypeError("Cannot read properties of undefined (reading 'x')");
    };
    const events = await collectEvents(createSSEStream(res, parseChunk));
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe('error');
    if (events[0].type === 'error') {
      expect(events[0].errorKind).toBe('upstream');
    }
  });

  it('maps a connection reset mid-read to errorKind=network to keep the noise down', async () => {
    const body = new ReadableStream<Uint8Array>({
      start(ctrl) {
        // controller.error() makes reader.read() reject, standing in for a reset connection.
        ctrl.error(new TypeError('network error'));
      },
    });
    const res = { ok: true, status: 200, body, text: async () => '', headers: new Headers() } as unknown as Response;
    const events = await collectEvents(createSSEStream(res, () => null));
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe('error');
    if (events[0].type === 'error') {
      expect(events[0].errorKind).toBe('network');
    }
  });

  it('maps a Free 401 session error to unauthorized rather than invalidKey', async () => {
    const res = {
      ok: false,
      status: 401,
      body: null,
      text: async () => 'Free session expired. Please retry to refresh your access.',
      headers: new Headers(),
    } as unknown as Response;

    const events = await collectEvents(createSSEStream(res, () => null));

    expect(events).toHaveLength(1);
    expect(events[0].type).toBe('error');
    if (events[0].type === 'error') {
      expect(events[0].errorKind).toBe('unauthorized');
      expect(events[0].errorKind).not.toBe('invalidKey');
    }
  });

  it('maps an exhausted Free quota to quotaExceeded', async () => {
    const res = {
      ok: false,
      status: 403,
      body: null,
      text: async () => 'Daily free quota exhausted. Please wait for the UTC reset.',
      headers: new Headers(),
    } as unknown as Response;

    const events = await collectEvents(createSSEStream(res, () => null));

    expect(events).toHaveLength(1);
    expect(events[0].type).toBe('error');
    if (events[0].type === 'error') {
      expect(events[0].errorKind).toBe('quotaExceeded');
    }
  });

  it('maps an English model-unavailable body to unavailable', async () => {
    const res = {
      ok: false,
      status: 503,
      body: null,
      text: async () => 'Current free model is temporarily unavailable.',
      headers: new Headers(),
    } as unknown as Response;

    const events = await collectEvents(createSSEStream(res, () => null));

    expect(events).toHaveLength(1);
    expect(events[0].type).toBe('error');
    if (events[0].type === 'error') {
      expect(events[0].errorKind).toBe('unavailable');
    }
  });

  it('produces the original text and the provider responsibility boundary from a real Moonshot 429 response', async () => {
    const res = {
      ok: false,
      status: 429,
      url: 'https://api.moonshot.cn/v1/chat/completions',
      body: null,
      text: async () => JSON.stringify({
        error: {
          type: 'engine_overloaded_error',
          message: 'The engine is currently overloaded, please try again later',
        },
      }),
      headers: new Headers(),
    } as unknown as Response;

    const events = await collectEvents(createSSEStream(res, () => null));

    expect(events).toEqual([expect.objectContaining({
      type: 'error',
      error: 'engine_overloaded_error | The engine is currently overloaded, please try again later',
      errorDetail: 'engine_overloaded_error | The engine is currently overloaded, please try again later',
      errorKind: 'rateLimited',
      source: 'provider',
      status: 429,
      upstreamURL: 'https://api.moonshot.cn/v1/chat/completions',
    })]);
  });

  it('handles a response with no body', async () => {
    const res = {
      ok: true,
      status: 200,
      body: null,
      headers: new Headers(),
    } as unknown as Response;

    const events = await collectEvents(createSSEStream(res, () => null));
    expect(events).toHaveLength(1);
    expect(events[0].type).toBe('error');
    if (events[0].type === 'error') {
      expect(events[0].errorKind).toBe('emptyResponse');
    }
  });

  it('skips a chunk that makes parseChunk throw', async () => {
    const res = mockSSEResponse([
      'data: invalid-json\n\n',
      'data: {"ok":true}\n\n',
      'data: [DONE]\n\n',
    ]);

    const parseChunk = (_event: string | null, data: string): StreamEvent | null => {
      const parsed = JSON.parse(data); // invalid-json throws here
      if (parsed.ok) return { type: 'delta', content: 'ok' };
      return null;
    };

    const events = await collectEvents(createSSEStream(res, parseChunk));
    expect(events).toEqual([
      { type: 'delta', content: 'ok' },
      { type: 'done' },
    ]);
  });

  it('handles an SSE line split across two chunks through the buffer', async () => {
    // One line of data split across two chunks.
    const res = mockSSEResponse([
      'data: {"content":"hel',
      'lo"}\n\ndata: [DONE]\n\n',
    ]);

    const parseChunk = (_event: string | null, data: string): StreamEvent | null => {
      const parsed = JSON.parse(data);
      return { type: 'delta', content: parsed.content };
    };

    const events = await collectEvents(createSSEStream(res, parseChunk));
    expect(events).toEqual([
      { type: 'delta', content: 'hello' },
      { type: 'done' },
    ]);
  });

  it('keeps the event type when the event line and the data line land in different chunks', async () => {
    const res = mockSSEResponse([
      'event: response.image_generation_call.partial_image\n',
      'data: {"type":"response.image_generation_call.partial_image","partial_image_b64":"abc"}\n\n',
      'data: [DONE]\n\n',
    ]);

    const parseChunk = (eventType: string | null, data: string): StreamEvent | null => {
      const parsed = JSON.parse(data);
      if (parsed.type === 'response.image_generation_call.partial_image') {
        return { type: 'delta', content: eventType ?? 'missing' };
      }
      return null;
    };

    const events = await collectEvents(createSSEStream(res, parseChunk));
    expect(events).toEqual([
      { type: 'delta', content: 'response.image_generation_call.partial_image' },
      { type: 'done' },
    ]);
  });

  it('honours a custom doneToken', async () => {
    const res = mockSSEResponse([
      'data: {"text":"hi"}\n\n',
      'data: END_STREAM\n\n',
    ]);

    const parseChunk = (_event: string | null, data: string): StreamEvent | null => {
      const parsed = JSON.parse(data);
      return { type: 'delta', content: parsed.text };
    };

    const events = await collectEvents(
      createSSEStream(res, parseChunk, { doneToken: 'END_STREAM' }),
    );
    expect(events).toEqual([
      { type: 'delta', content: 'hi' },
      { type: 'done' },
    ]);
  });

  it('ends cleanly on a stream with no doneToken, such as Gemini', async () => {
    const res = mockSSEResponse([
      'data: {"text":"hello"}\n\n',
    ]);

    const parseChunk = (_event: string | null, data: string): StreamEvent | null => {
      const parsed = JSON.parse(data);
      return { type: 'delta', content: parsed.text };
    };

    const events = await collectEvents(createSSEStream(res, parseChunk));
    expect(events).toEqual([
      { type: 'delta', content: 'hello' },
      { type: 'done' },
    ]);
  });

  it('emits only an error event on a read failure, with no trailing done', async () => {
    // A body that throws while being read.
    const body = new ReadableStream<Uint8Array>({
      start(ctrl) {
        ctrl.enqueue(new TextEncoder().encode('data: {"text":"hi"}\n\n'));
      },
      pull() {
        throw new Error('Connection lost');
      },
    });

    const res = {
      ok: true,
      status: 200,
      body,
      headers: new Headers(),
    } as unknown as Response;

    const events = await collectEvents(createSSEStream(res, (_event, data) => {
      const parsed = JSON.parse(data);
      return { type: 'delta', content: parsed.text };
    }));

    expect(events).toHaveLength(2);
    expect(events[0]).toEqual({ type: 'delta', content: 'hi' });
    expect(events[1].type).toBe('error');
    // Confirm no done event was appended.
    expect(events.filter((e) => e.type === 'done')).toHaveLength(0);
  });
});
