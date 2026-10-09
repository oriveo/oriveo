/**
 * The anti-forget reminder keeps attachments: when the last user message carries an image and a native file block, the reminder is only appended to the end of the text.
 *
 * The outbound history is built by the production `buildOutboundChatHistory` and the request is sent by the
 * production `sendStream`, with only `fetch` replaced by a fake; assertions look at the request body that
 * actually went out.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamEvent, StreamOptions } from '../../providers/types';

vi.mock('../../../infra/storage/image-store', () => ({
  loadImageBase64: vi.fn(async () => 'SU1BR0UtQllURVM='),
  imageSizeBytes: vi.fn(async () => 12),
}));

import { sendStream } from '../../providers/service';
import {
  __resetNativeFileFallbackForTest,
  sendWithNativeFileFallback,
} from '../../attachments/native-file-fallback';
import { buildOutboundChatHistory } from '../outbound-history';
import { appendAntiForgetReminder } from '../prompt-injection';

const PDF = 'application/pdf';
const RAW_PDF = 'JVBERi0xLjQKb3JpdmVv';
const IMAGE_B64 = 'SU1BR0UtQllURVM=';
const REMINDER = '[Reminder: Answer in French]';

const MODEL = {
  id: 'claude-relay', name: 'Claude', capabilities: ['text', 'image', 'file'],
  reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '$',
  nativeFileMimes: [PDF], pdfNativeDefault: true,
} as AIModel;

const PROVIDER = {
  id: 'relay-1', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [],
  apiKey: 'relay-key', apiKeyPreview: 'k', baseURLText: 'https://relay.example',
  relayResolvedTransport: 'anthropic_messages',
} as Provider;

const RELAY_OPTIONS: StreamOptions = {
  relayTransport: 'anthropic_messages',
  relayResolvedBaseURLText: 'https://relay.example',
};

const PREFS = { memoryAntiForgetEnabled: true, memoryAntiForgetText: 'Answer in French' };
const CONTEXT = { useMemory: true, remainingChars: 10_000 };

function message(id: string, role: 'user' | 'assistant', text: string, attachments: Attachment[] = []): ChatMessage {
  return {
    id, role, text, providerKind: 'relay', providerName: 'Relay', modelName: 'm',
    estimatedCost: 0, state: 'delivered', createdAt: '2026-10-09T00:00:00Z', attachments,
  } as ChatMessage;
}

/** A 10-turn conversation; the last user message carries one image and one PDF. */
function tenTurns(lastAttachments: Attachment[]): ChatMessage[] {
  const out: ChatMessage[] = [];
  for (let turn = 1; turn <= 9; turn += 1) {
    out.push(message(`u${turn}`, 'user', `question ${turn}`), message(`a${turn}`, 'assistant', `answer ${turn}`));
  }
  out.push(message('u10', 'user', 'Compare the chart with the report', lastAttachments));
  return out;
}

const image = { id: 'img', kind: 'image', fileName: 'chart.png', mimeType: 'image/png', localImageID: 'img-1' } as Attachment;
const textPdf = {
  id: 'pdf', kind: 'file', fileName: 'report.pdf', mimeType: PDF,
  originalBase64Data: RAW_PDF, base64Data: 'EXTRACTED-BODY-TEXT', extractedTotalLines: 1,
} as Attachment;

const upstreamBodies: string[] = [];
let responders: Array<() => Response> = [];

function reject(status: number): () => Response {
  return () => new Response(JSON.stringify({ error: { message: 'upstream said no' } }), {
    status, headers: { 'Content-Type': 'application/json' },
  });
}

function anthropicOk(): () => Response {
  const frames = [
    { type: 'message_start', message: { id: 'm', model: 'claude', usage: { input_tokens: 1, output_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'ANSWER' } },
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
  __resetNativeFileFallbackForTest();
  vi.stubGlobal('fetch', vi.fn(async (_url: unknown, init?: RequestInit) => {
    upstreamBodies.push(typeof init?.body === 'string' ? init.body : '');
    const next = responders.shift();
    if (!next) throw new Error('unexpected extra upstream request');
    return next();
  }));
});

async function send(messages: ChatMessage[], prefs = PREFS): Promise<void> {
  const history = await buildOutboundChatHistory({}, {
    messages, provider: PROVIDER, model: MODEL, streamOptions: RELAY_OPTIONS,
  });
  appendAntiForgetReminder(history, prefs, CONTEXT);
  const handle = sendWithNativeFileFallback(history, (outbound) => sendStream(
    PROVIDER.kind, PROVIDER.apiKey, MODEL.id, outbound, PROVIDER.baseURLText, RELAY_OPTIONS,
  ));
  const reader = (handle.stream as ReadableStream<StreamEvent>).getReader();
  while (!(await reader.read()).done) { /* drain */ }
}

interface AnthropicBlock { type: string; text?: string; source?: { data?: string } }

function lastUserBlocks(body: string): AnthropicBlock[] {
  const messages = (JSON.parse(body) as { messages: Array<{ role: string; content: string | AnthropicBlock[] }> }).messages;
  const last = messages.filter((entry) => entry.role === 'user').at(-1)!;
  return typeof last.content === 'string' ? [{ type: 'text', text: last.content }] : last.content;
}

const textOf = (blocks: AnthropicBlock[]) => blocks.map((block) => (block.type === 'text' ? block.text : '')).join('');

describe('anti-forget reminder: the last user message carries attachments', () => {
  it('the image block and the native file block stay in the outbound body unchanged, with the reminder at the end of the text', async () => {
    responders = [anthropicOk()];
    await send(tenTurns([image, textPdf]));

    expect(upstreamBodies).toHaveLength(1);
    const blocks = lastUserBlocks(upstreamBodies[0]);
    expect(blocks.filter((block) => block.type === 'image').map((block) => block.source?.data)).toEqual([IMAGE_B64]);
    expect(blocks.filter((block) => block.type === 'document').map((block) => block.source?.data)).toEqual([RAW_PDF]);
    const text = textOf(blocks);
    expect(text).toContain('Compare the chart with the report');
    expect(text.endsWith(`\n\n${REMINDER}`)).toBe(true);
    expect(text.split(REMINDER)).toHaveLength(2);
  });

  it('the text fallback request after the upstream rejects the file block carries the image and the reminder too', async () => {
    responders = [reject(400), anthropicOk()];
    await send(tenTurns([image, textPdf]));

    expect(upstreamBodies).toHaveLength(2);
    const blocks = lastUserBlocks(upstreamBodies[1]);
    expect(blocks.filter((block) => block.type === 'image').map((block) => block.source?.data)).toEqual([IMAGE_B64]);
    expect(blocks.some((block) => block.type === 'document')).toBe(false);
    const text = textOf(blocks);
    expect(text).toContain('EXTRACTED-BODY-TEXT');
    expect(text.endsWith(`\n\n${REMINDER}`)).toBe(true);
  });

  it('the reminder format for a plain text message is unchanged', async () => {
    responders = [anthropicOk()];
    await send(tenTurns([]));
    expect(textOf(lastUserBlocks(upstreamBodies[0]))).toBe(`Compare the chart with the report\n\n${REMINDER}`);
  });

  it('nothing is appended when the mode is off or there are fewer than 10 turns', async () => {
    responders = [anthropicOk(), anthropicOk()];
    await send(tenTurns([image]), { ...PREFS, memoryAntiForgetEnabled: false });
    await send(tenTurns([image]).slice(2));
    expect(upstreamBodies.join('')).not.toContain('[Reminder: ');
  });
});

describe('send and continue generating share one function', () => {
  it.each(['operations-send.ts', 'operations-continue.ts'])('%s appends the reminder only through appendAntiForgetReminder', (file) => {
    const source = readFileSync(join(__dirname, '..', file), 'utf8');
    expect(source).toContain('appendAntiForgetReminder(chatHistory, store.getState().preferences, promptContext)');
    expect(source).not.toContain('REMINDER_PREFIX');
  });
});
