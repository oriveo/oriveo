import { describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, ChatMessage } from '@oriveo/shared';
import { buildChatHistory, readStream } from '../chat-stream-utils';
import { AttachmentOverLimitError, findUnsendableTextAttachments } from '../../core/attachments/attachment-delivery';

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
  it.each(['openrouter_chat', 'relay_openai_chat', 'openai_chat'] as const)('expands QuoteContext at the shared %s provider boundary', async (transport) => {
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
    const history = await buildChatHistory([message], undefined, { transport });
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

describe('buildChatHistory text attachments (production path)', () => {
  const textAttachment = (fileName: string, bytes: number, extra: Partial<Attachment> = {}): Attachment => ({
    id: fileName,
    kind: 'file',
    fileName,
    mimeType: 'text/plain',
    base64Data: 'x'.repeat(bytes),
    ...extra,
  });
  const outboundText = (history: Awaited<ReturnType<typeof buildChatHistory>>): string => {
    const content = history[history.length - 1]!.content;
    if (typeof content === 'string') return content;
    return content.flatMap((part) => (part.type === 'text' ? [part.text] : [])).join('\n');
  };

  // A persisted attachment stores extractedTruncated but not the truncation reason. The injector used to look
  // only at the reason, so every truncated file was sent without any truncation note.
  it('a truncated attachment is sent with the TRUNCATED marker', async () => {
    const content = Array.from({ length: 500 }, (_, i) => `L${i + 1}`).join('\n');
    const history = await buildChatHistory([makeMessage({
      text: 'Summarize',
      attachments: [{
        id: 'a', kind: 'file', fileName: 'long.txt', mimeType: 'text/plain',
        base64Data: content, extractedTruncated: true, extractedTotalLines: 1200, extractedSizeBytes: 9000,
      }],
    })], null, { transport: 'openai_responses' });

    expect(outboundText(history)).toContain('<TRUNCATED>showing first 500 of 1200 lines</TRUNCATED>');
  });

  const tightModel = {
    id: 'm', name: 'M', capabilities: ['text'], reasoningModeAvailable: false,
    isAvailable: true, isDefault: true, priceTier: '$',
    attachmentExtraction: { totalCap: 100 * 1024 },
  } as unknown as AIModel;
  const overBudget = () => [
    textAttachment('a.txt', 60 * 1024),
    textAttachment('b.txt', 60 * 1024),
    textAttachment('c.txt', 10 * 1024),
  ];

  it('the current turn has attachments that do not fit: the build fails, reporting exactly what the pre-send check reports', async () => {
    const attachments = overBudget();
    const line = { transport: 'openai_responses' } as const;
    const failure = await buildChatHistory([makeMessage({ text: 'Compare', attachments })], tightModel, line)
      .then(() => undefined, (error: unknown) => error);

    expect(failure).toBeInstanceOf(AttachmentOverLimitError);
    const error = failure as AttachmentOverLimitError;
    expect(error.skipped).toEqual(findUnsendableTextAttachments(attachments, tightModel, line));
    expect(error.skipped.map((item) => item.fileName)).toEqual(['b.txt']);
    // Stable code; the message carries no file names (file names stay out of telemetry and error reports)
    expect(error.kind).toBe('attachment_text_over_limit');
    expect(error.message).toBe('attachment_text_over_limit');
    expect(error.skipReport).toBe(true);
  });

  it('exceeding the count uses a different stable code', async () => {
    const attachments = [1, 2, 3, 4].map((n) => textAttachment(`f${n}.txt`, 1024));
    const failure = await buildChatHistory([makeMessage({ text: 'x', attachments })], undefined, { transport: 'openai_chat' })
      .then(() => undefined, (error: unknown) => error);
    expect((failure as AttachmentOverLimitError).kind).toBe('attachment_count_over_limit');
  });

  it('attachments that do not fit in older history are not blocked (how that turn was sent is already settled)', async () => {
    const history = await buildChatHistory([
      makeMessage({ id: 'old', text: 'Compare', attachments: overBudget() }),
      makeMessage({ id: 'reply', role: 'assistant', text: 'done' }),
      makeMessage({ id: 'now', text: 'And now?' }),
    ], tightModel, { transport: 'openai_responses' });
    const text = outboundText(history.slice(0, 1));
    expect(text).toContain('<FILE_NAME>a.txt</FILE_NAME>');
    expect(text).not.toContain('<FILE_NAME>b.txt</FILE_NAME>');
    expect(history[2].content).toBe('And now?');
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

  // The recovery UI reads kind, retryable and source off the thrown error, and a support request
  // needs the trace id, so every one of them has to survive the stream event.
  it('carries the error kind, retry flags and trace id from a stream error event', async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue({
          type: 'error',
          error: 'The provider quota is exhausted.',
          errorDetail: 'The provider quota is exhausted.',
          errorKind: 'quotaExceeded',
          retryable: false,
          source: 'provider',
          quotaSource: 'provider',
          traceId: 'trc_1',
        });
        controller.close();
      },
    });

    await expect(readStream(stream, '', vi.fn())).rejects.toMatchObject({
      kind: 'quotaExceeded',
      message: 'The provider quota is exhausted.',
      detail: 'The provider quota is exhausted.',
      retryable: false,
      source: 'provider',
      quotaSource: 'provider',
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
