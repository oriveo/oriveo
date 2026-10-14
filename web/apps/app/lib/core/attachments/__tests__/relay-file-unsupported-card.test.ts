/**
  * BOARD-OPTIONS-11: local marker for the Relay file-rejection hint card (file rejection contract, last item).
 *
  * The send goes through the production chain: `buildOutboundChatHistory` -> `sendWithRelayRejectionLoop` -> `sendWithNativeFileFallback`
  * -> production `sendStream` (Relay orchestration layer); only `fetch` is replaced with a fake relay.
 */
import 'fake-indexeddb/auto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamEvent, StreamHandle } from '../../providers/types';
import { createAppStore } from '../../store/app-store';
import { sendStream } from '../../providers/service';
import { sendWithNativeFileFallback } from '../native-file-fallback';
import { buildOutboundChatHistory } from '../../chat/outbound-history';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../chat/stream-options';
import { withoutUnreceivableImages } from '../../chat/attachment-policy';
import { sendWithRelayRejectionLoop } from '../../chat/relay-rejection-loop';
import { createRelayManualModel } from '../../provider-model-ops';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';

const PDF = 'application/pdf';
const RAW_PDF = 'JVBERi0xLjQKb3JpdmVvUkVMQVk=';
const IMAGE_B64 = 'iVBORw0KGgoORIVEOIMAGE';

const sent: string[] = [];
let responders: Array<() => Response> = [];

function reject(status: number): () => Response {
  return () => new Response(JSON.stringify({ error: { message: 'upstream said no' } }), {
    status, headers: { 'Content-Type': 'application/json' },
  });
}

function chatOk(text = 'ANSWER'): () => Response {
  const body = `data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: text } }] })}\n\ndata: [DONE]\n\n`;
  return () => new Response(body, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
}

beforeEach(() => {
  sent.length = 0;
  responders = [];
  localStorage.clear();
  resetCapabilityEvidenceIdentitiesForTesting();
  vi.stubGlobal('fetch', vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
    sent.push(typeof init?.body === 'string' ? init.body : '');
    const next = responders.shift();
    return next ? next() : new Response('not found', { status: 404 });
  }));
});

afterEach(() => {
  vi.unstubAllGlobals();
  localStorage.clear();
  resetCapabilityEvidenceIdentitiesForTesting();
});

/** Protocol follows the connection (no model-level protocol source), so protocol fallback is not triggered: only the text-fallback chain is under test. */
function setup(extra: Partial<AIModel> = {}) {
  const relayModel: AIModel = {
    ...createRelayManualModel('gpt-file', true),
    nativeFileMimes: [PDF], pdfNativeDefault: true,
    ...extra,
  };
  const provider = {
    id: 'relay-file-card', kind: 'relay', status: { kind: 'connected' }, models: [relayModel], catalogModels: [relayModel],
    apiKey: 'sk-test', apiKeyPreview: 'sk-...test', baseURLText: 'https://relay.example.com/v1', relayKind: 'openai_compatible',
    relayRequested: { transport: 'openai_responses', authMode: 'bearer' },
  } as Provider;
  const store = createAppStore();
  store.getState().addProvider(provider);
  beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
  return { store, provider, relayModel };
}

const textPdf = { id: 'f1', kind: 'file', fileName: 'report.pdf', mimeType: PDF,
  originalBase64Data: RAW_PDF, base64Data: 'EXTRACTED-BODY-TEXT', extractedTotalLines: 1 } as Attachment;
const scannedPdf = { id: 'f2', kind: 'file', fileName: 'scan.pdf', mimeType: PDF,
  originalBase64Data: RAW_PDF, base64Data: '', extractionErrorCode: 'scanned_pdf' } as Attachment;
const image = { id: 'img-1', kind: 'image', mimeType: 'image/png', base64Data: IMAGE_B64 } as Attachment;

function userMessage(attachments: Attachment[]): ChatMessage {
  return {
    id: 'u1', role: 'user', text: 'Read this', providerKind: 'relay', providerName: 'Relay', modelName: 'm',
    estimatedCost: 0, state: 'delivered', createdAt: '2026-10-11T00:00:00Z', attachments,
  } as ChatMessage;
}

async function drain(stream: ReadableStream<StreamEvent>): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  const reader = stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) return events;
    events.push(value);
  }
}

async function sendRelay(ctx: ReturnType<typeof setup>, attachments: Attachment[]) {
  const { store, provider, relayModel } = ctx;
  const streamOptions = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(relayModel, 'automatic', false), relayModel);
  const messages = withoutUnreceivableImages([userMessage(attachments)], provider, relayModel, streamOptions);
  const history = await buildOutboundChatHistory({}, { messages, provider, model: relayModel, streamOptions });
  const handle = sendWithRelayRejectionLoop({
    store, provider, model: relayModel, history, streamOptions,
    resolveCandidates: async () => [],
    send: (outbound, options) => sendWithNativeFileFallback(outbound, (h) => sendStream(
      provider.kind, provider.apiKey, relayModel.id, h, provider.baseURLText, options,
    )),
  });
  const events = await drain(handle.stream);
  return { handle, events };
}

const errorsOf = (events: StreamEvent[]) => events.filter((event) => event.type === 'error');

describe('BOARD-OPTIONS-11 Relay file-rejection hint card', () => {
  it.each([400, 404, 415, 422])('BOARD-OPTIONS-11 native file block rejected with %i -> text resend still fails -> marker set, the first error is shown', async (status) => {
    const ctx = setup();
    responders = [reject(status), reject(500)];
    const { handle, events } = await sendRelay(ctx, [textPdf]);
    expect(sent).toHaveLength(2);
    expect(sent[0]).toContain(RAW_PDF);
    expect(sent[1]).not.toContain(RAW_PDF);
    expect(errorsOf(events)).toEqual([expect.objectContaining({ status })]);
    expect(handle.getRelayFileRejected?.()).toBe(true);
  });

  it('BOARD-OPTIONS-11 all scanned documents, no text fallback possible -> marker set on rejection', async () => {
    const ctx = setup();
    responders = [reject(400)];
    const { handle } = await sendRelay(ctx, [scannedPdf]);
    expect(sent).toHaveLength(1);
    expect(handle.getRelayFileRejected?.()).toBe(true);
  });

  it('BOARD-OPTIONS-11 text fallback succeeds -> no marker', async () => {
    const ctx = setup();
    responders = [reject(400), chatOk()];
    const { handle, events } = await sendRelay(ctx, [textPdf]);
    expect(errorsOf(events)).toEqual([]);
    expect(handle.getRelayFileRejected?.()).toBe(false);
  });

  it('BOARD-OPTIONS-11 413 is not a rejection signal -> no marker', async () => {
    const ctx = setup();
    responders = [reject(413), reject(413)];
    const { handle } = await sendRelay(ctx, [textPdf]);
    expect(handle.getRelayFileRejected?.()).toBe(false);
  });

  it('BOARD-OPTIONS-11 request carries no native file block -> no marker', async () => {
    const ctx = setup({ nativeFileMimes: [] });
    responders = [reject(400)];
    const { handle } = await sendRelay(ctx, [textPdf]);
    expect(sent[0]).not.toContain(RAW_PDF);
    expect(handle.getRelayFileRejected?.()).toBe(false);
  });

  it('BOARD-OPTIONS-11 both image rejection and file rejection apply -> the image card wins, no file marker', async () => {
    const ctx = setup();
    responders = [reject(400)];
    const { handle } = await sendRelay(ctx, [scannedPdf, image]);
    expect(sent[0]).toContain(IMAGE_B64);
    expect(handle.getRelayImageRejected?.()).toBe(true);
    expect(handle.getRelayFileRejected?.()).toBe(false);
  });

  it('BOARD-OPTIONS-11 non-Relay form -> the handle is returned unchanged, no file marker', async () => {
    const { store, relayModel } = setup();
    const official = { id: 'official', kind: 'openAI', status: { kind: 'connected' }, models: [], apiKey: 'k' } as unknown as Provider;
    const failing: StreamHandle = {
      stream: new ReadableStream<StreamEvent>({
        start(ctrl) {
          ctrl.enqueue({ type: 'error', error: 'no', status: 400 } as StreamEvent);
          ctrl.close();
        },
      }),
      abort: () => {},
    } as StreamHandle;
    const handle = sendWithRelayRejectionLoop({
      store, provider: official, model: relayModel,
      history: [{ role: 'user', content: [{ type: 'file', mimeType: PDF, data: RAW_PDF, fileName: 'a.pdf' } as never] }],
      streamOptions: undefined, send: () => failing,
    });
    await drain(handle.stream);
    expect(handle.getRelayFileRejected?.() ?? false).toBe(false);
  });
});
