/**
 * Text fallback after the upstream rejects a native file block (`alwaysWithTextFallback`).
 *
 * Runs the real send chain: the outbound history is built by `buildOutboundChatHistory` and the request is
 * sent by the production `sendStream` (the relay orchestration layer / the chat streaming proxy client),
 * with only `fetch` replaced by a fake. Assertions look at the request body that actually went out.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamEvent, StreamOptions } from '../../providers/types';

const mocks = vi.hoisted(() => ({ trackEvent: vi.fn() }));

vi.mock('../../telemetry', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../telemetry')>()),
  trackEvent: mocks.trackEvent,
}));
vi.mock('../../../infra/storage/image-store', () => ({
  loadImageBase64: vi.fn(async () => null),
  imageSizeBytes: vi.fn(async () => 0),
}));

import { sendStream } from '../../providers/service';
import {
  __resetNativeFileFallbackForTest,
  sendWithNativeFileFallback,
} from '../../attachments/native-file-fallback';
import { buildOutboundChatHistory } from '../outbound-history';

const PDF = 'application/pdf';
const RAW_PDF = 'JVBERi0xLjQKb3JpdmVv';

function model(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: 'claude-relay', name: 'Claude', capabilities: ['text', 'image', 'file'],
    reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '$',
    nativeFileMimes: [PDF], pdfNativeDefault: true,
    ...overrides,
  } as AIModel;
}

function relayProvider(id = 'relay-1'): Provider {
  return {
    id, kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [],
    apiKey: 'relay-key', apiKeyPreview: 'k', baseURLText: 'https://relay.example',
    relayResolvedTransport: 'anthropic_messages',
  } as Provider;
}

const RELAY_OPTIONS: StreamOptions = {
  relayTransport: 'anthropic_messages',
  relayResolvedBaseURLText: 'https://relay.example',
};

function textPdf(fileName = 'report.pdf'): Attachment {
  return {
    id: fileName, kind: 'file', fileName, mimeType: PDF,
    originalBase64Data: RAW_PDF, base64Data: 'EXTRACTED-BODY-TEXT', extractedTotalLines: 1,
  } as Attachment;
}

function scannedPdf(fileName = 'scan.pdf'): Attachment {
  return {
    id: fileName, kind: 'file', fileName, mimeType: PDF,
    originalBase64Data: RAW_PDF, base64Data: '', extractionErrorCode: 'scanned_pdf',
  } as Attachment;
}

function userMessage(id: string, attachments: Attachment[]): ChatMessage {
  return {
    id, role: 'user', text: 'Summarize the file', providerKind: 'relay', providerName: 'Relay', modelName: 'm',
    estimatedCost: 0, state: 'delivered', createdAt: '2026-10-09T00:00:00Z', attachments,
  } as ChatMessage;
}

/* -- Fake upstream -- */

const upstreamBodies: string[] = [];
let responders: Array<() => Response> = [];

function reject(status: number): () => Response {
  return () => new Response(JSON.stringify({ error: { message: 'upstream said no' } }), {
    status, headers: { 'Content-Type': 'application/json' },
  });
}

function anthropicOk(text = 'ANSWER'): () => Response {
  const frames = [
    { type: 'message_start', message: { id: 'm', model: 'claude', usage: { input_tokens: 1, output_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } },
    { type: 'content_block_stop', index: 0 },
    { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 1 } },
    { type: 'message_stop' },
  ];
  return () => new Response(
    frames.map((frame) => `event: ${frame.type}\ndata: ${JSON.stringify(frame)}\n\n`).join(''),
    { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
  );
}

beforeEach(() => {
  upstreamBodies.length = 0;
  responders = [];
  mocks.trackEvent.mockClear();
  __resetNativeFileFallbackForTest();
  vi.stubGlobal('fetch', vi.fn(async (_url: unknown, init?: RequestInit) => {
    upstreamBodies.push(typeof init?.body === 'string' ? init.body : '');
    const next = responders.shift();
    if (!next) throw new Error('unexpected extra upstream request');
    return next();
  }));
});

async function drain(stream: ReadableStream<StreamEvent>): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  const reader = stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) return events;
    events.push(value);
  }
}

async function sendRelay(provider: Provider, message: ChatMessage, relayModel = model()): Promise<StreamEvent[]> {
  const history = await buildOutboundChatHistory({}, {
    messages: [message], provider, model: relayModel, streamOptions: RELAY_OPTIONS,
  });
  const handle = sendWithNativeFileFallback(history, (outbound) => sendStream(
    provider.kind, provider.apiKey, relayModel.id, outbound, provider.baseURLText, RELAY_OPTIONS,
  ));
  return drain(handle.stream);
}

function textOf(events: StreamEvent[]): string {
  return events.map((event) => (event.type === 'delta' ? event.content : '')).join('');
}

function errorsOf(events: StreamEvent[]) {
  return events.filter((event): event is Extract<StreamEvent, { type: 'error' }> => event.type === 'error');
}

const hasDocumentBlock = (body: string) => body.includes('"type":"document"') && body.includes(RAW_PDF);
const hasTextInjection = (body: string) => body.includes('<FILE_NAME>') && body.includes('EXTRACTED-BODY-TEXT');

describe('Relay Anthropic line: falls back to text injection after the file block is rejected', () => {
  it('first send carries a document block -> upstream 400 -> automatic resend with text injection -> success; the user never sees the first error', async () => {
    responders = [reject(400), anthropicOk()];
    const events = await sendRelay(relayProvider(), userMessage('u1', [textPdf()]));

    expect(upstreamBodies).toHaveLength(2);
    expect(hasDocumentBlock(upstreamBodies[0])).toBe(true);
    expect(upstreamBodies[0]).not.toContain('ATTACHMENT_FILE');
    // Second request: the same message, with the file injected as text and no file block
    expect(hasTextInjection(upstreamBodies[1])).toBe(true);
    expect(upstreamBodies[1]).not.toContain('"type":"document"');
    expect(upstreamBodies[1]).not.toContain(RAW_PDF);
    expect(upstreamBodies[1]).toContain('Summarize the file');

    expect(textOf(events)).toBe('ANSWER');
    expect(errorsOf(events)).toEqual([]);
    // The fallback records one count: only provider_kind and the protocol
    expect(mocks.trackEvent).toHaveBeenCalledWith('native_file_fallback', {
      provider_kind: expect.any(String),
      protocol: 'relay_anthropic_messages',
    });
    expect(mocks.trackEvent.mock.calls.filter(([name]) => name === 'native_file_fallback')).toHaveLength(1);
    expect(JSON.stringify(mocks.trackEvent.mock.calls)).not.toContain('report.pdf');
  });

  it('second message on the same connection: only one text request is sent', async () => {
    const provider = relayProvider();
    responders = [reject(400), anthropicOk()];
    await sendRelay(provider, userMessage('u1', [textPdf()]));

    upstreamBodies.length = 0;
    responders = [anthropicOk('SECOND')];
    const events = await sendRelay(provider, userMessage('u2', [textPdf('next.pdf')]));
    expect(upstreamBodies).toHaveLength(1);
    expect(hasTextInjection(upstreamBodies[0])).toBe(true);
    expect(upstreamBodies[0]).not.toContain('"type":"document"');
    expect(textOf(events)).toBe('SECOND');

    // The memory is per connection: another connection still sends the file block first
    upstreamBodies.length = 0;
    responders = [anthropicOk()];
    await sendRelay(relayProvider('relay-2'), userMessage('u3', [textPdf()]));
    expect(upstreamBodies).toHaveLength(1);
    expect(hasDocumentBlock(upstreamBodies[0])).toBe(true);
  });

  it.each([404, 413, 415, 422])('upstream %i falls back as well', async (status) => {
    responders = [reject(status), anthropicOk()];
    const events = await sendRelay(relayProvider(), userMessage('u1', [textPdf()]));
    expect(upstreamBodies).toHaveLength(2);
    expect(textOf(events)).toBe('ANSWER');
  });

  it('the rejected native files are all scanned: no fallback, this error is shown', async () => {
    responders = [reject(400)];
    const events = await sendRelay(relayProvider(), userMessage('u1', [scannedPdf()]));
    expect(upstreamBodies).toHaveLength(1);
    expect(hasDocumentBlock(upstreamBodies[0])).toBe(true);
    expect(errorsOf(events)).toEqual([expect.objectContaining({ status: 400 })]);
    expect(mocks.trackEvent).not.toHaveBeenCalledWith('native_file_fallback', expect.anything());
  });

  it.each([401, 403, 429, 500, 503])('upstream %i: no fallback', async (status) => {
    responders = [reject(status)];
    const events = await sendRelay(relayProvider(), userMessage('u1', [textPdf()]));
    expect(upstreamBodies).toHaveLength(1);
    expect(errorsOf(events)).toEqual([expect.objectContaining({ status })]);
    expect(mocks.trackEvent).not.toHaveBeenCalledWith('native_file_fallback', expect.anything());
  });

  it('the resend also fails: the first error is shown and the connection is not remembered', async () => {
    const provider = relayProvider();
    responders = [reject(422), reject(500)];
    const events = await sendRelay(provider, userMessage('u1', [textPdf()]));
    expect(upstreamBodies).toHaveLength(2);
    expect(errorsOf(events)).toEqual([expect.objectContaining({ status: 422 })]);
    // A resend that did not succeed is not a fallback: the count is recorded only after the upstream accepts the resend
    expect(mocks.trackEvent).not.toHaveBeenCalledWith('native_file_fallback', expect.anything());

    // Not remembered: the next message still sends the file block first
    upstreamBodies.length = 0;
    responders = [anthropicOk()];
    await sendRelay(provider, userMessage('u2', [textPdf()]));
    expect(hasDocumentBlock(upstreamBodies[0])).toBe(true);
  });

  it('mixed scanned and text PDFs: after the fallback the text PDF carries its body and the scanned one carries the "could not be read" note', async () => {
    responders = [reject(400), anthropicOk()];
    await sendRelay(relayProvider(), userMessage('u1', [scannedPdf(), textPdf()]));
    expect(upstreamBodies).toHaveLength(2);
    expect(hasTextInjection(upstreamBodies[1])).toBe(true);
    expect(upstreamBodies[1]).toContain('scanned_pdf');
    expect(upstreamBodies[1]).not.toContain(RAW_PDF);
  });

  it('the fallback version does not fit the text budget: no fallback, the first error is shown', async () => {
    const tight = model({ attachmentExtraction: { totalCap: 4 } });
    responders = [reject(400)];
    const events = await sendRelay(relayProvider(), userMessage('u1', [textPdf()]), tight);
    expect(upstreamBodies).toHaveLength(1);
    expect(errorsOf(events)).toEqual([expect.objectContaining({ status: 400 })]);
  });

  it('a request without file blocks gets a 400: the error is reported unchanged', async () => {
    responders = [reject(400)];
    const events = await sendRelay(relayProvider(), userMessage('u1', []));
    expect(upstreamBodies).toHaveLength(1);
    expect(errorsOf(events)).toEqual([expect.objectContaining({ status: 400 })]);
  });
});

describe('official direct lines: no fallback', () => {
  it('OpenRouter with a native file block gets a 400: sent once, the error is shown', async () => {
    const provider = {
      id: 'or-1', kind: 'openRouter', status: { kind: 'connected' }, models: [], catalogModels: [],
      apiKey: 'k', apiKeyPreview: 'k',
    } as Provider;
    const orModel = model({ id: 'openai/gpt-x' });
    // A direct line is derived by a dry run over metadata; here the line is given directly, and building and sending are still the production path.
    const { buildChatHistory } = await import('../../../utils/chat-stream-utils');
    const history = await buildChatHistory([userMessage('u1', [textPdf()])], orModel, { transport: 'openrouter_chat' });
    expect(JSON.stringify(history)).toContain('"type":"file"');

    // /api/chat/stream relays the upstream 400 unchanged
    responders = [() => new Response(JSON.stringify({ error: 'upstream said no' }), {
      status: 400, headers: { 'Content-Type': 'application/json', 'X-Oriveo-Error-Source': 'provider' },
    })];
    const handle = sendWithNativeFileFallback(history, (outbound) => sendStream(
      provider.kind, provider.apiKey, orModel.id, outbound, undefined, undefined,
    ));
    const events = await drain(handle.stream);
    expect(upstreamBodies).toHaveLength(1);
    expect(errorsOf(events)).toHaveLength(1);
    expect(mocks.trackEvent).not.toHaveBeenCalledWith('native_file_fallback', expect.anything());
  });
});
