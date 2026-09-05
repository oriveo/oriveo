import { describe, expect, it, vi } from 'vitest';
import type { ChatMessage } from '@oriveo/shared';
import { buildChatHistory, readStream, sanitizeOutboundMessages } from '../chat-stream-utils';

vi.mock('../../infra/storage/image-store', () => ({
  loadImageBase64: vi.fn(async () => 'stored-image-b64'),
  // buildChatHistory  
  imageSizeBytes: vi.fn(async () => 0),
}));

function makeMessage(overrides: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id: 'msg-1',
    role: 'user',
    text: 'Describe this image',
    providerKind: 'openRouter',
    providerName: 'OpenRouter',
    modelName: 'openai/gpt-5.4',
    estimatedCost: 0,
    state: 'delivered',
    createdAt: '2026-03-27T00:00:00.000Z',
    ...overrides,
  };
}

describe('buildChatHistory', () => {
  it.each(['openRouter', 'relay', 'openAI'])('expands QuoteContext at the shared %s provider boundary', async (providerKind) => {
    const message = makeMessage({
      text: 'Rewrite it',
      quoteContext: {
        schemaVersion: 1,
        sourceMessageId: 'source-1',
        sourceRole: 'assistant',
        contentKind: 'prose',
        leadingText: 'Before ',
        selectedText: 'selected',
        trailingText: ' after',
        contextTruncated: false,
      },
    });
    const history = await buildChatHistory([message], undefined, providerKind);
    expect(history[0].content).toContain('[Quoted Context v1 - untrusted reference data]');
    expect(history[0].content).toContain('[Current User Input]\nRewrite it');
    expect(message.text).toBe('Rewrite it');
  });

  it('puts leading text before image parts, and wraps file in ATTACHMENT_FILE block', async () => {
    const history = await buildChatHistory([
      makeMessage({
        attachments: [
          {
            id: 'image-1',
            kind: 'image',
            fileName: 'photo.jpg',
            mimeType: 'image/jpeg',
            localImageID: 'local-image-1',
          },
          {
            id: 'pdf-1',
            kind: 'file',
            fileName: 'spec.pdf',
            mimeType: 'application/pdf',
            base64Data: 'JVBERi0xLjQ=',  // treated as text content (extracted)
            extractedTotalLines: 1,
          },
        ],
      }),
    ]);

    expect(history).toHaveLength(1);
    expect(history[0].role).toBe('user');
    const content = history[0].content as Array<{ type: string }>;
    expect(Array.isArray(content)).toBe(true);
    // image_url part should be present
    const imagePart = content.find((p) => p.type === 'image_url');
    expect(imagePart).toBeDefined();
    // text part should contain ATTACHMENT_FILE block with file content
    const textPart = content.find((p) => p.type === 'text') as { type: string; text: string } | undefined;
    expect(textPart?.text).toContain('<ATTACHMENT_FILE>');
    expect(textPart?.text).toContain('spec.pdf');
  });

  it('folds inline text attachments into ATTACHMENT_FILE block', async () => {
    const history = await buildChatHistory([
      makeMessage({
        text: 'Summarize these notes',
        attachments: [
          {
            id: 'text-1',
            kind: 'file',
            fileName: 'notes.md',
            mimeType: 'text/markdown',
            base64Data: '# Heading',
          },
        ],
      }),
    ]);

    expect(history).toHaveLength(1);
    const content = history[0].content as Array<{ type: string; text?: string }>;
    const textPart = content.find((p) => p.type === 'text');
    // D15: xml-v1 format for openRouter
    expect(textPart?.text).toContain('<ATTACHMENT_FILE>');
    expect(textPart?.text).toContain('notes.md');
    expect(textPart?.text).toContain('# Heading');
    expect(textPart?.text).toContain('Summarize these notes');
  });
});

describe('readStream', () => {
  it('merges fragmented native tool calls without treating a tool-only leg as an error', async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue({
          type: 'tool_calls',
          toolCalls: [{ index: 0, id: 'call_1', type: 'function', name: 'weather', arguments: ' {"city"' }],
        });
        controller.enqueue({
          type: 'tool_calls',
          toolCalls: [{ index: 0, id: '', name: '', arguments: ':"Melbourne"}' }],
        });
        controller.enqueue({ type: 'done' });
        controller.close();
      },
    });

    const result = await readStream(stream, '', vi.fn());

    expect(result.fullText).toBe('');
    expect(result.toolCalls).toEqual([
      { id: 'call_1', name: 'weather', arguments: ' {"city":"Melbourne"}' },
    ]);
  });

  it('advances Managed delivered sequence for reasoning and text events', async () => {
    const onManagedSequence = vi.fn();
    const onReasoningChunk = vi.fn();
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue({ type: 'reasoning', content: 'thinking', managedSequence: 1 });
        controller.enqueue({ type: 'delta', content: 'answer', managedSequence: 2 });
        controller.close();
      },
    });

    const result = await readStream(stream, '', vi.fn(), undefined, onReasoningChunk, onManagedSequence);

    expect(result.reasoningText).toBe('thinking');
    expect(result.fullText).toBe('answer');
    expect(onReasoningChunk).toHaveBeenCalledWith('thinking');
    expect(onManagedSequence.mock.calls.map(([sequence]) => sequence)).toEqual([1, 2]);
  });

  it('preserves provider error detail from stream error events', async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue({
          type: 'error',
          error: 'The AI provider is experiencing issues. Please try again later.',
          errorDetail: 'connect ETIMEDOUT [upstream: https://relay.example.com/v1/chat/completions]',
          errorKind: 'upstream',
          source: 'provider',
        });
        controller.close();
      },
    });

    await expect(readStream(stream, '', vi.fn())).rejects.toMatchObject({
      kind: 'upstream',
      message: 'The AI provider is experiencing issues. Please try again later.',
      detail: 'connect ETIMEDOUT [upstream: https://relay.example.com/v1/chat/completions]',
      source: 'provider',
    });
  });

  it('preserves Managed error code and primary action from stream error events', async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue({
          type: 'error',
          error: 'AI balance is not enough.',
          errorDetail: 'AI balance is not enough.',
          errorKind: 'quotaExceeded',
          retryable: false,
          source: 'oriveo',
          managedErrorCode: 'INSUFFICIENT_BALANCE',
          managedErrorAction: 'recharge',
          traceId: 'trc_1',
        });
        controller.close();
      },
    });

    await expect(readStream(stream, '', vi.fn())).rejects.toMatchObject({
      kind: 'quotaExceeded',
      message: 'AI balance is not enough.',
      detail: 'AI balance is not enough.',
      retryable: false,
      source: 'oriveo',
      managedErrorCode: 'INSUFFICIENT_BALANCE',
      managedErrorAction: 'recharge',
      traceId: 'trc_1',
    });
  });

  it('reports latest citations before an upstream stream error is thrown', async () => {
    const onCitations = vi.fn();
    const citations = [{ url: 'https://source.example/a', title: 'Source A' }];
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue({ type: 'citations', citations });
        controller.enqueue({
          type: 'error',
          error: 'upstream failed',
          errorKind: 'upstream',
        });
        controller.close();
      },
    });

    await expect(readStream(stream, '', vi.fn(), onCitations)).rejects.toMatchObject({
      kind: 'upstream',
      message: 'upstream failed',
    });
    expect(onCitations).toHaveBeenCalledWith(citations);
  });
});

describe('sanitizeOutboundMessages ', () => {
  it('drops an empty failed assistant even when it carries keepId, the root cause of the retry bug', () => {
    const result = sanitizeOutboundMessages(
      [
        makeMessage({ id: 'u1', role: 'user', text: 'hi', state: 'delivered' }),
        makeMessage({ id: 'a1', role: 'assistant', text: '', state: 'failed' }),
      ],
      'a1',
    );
    expect(result.map((m) => m.id)).toEqual(['u1']);
  });

  it('leaves a healthy conversation exactly as it is', () => {
    const msgs = [
      makeMessage({ id: 'u1', role: 'user', text: 'hi', state: 'delivered' }),
      makeMessage({ id: 'a1', role: 'assistant', text: 'hello', state: 'delivered' }),
      makeMessage({ id: 'u2', role: 'user', text: 'more', state: 'delivered' }),
    ];
    expect(sanitizeOutboundMessages(msgs).map((m) => m.id)).toEqual(['u1', 'a1', 'u2']);
  });

  it('after dropping an empty failed assistant in the middle, keeps only the newest user message so two questions are not merged into one prompt', () => {
    const result = sanitizeOutboundMessages([
      makeMessage({ id: 'u1', role: 'user', text: 'q1', state: 'delivered' }),
      makeMessage({ id: 'a1', role: 'assistant', text: '', state: 'failed' }),
      makeMessage({ id: 'u2', role: 'user', text: 'q2', state: 'delivered' }),
    ]);
    // With the empty a1 gone, u1 and u2 are adjacent; the answer to u1 failed or was abandoned, so only the newest u2 is kept, which stays strictly alternating without merging the two questions.
    expect(result.map((m) => m.id)).toEqual(['u2']);
    expect(result[0].text).toBe('q2');
  });

  it('retrying a failed message drops the intervening empty failed assistant and keeps only the newest user message, staying strictly alternating', () => {
    // A conversation that accumulated failed turns: u1 -> a1(delivered) -> u2 -> a2(failed, empty) -> u3.
    // Dropping a2 leaves u2 and u3 adjacent, so the older u2 goes and only u3 remains.
    const result = sanitizeOutboundMessages([
      makeMessage({ id: 'u1', role: 'user', text: 'q1', state: 'delivered' }),
      makeMessage({ id: 'a1', role: 'assistant', text: 'a1', state: 'delivered' }),
      makeMessage({ id: 'u2', role: 'user', text: 'q2', state: 'delivered' }),
      makeMessage({ id: 'a2', role: 'assistant', text: '', state: 'failed' }),
      makeMessage({ id: 'u3', role: 'user', text: 'q3', state: 'delivered' }),
    ]);
    expect(result.map((m) => m.role)).toEqual(['user', 'assistant', 'user']);
    expect(result.map((m) => m.text)).toEqual(['q1', 'a1', 'q3']);
    expect(result.map((m) => m.id)).toEqual(['u1', 'a1', 'u3']);
  });

  it('keeps the newest user message with its own attachments when discarding the older one', () => {
    const result = sanitizeOutboundMessages([
      makeMessage({
        id: 'u1', role: 'user', text: 'q1', state: 'delivered',
        attachments: [{ id: 'att1', kind: 'image', fileName: 'a.jpg', mimeType: 'image/jpeg', base64Data: 'b1' }],
      }),
      makeMessage({ id: 'a1', role: 'assistant', text: '', state: 'failed' }),
      makeMessage({
        id: 'u2', role: 'user', text: 'q2', state: 'delivered',
        attachments: [{ id: 'att2', kind: 'image', fileName: 'b.jpg', mimeType: 'image/jpeg', base64Data: 'b2' }],
      }),
    ]);
    expect(result).toHaveLength(1);
    expect(result[0].id).toBe('u2');
    expect(result[0].text).toBe('q2');
    expect(result[0].attachments?.map((a) => a.id)).toEqual(['att2']);
  });

  it('keeps an interrupted assistant that has partial text as context separating two user messages, and preserves the continuation target through keepId', () => {
    const msgs = [
      makeMessage({ id: 'u1', role: 'user', text: 'hi', state: 'delivered' }),
      makeMessage({ id: 'a-old', role: 'assistant', text: 'orphan', state: 'interrupted' }),
      makeMessage({ id: 'u2', role: 'user', text: 'q2', state: 'delivered' }),
      makeMessage({ id: 'a1', role: 'assistant', text: 'partial', state: 'generating' }),
    ];
    const result = sanitizeOutboundMessages(msgs, 'a1');
    // a-old has partial text (state is not failed) so it is kept and naturally separates u1 and u2; a1 (keepId, generating) is kept too, giving strict alternation.
    expect(result.map((m) => m.role)).toEqual(['user', 'assistant', 'user', 'assistant']);
    expect(result.map((m) => m.id)).toEqual(['u1', 'a-old', 'u2', 'a1']);
  });

  it('does not touch a healthy conversation that already alternates strictly', () => {
    const msgs = [
      makeMessage({ id: 'u1', role: 'user', text: 'hi', state: 'delivered' }),
      makeMessage({ id: 'a1', role: 'assistant', text: 'hello', state: 'delivered' }),
      makeMessage({ id: 'u2', role: 'user', text: 'more', state: 'delivered' }),
    ];
    expect(sanitizeOutboundMessages(msgs).map((m) => m.id)).toEqual(['u1', 'a1', 'u2']);
  });

  it('strips image attachments from assistant messages while keeping their text, the root cause of an upstream 400 when a generated image reached a text-only model', () => {
    const result = sanitizeOutboundMessages([
      makeMessage({ id: 'u1', role: 'user', text: 'draw me a farmer', state: 'delivered' }),
      makeMessage({
        id: 'a1', role: 'assistant', text: 'here is the image I generated for you', state: 'delivered',
        attachments: [{ id: 'gen1', kind: 'image', fileName: 'generated.png', mimeType: 'image/png', base64Data: 'b64gen' }],
      }),
      makeMessage({ id: 'u2', role: 'user', text: 'nice one', state: 'delivered' }),
    ]);
    expect(result.map((m) => m.id)).toEqual(['u1', 'a1', 'u2']);
    // The assistant keeps its text, only the generated image is stripped.
    expect(result[1].text).toBe('here is the image I generated for you');
    expect(result[1].attachments).toBeUndefined();
  });

  it('drops an image-only assistant message that has no text left after stripping, and keeps only the newest user message', () => {
    const result = sanitizeOutboundMessages([
      makeMessage({ id: 'u1', role: 'user', text: 'draw me a farmer', state: 'delivered' }),
      makeMessage({
        id: 'a1', role: 'assistant', text: '', state: 'delivered',
        attachments: [{ id: 'gen1', kind: 'image', fileName: 'generated.png', mimeType: 'image/png', base64Data: 'b64gen' }],
      }),
      makeMessage({ id: 'u2', role: 'user', text: 'nice one', state: 'delivered' }),
    ]);
    // An image-only assistant becomes empty once images are stripped, so it is dropped; u1 and u2 are then adjacent and only the newest u2 is kept.
    expect(result.map((m) => m.role)).toEqual(['user']);
    expect(result[0].text).toBe('nice one');
  });

  it('does not strip image attachments the user uploaded; only assistant messages are touched', () => {
    const result = sanitizeOutboundMessages([
      makeMessage({
        id: 'u1', role: 'user', text: 'what is this', state: 'delivered',
        attachments: [{ id: 'up1', kind: 'image', fileName: 'photo.jpg', mimeType: 'image/jpeg', base64Data: 'b64up' }],
      }),
    ]);
    expect(result[0].attachments?.map((a) => a.id)).toEqual(['up1']);
  });

  it('sending a new question after stopping drops the empty interrupted assistant and the old question, sending only the new one', () => {
    // Reproduces and pins a production bug: send A, stop (leaving an empty interrupted assistant), send B. The old behavior merged A and B into one message for the model to answer together; now only B is sent.
    const result = sanitizeOutboundMessages([
      makeMessage({ id: 'uA', role: 'user', text: 'what is that micro frontend framework called', state: 'delivered' }),
      makeMessage({ id: 'aA', role: 'assistant', text: '', state: 'interrupted' }),
      makeMessage({ id: 'uB', role: 'user', text: 'who founded that video studio', state: 'delivered' }),
    ]);
    expect(result.map((m) => m.id)).toEqual(['uB']);
    expect(result[0].text).toBe('who founded that video studio');
  });

  it('sending a new question after stopping keeps an interrupted assistant with partial text between the two user messages, so the model answers only the new question', () => {
    const result = sanitizeOutboundMessages([
      makeMessage({ id: 'uA', role: 'user', text: 'what is that micro frontend framework called', state: 'delivered' }),
      makeMessage({ id: 'aA', role: 'assistant', text: 'you probably mean micro-app', state: 'interrupted' }),
      makeMessage({ id: 'uB', role: 'user', text: 'who founded that video studio', state: 'delivered' }),
    ]);
    expect(result.map((m) => m.role)).toEqual(['user', 'assistant', 'user']);
    expect(result.map((m) => m.id)).toEqual(['uA', 'aA', 'uB']);
  });

  it('keeps failed turns out of the payload, including failed messages holding error copy and no keepId', () => {
    // A failed turn must not act as assistant context, or the error copy becomes a fake answer that is resent every turn. Anything with state == failed is dropped.
    const result = sanitizeOutboundMessages([
      makeMessage({ id: 'u1', role: 'user', text: 'q1', state: 'delivered' }),
      makeMessage({ id: 'a1', role: 'assistant', text: 'Request failed: invalid key', state: 'failed' }),
      makeMessage({ id: 'u2', role: 'user', text: 'q2', state: 'delivered' }),
    ]);
    expect(result.map((m) => m.id)).toEqual(['u2']);
    expect(result[0].text).toBe('q2');
  });

  it('merges the text of adjacent assistant messages from a malformed history to restore alternation', () => {
    // Defensive: the normal path never produces adjacent assistant messages, but a malformed history is merged on text and attachments.
    const result = sanitizeOutboundMessages([
      makeMessage({ id: 'u1', role: 'user', text: 'q1', state: 'delivered' }),
      makeMessage({ id: 'a1', role: 'assistant', text: 'part1', state: 'delivered' }),
      makeMessage({ id: 'a2', role: 'assistant', text: 'part2', state: 'delivered' }),
    ]);
    expect(result.map((m) => m.role)).toEqual(['user', 'assistant']);
    expect(result[1].text).toBe('part1\n\npart2');
  });
});

describe('sanitizeOutboundMessages + buildChatHistory end to end: generated assistant images stay out of the payload', () => {
  it('buildChatHistory produces no image_url content part for an assistant message after sanitizing', async () => {
    const sanitized = sanitizeOutboundMessages([
      makeMessage({ id: 'u1', role: 'user', text: 'draw me a farmer', state: 'delivered' }),
      makeMessage({
        id: 'a1', role: 'assistant', text: 'here is the image I generated for you', state: 'delivered',
        attachments: [{ id: 'gen1', kind: 'image', fileName: 'generated.png', mimeType: 'image/png', base64Data: 'b64gen' }],
      }),
      makeMessage({ id: 'u2', role: 'user', text: 'nice one', state: 'delivered' }),
    ]);
    const history = await buildChatHistory(sanitized);
    const assistantTurn = history.find((h) => h.role === 'assistant');
    // Assistant content must be a plain string and never contain an image_url part.
    expect(typeof assistantTurn?.content).toBe('string');
    const serialized = JSON.stringify(history);
    expect(serialized).not.toContain('image_url');
  });
});

describe('buildChatHistory outbound attachment budget window (production path)', () => {
  it('replaces an over-budget historical video with a placeholder line while keeping this turn attachments intact', async () => {
    // The assertions come from the payload buildChatHistory actually produces, not a hand-built
    // trimmed result. Video payloads are fully inlined on the attachment and never touch
    // ImageStore, so this case measures the budget window itself.
    const oversized = 'A'.repeat(10 * 1024 * 1024 + 1); // Just over the 10MiB budget.
    const history = await buildChatHistory([
      makeMessage({
        id: 'u1', role: 'user', text: 'take a look at this clip', state: 'delivered',
        attachments: [{ id: 'v1', kind: 'video', fileName: 'clip.mp4', mimeType: 'video/mp4', base64Data: oversized }],
      }),
      makeMessage({ id: 'a1', role: 'assistant', text: 'sure', state: 'delivered' }),
      makeMessage({
        id: 'u2', role: 'user', text: 'what about this one', state: 'delivered',
        attachments: [{ id: 'v2', kind: 'video', fileName: 'now.mp4', mimeType: 'video/mp4', base64Data: 'tiny' }],
      }),
    ]);

    // The oldest video is over budget, so it degrades to a placeholder line under its text.
    expect(history[0].content).toBe(
      'take a look at this clip\n\n[Video omitted: clip.mp4 (older attachment dropped to keep this request small)]',
    );
    // The attachment sent in this turn is inlined as usual.
    expect(history[2].content).toEqual([
      { type: 'text', text: 'what about this one' },
      { type: 'video_url', video_url: { url: 'data:video/mp4;base64,tiny' } },
    ]);
  });
});
