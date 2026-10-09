/**
 * Line declaration contrast test: the declaration of every line in `attachment-transport.ts` must equal what
 * that line's production request builder actually does with a `file` part.
 *
 * The declaration and the builder are two pieces of code, and aligning them by hand drifts sooner or later;
 * the consequence of drift is that a file routed to native reaches neither the body nor the request. The
 * probe table is a `Record<AttachmentTransport, ...>`, so adding a line without a probe is a type error.
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, ChatMessage, Provider } from '@oriveo/shared';
import {
  ATTACHMENT_TRANSPORTS,
  type AttachmentTransport,
  type NativeFileBlock,
  AttachmentTransportMismatchError,
  assertFilePartsDeliverable,
  attachmentTransportProfile,
  dispatchedAttachmentTransport,
  grokSubscriptionAttachmentTransport,
  outboundWireOf,
  relayAttachmentTransport,
} from '@oriveo/core/providers/attachment-transport';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import { buildAnthropicRequest } from '@oriveo/core/providers/request-builders/anthropic';
import { buildDeepSeekRequest } from '@oriveo/core/providers/request-builders/deepseek';
import { buildGeminiRequest } from '@oriveo/core/providers/request-builders/gemini';
import { buildGeminiInteractionsRequest } from '@oriveo/core/providers/request-builders/gemini-interactions';
import { buildGrokRequest } from '@oriveo/core/providers/request-builders/grok';
import { buildMiniMaxRequest } from '@oriveo/core/providers/request-builders/minimax';
import { buildMiniMaxAnthropicMessagesRequest } from '@oriveo/core/providers/request-builders/minimax-anthropic-messages';
import { buildMoonshotRequest } from '@oriveo/core/providers/request-builders/moonshot';
import { buildOpenAICompatibleRequest } from '@oriveo/core/providers/request-builders/openai-compatible';
import { buildOpenAIRequest, buildOpenRouterRequest } from '@oriveo/core/providers/request-builders/openai';
import { buildQwenRequest } from '@oriveo/core/providers/request-builders/qwen';
import { buildSiliconFlowRequest } from '@oriveo/core/providers/request-builders/siliconflow';
import { buildZhipuRequest } from '@oriveo/core/providers/request-builders/zhipu';
import {
  applyToolCallWireAdapter,
  protocolForRequest,
} from '@oriveo/core/providers/request-builders/tool-call-wire-adapter';
import type { ProxyMessage, RuntimeMetadataResponse } from '@oriveo/core/providers/request-builders/runtime';
import type { ProviderRequest, RequestParams } from '@oriveo/core/providers/request-builders/types';
import {
  buildResponsesContent,
  convertToAnthropicParts,
  convertToGeminiParts,
  convertToOpenAIChatParts,
} from '@oriveo/core/providers/relay-adapter';
import { buildLlamaCppNativePrompt } from '@oriveo/core/providers/relay-orchestrator';
import type { ContentPart } from '@oriveo/core/providers/types';
import { buildMoonshotMessages } from '../../providers/adapters/moonshot';
import { buildChatHistory } from '../../../utils/chat-stream-utils';
import { applyGrokSubscriptionTransport } from '../../../../app/api/chat/stream/grok-subscription-transport';
import { buildCodexSubscriptionRequest } from '../../../../app/api/chat/stream/openai-subscription-transport';
import { resolveAttachmentLine } from '../attachment-transport-resolver';

vi.mock('../../../infra/storage/image-store', () => ({
  loadImageBase64: vi.fn(async () => null),
  imageSizeBytes: vi.fn(async () => 0),
}));

/* -- Fixtures -- */

const MARKER = 'ORIVEO-PDF-MARKER-7391';
const QUESTION = 'What is the marker code printed in the attached PDF? Reply with the code only.';

/** A minimal one-page PDF whose body is only a marker word (with correct xref offsets). */
function minimalPdfBase64(text: string): string {
  const stream = `BT /F1 24 Tf 72 720 Td (${text}) Tj ET`;
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  let pdf = '%PDF-1.4\n';
  const offsets: number[] = [];
  objects.forEach((body, index) => {
    offsets.push(pdf.length);
    pdf += `${index + 1} 0 obj\n${body}\nendobj\n`;
  });
  const xref = pdf.length;
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const offset of offsets) pdf += `${String(offset).padStart(10, '0')} 00000 n \n`;
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(pdf, 'latin1').toString('base64');
}

const PDF_BASE64 = minimalPdfBase64(MARKER);
const PDF_DATA_URI = `data:application/pdf;base64,${PDF_BASE64}`;

const FILE_PART: ContentPart = {
  type: 'file',
  file: { filename: 'marker.pdf', file_data: PDF_DATA_URI, mimeType: 'application/pdf' },
};

const PROBE_MESSAGES: ProxyMessage[] = [
  { role: 'user', content: [{ type: 'text', text: 'read it' }, FILE_PART] },
];

function params(providerKind: RequestParams['providerKind'], modelID = 'm'): RequestParams {
  return { providerKind, apiKey: 'k', modelID, messages: PROBE_MESSAGES };
}

const TOOL = {
  type: 'function' as const,
  function: { name: 'lookup', description: 'd', parameters: { type: 'object', properties: {} } },
};

function toolLeg(request: ProviderRequest, providerKind: RequestParams['providerKind']): unknown {
  return applyToolCallWireAdapter(request, {
    providerKind, messages: PROBE_MESSAGES, tools: [TOOL], toolChoice: 'auto',
  }).body;
}

/** Finds a native file block in a request body; returns null when there is none (a file treated as an image or written as placeholder text counts as none). */
function findNativeFileBlock(value: unknown): NativeFileBlock | null {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findNativeFileBlock(item);
      if (found) return found;
    }
    return null;
  }
  if (!value || typeof value !== 'object') return null;
  const record = value as Record<string, unknown>;
  if (record.type === 'input_file') return 'input_file';
  if (record.type === 'document') return 'document';
  if (record.type === 'file') return 'file';
  if (record.inlineData && (record.inlineData as { mimeType?: unknown }).mimeType === 'application/pdf') {
    return 'inline_data';
  }
  for (const child of Object.values(record)) {
    const found = findNativeFileBlock(child);
    if (found) return found;
  }
  return null;
}

const GEMINI_INTERACTIONS_ROUTE = {
  protocol: 'gemini_interactions', endpointClass: 'interactions', path: '/v1beta/interactions',
  requestMapper: 'gemini_interactions',
};
const MINIMAX_ANTHROPIC_ROUTE = {
  protocol: 'anthropic_messages', endpointClass: 'messages', path: '/anthropic/v1/messages',
  requestMapper: 'anthropic_messages', authHeader: 'x-api-key', headers: {},
};
const GROK_SUBSCRIPTION = {
  chatURL: 'https://cli-chat-proxy.grok.com/v1/chat/completions',
  responsesURL: 'https://cli-chat-proxy.grok.com/v1/responses',
  requiredHeaders: {},
};
const CODEX_SUBSCRIPTION = {
  responsesURL: 'https://chatgpt.com/backend-api/codex/responses',
  requiredHeaders: {},
};

interface Probe {
  /** The request body this line's production builder produces from a `file` part. */
  body: () => unknown;
  /** The request body of the same line when client tools are attached; a line that does not go through /api/chat/stream has no tool leg. */
  toolLegBody?: () => unknown;
}

const PROBES: Record<AttachmentTransport, Probe> = {
  openai_chat: {
    body: () => buildOpenAIRequest(params('openAI'), null, null, null, null, null).body,
    toolLegBody: () => toolLeg(buildOpenAIRequest(params('openAI'), null, null, null, null, null), 'openAI'),
  },
  openai_responses: {
    body: () => buildOpenAIRequest(params('openAI'), null, null, null, null, null, undefined, 'openai_responses').body,
    toolLegBody: () => toolLeg(
      buildOpenAIRequest(params('openAI'), null, null, null, null, null, undefined, 'openai_responses'), 'openAI',
    ),
  },
  openai_subscription_codex: {
    body: () => buildCodexSubscriptionRequest(params('openAI'), CODEX_SUBSCRIPTION as never).body,
    toolLegBody: () => toolLeg(buildCodexSubscriptionRequest(params('openAI'), CODEX_SUBSCRIPTION as never), 'openAI'),
  },
  anthropic_messages: {
    body: () => buildAnthropicRequest(params('anthropic'), null, null).body,
    toolLegBody: () => toolLeg(buildAnthropicRequest(params('anthropic'), null, null), 'anthropic'),
  },
  gemini_generate: {
    body: () => buildGeminiRequest(params('gemini'), null, null, null).body,
    toolLegBody: () => toolLeg(buildGeminiRequest(params('gemini'), null, null, null), 'gemini'),
  },
  gemini_interactions: {
    body: () => buildGeminiInteractionsRequest(params('gemini'), GEMINI_INTERACTIONS_ROUTE as never).body,
  },
  openrouter_chat: {
    body: () => buildOpenRouterRequest(params('openRouter'), null, null, null).body,
    toolLegBody: () => toolLeg(buildOpenRouterRequest(params('openRouter'), null, null, null), 'openRouter'),
  },
  grok_chat: {
    body: () => buildGrokRequest(params('grok'), null, null).body,
    toolLegBody: () => toolLeg(buildGrokRequest(params('grok'), null, null), 'grok'),
  },
  grok_responses: {
    body: () => buildGrokRequest(params('grok'), null, null, 'openai_responses').body,
    toolLegBody: () => toolLeg(buildGrokRequest(params('grok'), null, null, 'openai_responses'), 'grok'),
  },
  grok_subscription_chat: {
    body: () => applyGrokSubscriptionTransport(
      buildGrokRequest(params('grok'), null, null), GROK_SUBSCRIPTION as never,
      { apiBackend: 'chat', messages: PROBE_MESSAGES },
    ).body,
  },
  grok_subscription_responses: {
    body: () => applyGrokSubscriptionTransport(
      buildGrokRequest(params('grok'), null, null), GROK_SUBSCRIPTION as never,
      { apiBackend: 'responses', messages: PROBE_MESSAGES },
    ).body,
  },
  minimax_chat: {
    body: () => buildMiniMaxRequest(params('miniMax'), null, null).body,
    toolLegBody: () => toolLeg(buildMiniMaxRequest(params('miniMax'), null, null), 'miniMax'),
  },
  minimax_anthropic_messages: {
    body: () => buildMiniMaxAnthropicMessagesRequest(params('miniMax'), MINIMAX_ANTHROPIC_ROUTE as never).body,
  },
  deepseek_chat: {
    body: () => buildDeepSeekRequest(params('deepseek'), null, false).body,
    toolLegBody: () => toolLeg(buildDeepSeekRequest(params('deepseek'), null, false), 'deepseek'),
  },
  qwen_chat: {
    body: () => buildQwenRequest(params('qwen'), null, null, null).body,
    toolLegBody: () => toolLeg(buildQwenRequest(params('qwen'), null, null, null), 'qwen'),
  },
  moonshot_chat: {
    body: () => buildMoonshotRequest(params('moonshot'), null, null).body,
    toolLegBody: () => toolLeg(buildMoonshotRequest(params('moonshot'), null, null), 'moonshot'),
  },
  moonshot_browser_direct: {
    body: () => buildMoonshotMessages(PROBE_MESSAGES as never),
  },
  zhipu_chat: {
    body: () => buildZhipuRequest(params('zhipu'), null, null).body,
    toolLegBody: () => toolLeg(buildZhipuRequest(params('zhipu'), null, null), 'zhipu'),
  },
  siliconflow_chat: {
    body: () => buildSiliconFlowRequest(params('siliconFlow'), null).body,
    toolLegBody: () => toolLeg(buildSiliconFlowRequest(params('siliconFlow'), null), 'siliconFlow'),
  },
  openai_compatible_chat: {
    body: () => buildOpenAICompatibleRequest(params('mistral'), null).body,
    toolLegBody: () => toolLeg(buildOpenAICompatibleRequest(params('mistral'), null), 'mistral'),
  },
  relay_openai_chat: {
    body: () => convertToOpenAIChatParts([FILE_PART]),
    // A relay request with tools goes through /api/chat/stream and is built by the OpenAI-compatible builder.
    toolLegBody: () => toolLeg(
      buildOpenAICompatibleRequest({ ...params('relay'), baseURL: 'https://relay.example/v1' }, null), 'relay',
    ),
  },
  relay_openai_responses: { body: () => buildResponsesContent('user', [FILE_PART]) },
  relay_anthropic_messages: { body: () => convertToAnthropicParts([FILE_PART]) },
  relay_gemini_generate: { body: () => convertToGeminiParts([FILE_PART]) },
  relay_llamacpp_native: { body: () => buildLlamaCppNativePrompt(PROBE_MESSAGES as never) },
};

describe('line declaration = what the production request builder actually does with a file part', () => {
  it.each(ATTACHMENT_TRANSPORTS)('%s', (transport) => {
    const profile = attachmentTransportProfile(transport);
    const probe = PROBES[transport];
    expect(findNativeFileBlock(probe.body())).toBe(profile.nativeFileBlock);
    if (probe.toolLegBody) {
      expect(findNativeFileBlock(probe.toolLegBody())).toBe(profile.toolLoopNativeFileBlock);
    } else {
      expect(profile.toolLoopNativeFileBlock).toBeNull();
    }
  });

  it('the DeepSeek and llama.cpp image placeholders match the declaration', () => {
    const withImage: ProxyMessage[] = [{
      role: 'user',
      content: [{ type: 'text', text: 'look' }, { type: 'image_url', image_url: { url: 'data:image/png;base64,AAAA' } }],
    }];
    const deepseek = buildDeepSeekRequest({ ...params('deepseek'), messages: withImage }, null, false).body;
    expect(JSON.stringify(deepseek)).toContain(attachmentTransportProfile('deepseek_chat').imagePlaceholderText);

    // The same literal on every client; DeepSeek is an existing line and keeps its original placeholder.
    expect(attachmentTransportProfile('deepseek_chat').imagePlaceholderText).toBe('[Image omitted: unsupported by DeepSeek]');
    expect(attachmentTransportProfile('relay_llamacpp_native').imagePlaceholderText).toBe('[Image omitted: this route sends text only]');
    expect(buildLlamaCppNativePrompt(withImage as never)).toBe('user: look\n[Image omitted: this route sends text only]');
    // Without images the prompt is byte-for-byte what it was before
    expect(buildLlamaCppNativePrompt([{ role: 'user', content: [{ type: 'text', text: 'a' }, { type: 'text', text: 'b' }] }] as never))
      .toBe('user: a\nb');
  });
});

describe('line resolution shares its test with the real builder choice', () => {
  it('the outbound protocol test and the tool leg message conversion use the same criterion', () => {
    const requests = [
      buildOpenAIRequest(params('openAI'), null, null, null, null, null),
      buildOpenAIRequest(params('openAI'), null, null, null, null, null, undefined, 'openai_responses'),
      buildAnthropicRequest(params('anthropic'), null, null),
      buildGeminiRequest(params('gemini'), null, null, null),
      buildOpenRouterRequest(params('openRouter'), null, null, null),
      buildGrokRequest(params('grok'), null, null, 'openai_responses'),
      buildMiniMaxAnthropicMessagesRequest(params('miniMax'), MINIMAX_ANTHROPIC_ROUTE as never),
    ];
    for (const request of requests) expect(outboundWireOf(request)).toBe(protocolForRequest(request));
    expect(outboundWireOf(buildGeminiInteractionsRequest(params('gemini'), GEMINI_INTERACTIONS_ROUTE as never)))
      .toBe('gemini_interactions');
  });

  it('a dispatched request maps to the declared line', () => {
    const cases: Array<[RequestParams['providerKind'], ProviderRequest, AttachmentTransport]> = [
      ['openAI', buildOpenAIRequest(params('openAI'), null, null, null, null, null), 'openai_chat'],
      ['openAI', buildOpenAIRequest(params('openAI'), null, null, null, null, null, undefined, 'openai_responses'), 'openai_responses'],
      ['anthropic', buildAnthropicRequest(params('anthropic'), null, null), 'anthropic_messages'],
      ['gemini', buildGeminiRequest(params('gemini'), null, null, null), 'gemini_generate'],
      ['gemini', buildGeminiInteractionsRequest(params('gemini'), GEMINI_INTERACTIONS_ROUTE as never), 'gemini_interactions'],
      ['openRouter', buildOpenRouterRequest(params('openRouter'), null, null, null), 'openrouter_chat'],
      ['grok', buildGrokRequest(params('grok'), null, null), 'grok_chat'],
      ['grok', buildGrokRequest(params('grok'), null, null, 'openai_responses'), 'grok_responses'],
      ['miniMax', buildMiniMaxRequest(params('miniMax'), null, null), 'minimax_chat'],
      ['miniMax', buildMiniMaxAnthropicMessagesRequest(params('miniMax'), MINIMAX_ANTHROPIC_ROUTE as never), 'minimax_anthropic_messages'],
      ['deepseek', buildDeepSeekRequest(params('deepseek'), null, false), 'deepseek_chat'],
      ['qwen', buildQwenRequest(params('qwen'), null, null, null), 'qwen_chat'],
      ['moonshot', buildMoonshotRequest(params('moonshot'), null, null), 'moonshot_chat'],
      ['zhipu', buildZhipuRequest(params('zhipu'), null, null), 'zhipu_chat'],
      ['siliconFlow', buildSiliconFlowRequest(params('siliconFlow'), null), 'siliconflow_chat'],
      ['mistral', buildOpenAICompatibleRequest(params('mistral'), null), 'openai_compatible_chat'],
    ];
    for (const [kind, request, expected] of cases) {
      expect(dispatchedAttachmentTransport(kind, outboundWireOf(request))).toBe(expected);
    }
  });

  it('relay protocols and the Grok subscription declaration map to their own lines', () => {
    expect(relayAttachmentTransport('openai_chat_completions')).toBe('relay_openai_chat');
    expect(relayAttachmentTransport(undefined)).toBe('relay_openai_chat');
    expect(relayAttachmentTransport('openai_responses')).toBe('relay_openai_responses');
    expect(relayAttachmentTransport('anthropic_messages')).toBe('relay_anthropic_messages');
    expect(relayAttachmentTransport('gemini_generate_content')).toBe('relay_gemini_generate');
    expect(relayAttachmentTransport('llamacpp_native')).toBe('relay_llamacpp_native');
    expect(grokSubscriptionAttachmentTransport('responses')).toBe('grok_subscription_responses');
    expect(grokSubscriptionAttachmentTransport('chat')).toBe('grok_subscription_chat');
    expect(grokSubscriptionAttachmentTransport(undefined)).toBeNull();
  });

  it('last gate before sending: a native file part landing on a line that does not accept it raises an error', () => {
    expect(() => assertFilePartsDeliverable({ transport: 'openai_chat' }, PROBE_MESSAGES))
      .toThrow(AttachmentTransportMismatchError);
    expect(() => assertFilePartsDeliverable({ transport: 'openai_responses', toolLoop: true }, PROBE_MESSAGES))
      .toThrow(AttachmentTransportMismatchError);
    expect(() => assertFilePartsDeliverable({ transport: null }, PROBE_MESSAGES))
      .toThrow(AttachmentTransportMismatchError);
    expect(() => assertFilePartsDeliverable({ transport: 'openai_responses' }, PROBE_MESSAGES)).not.toThrow();
    expect(() => assertFilePartsDeliverable({ transport: 'openrouter_chat', toolLoop: true }, PROBE_MESSAGES)).not.toThrow();
    expect(() => assertFilePartsDeliverable({ transport: 'relay_anthropic_messages' }, PROBE_MESSAGES)).not.toThrow();
    // A request without a file part is unaffected
    expect(() => assertFilePartsDeliverable({ transport: 'openai_chat' }, [{ role: 'user', content: 'hi' }])).not.toThrow();
  });
});

/* -- Production path: attachment -> line resolution -> outbound history -> dispatch -> request body -- */

const PDF_MIME = 'application/pdf';

function officialMetadata(
  providerKind: string,
  modelID: string,
  model: Record<string, unknown> = {},
): RuntimeMetadataResponse {
  return {
    version: 1,
    updatedAt: '2026-10-09T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    providers: {
      [providerKind]: {
        resolveMap: { [modelID]: modelID },
        models: { [modelID]: { canonicalModelId: modelID, capabilities: ['text', 'image', 'file'], profiles: {}, ...model } },
      },
    },
  } as unknown as RuntimeMetadataResponse;
}

function catalogModel(id: string, overrides: Partial<AIModel> = {}): AIModel {
  return {
    id, name: id, capabilities: ['text', 'image', 'file'], reasoningModeAvailable: false,
    isAvailable: true, isDefault: true, priceTier: '$',
    nativeFileMimes: [PDF_MIME], pdfNativeDefault: false,
    ...overrides,
  } as AIModel;
}

function provider(kind: Provider['kind'], overrides: Partial<Provider> = {}): Provider {
  return {
    id: `p-${kind}`, kind, status: { kind: 'connected' }, models: [], catalogModels: [],
    apiKey: 'k', apiKeyPreview: 'k', ...overrides,
  } as Provider;
}

/** A PDF whose text cannot be extracted: the marker word is only in the raw bytes, not in the extracted text. */
function markerPdfAttachment(overrides: Partial<Attachment> = {}): Attachment {
  return {
    id: 'att-1', kind: 'file', fileName: 'marker.pdf', mimeType: PDF_MIME,
    originalBase64Data: PDF_BASE64, extractionErrorCode: 'scanned_pdf',
    ...overrides,
  } as Attachment;
}

function userMessage(attachments: Attachment[]): ChatMessage {
  return {
    id: 'u1', role: 'user', text: QUESTION, providerKind: 'openAI', providerName: 'p', modelName: 'm',
    estimatedCost: 0, state: 'delivered', createdAt: '2026-10-09T00:00:00Z', attachments,
  } as ChatMessage;
}

async function outboundRequest(input: {
  providerKind: Provider['kind'];
  model: AIModel;
  metadata: RuntimeMetadataResponse;
  attachment?: Attachment;
}): Promise<{ transport: AttachmentTransport; request: ProviderRequest }> {
  const line = await resolveAttachmentLine({
    provider: provider(input.providerKind),
    model: input.model,
    officialMetadata: async () => input.metadata,
  });
  expect(line.exact).toBe(true);
  const history = await buildChatHistory([userMessage([input.attachment ?? markerPdfAttachment()])], input.model, line);
  const request = await buildProviderRequest({
    providerKind: input.providerKind, apiKey: 'test-key', modelID: input.model.id,
    messages: history as ProxyMessage[],
  }, async () => input.metadata);
  // The check the route makes before sending, using the line actually selected
  assertFilePartsDeliverable(
    { transport: dispatchedAttachmentTransport(input.providerKind, outboundWireOf(request)) },
    history as ProxyMessage[],
  );
  return { transport: line.transport, request };
}

const EXPORT_MODELS = {
  openAI: process.env.ORIVEO_TEST_EXPORT_MODEL_OPENAI ?? 'gpt-4.1-mini',
  anthropic: process.env.ORIVEO_TEST_EXPORT_MODEL_ANTHROPIC ?? 'claude-haiku-4-5',
  gemini: process.env.ORIVEO_TEST_EXPORT_MODEL_GEMINI ?? 'gemini-2.5-flash',
  openRouter: process.env.ORIVEO_TEST_EXPORT_MODEL_OPENROUTER ?? 'openai/gpt-4.1-mini',
};

const DIRECT_LINES: Array<{
  name: string;
  providerKind: Provider['kind'];
  modelID: string;
  metadataModel?: Record<string, unknown>;
  transport: AttachmentTransport;
  block: NativeFileBlock;
}> = [
  // For the official OpenAI API, metadata's model.transport selects Responses.
  { name: 'openai-responses', providerKind: 'openAI', modelID: EXPORT_MODELS.openAI, metadataModel: { transport: 'openai_responses' }, transport: 'openai_responses', block: 'input_file' },
  { name: 'anthropic-messages', providerKind: 'anthropic', modelID: EXPORT_MODELS.anthropic, transport: 'anthropic_messages', block: 'document' },
  { name: 'gemini-generate', providerKind: 'gemini', modelID: EXPORT_MODELS.gemini, transport: 'gemini_generate', block: 'inline_data' },
  { name: 'openrouter-chat', providerKind: 'openRouter', modelID: EXPORT_MODELS.openRouter, transport: 'openrouter_chat', block: 'file' },
];

const CREDENTIAL_HEADERS = new Set(['authorization', 'x-api-key', 'x-goog-api-key', 'api-key']);

describe('native file upload on direct connection lines', () => {
  it.each(DIRECT_LINES)('$name: the production builder body has a native file block and no text block for the file', async (line) => {
    const model = catalogModel(line.modelID);
    const { transport, request } = await outboundRequest({
      providerKind: line.providerKind,
      model,
      metadata: officialMetadata(line.providerKind, line.modelID, line.metadataModel),
    });
    expect(transport).toBe(line.transport);
    expect(findNativeFileBlock(request.body)).toBe(line.block);
    const wire = JSON.stringify(request.body);
    expect(wire).toContain(PDF_BASE64);
    expect(wire).toContain(QUESTION);
    expect(wire).not.toContain('ATTACHMENT_FILE');
    expect(wire).not.toContain('[File:');
    expect(wire).not.toContain('[file:');
    // The file was not treated as an image
    expect(wire).not.toContain('"image_url":{"url":"data:application/pdf');

    const exportDir = process.env.ORIVEO_TEST_EXPORT_DIR;
    if (exportDir) {
      mkdirSync(exportDir, { recursive: true });
      const url = new URL(request.url);
      writeFileSync(path.join(exportDir, `web-${line.name}.json`), `${JSON.stringify({
        line: line.transport,
        method: 'POST',
        origin: url.origin,
        path: url.pathname,
        query: Object.fromEntries([...url.searchParams].filter(([name]) => name.toLowerCase() !== 'key')),
        headers: Object.fromEntries(
          Object.entries(request.headers).filter(([name]) => !CREDENTIAL_HEADERS.has(name.toLowerCase())),
        ),
        body: request.body,
      }, null, 2)}\n`);
    }
  });

  it('a Gemini text PDF (pdfNativeDefault) goes native too; an OpenAI text PDF is injected as text', async () => {
    const textPdf = markerPdfAttachment({ extractionErrorCode: undefined, base64Data: 'extracted body', extractedTotalLines: 1 });
    const gemini = await outboundRequest({
      providerKind: 'gemini',
      model: catalogModel('gemini-x', { pdfNativeDefault: true }),
      metadata: officialMetadata('gemini', 'gemini-x'),
      attachment: textPdf,
    });
    expect(findNativeFileBlock(gemini.request.body)).toBe('inline_data');

    const openai = await outboundRequest({
      providerKind: 'openAI',
      model: catalogModel('gpt-x'),
      metadata: officialMetadata('openAI', 'gpt-x', { transport: 'openai_responses' }),
      attachment: textPdf,
    });
    expect(findNativeFileBlock(openai.request.body)).toBeNull();
    expect(JSON.stringify(openai.request.body)).toContain('<FILE_NAME>marker.pdf</FILE_NAME>');
  });
});

describe('lines without a native block: the same attachment is injected as text', () => {
  function expectTextInjected(wire: string, wrapper: 'xml' | 'markdown') {
    expect(wire).toContain(wrapper === 'xml' ? '<FILE_NAME>marker.pdf</FILE_NAME>' : '## Attachment 1: marker.pdf');
    expect(wire).toContain('scanned_pdf');
    expect(wire).not.toContain('[File:');
    expect(wire).not.toContain('[file:');
    expect(wire).not.toContain(PDF_BASE64);
    expect(wire).not.toContain('data:application/pdf');
  }

  it('OpenAI Chat Completions (metadata did not put the model on Responses)', async () => {
    const { transport, request } = await outboundRequest({
      providerKind: 'openAI',
      model: catalogModel('gpt-chat'),
      metadata: officialMetadata('openAI', 'gpt-chat'),
    });
    expect(transport).toBe('openai_chat');
    expect(request.url).toMatch(/\/chat\/completions$/);
    expect(findNativeFileBlock(request.body)).toBeNull();
    expectTextInjected(JSON.stringify(request.body), 'xml');
  });

  it('Moonshot (both the /api/chat/stream line and the direct browser line)', async () => {
    const model = catalogModel('kimi-x');
    const { transport, request } = await outboundRequest({
      providerKind: 'moonshot', model, metadata: officialMetadata('moonshot', 'kimi-x'),
    });
    expect(transport).toBe('moonshot_chat');
    expectTextInjected(JSON.stringify(request.body), 'markdown');

    const direct = await resolveAttachmentLine({
      provider: provider('moonshot', { baseURLText: 'https://api.moonshot.cn/v1' }), model,
    });
    expect(direct).toEqual({ transport: 'moonshot_browser_direct', toolLoop: false, exact: true });
    const history = await buildChatHistory([userMessage([markerPdfAttachment()])], model, direct);
    expectTextInjected(JSON.stringify(buildMoonshotMessages(history as never)), 'markdown');
  });

  it('Relay Chat Completions (the image adapter one)', async () => {
    const model = catalogModel('relay-model');
    const line = await resolveAttachmentLine({
      provider: provider('relay'), model, streamOptions: { relayTransport: 'openai_chat_completions' },
    });
    expect(line.transport).toBe('relay_openai_chat');
    const history = await buildChatHistory([userMessage([markerPdfAttachment()])], model, line);
    const content = history[0].content;
    const wire = JSON.stringify(typeof content === 'string' ? content : convertToOpenAIChatParts(content));
    expectTextInjected(wire, 'xml');
    expect(wire).not.toContain('image_url');
  });
});

describe('relay and subscription lines: routing is the same as direct, falling back to text after a rejection', () => {
  const relayModel = catalogModel('claude-x', { pdfNativeDefault: true });

  async function relayAnthropicParts(attachment: Attachment, model = relayModel) {
    const line = await resolveAttachmentLine({
      provider: provider('relay'), model, streamOptions: { relayTransport: 'anthropic_messages' },
    });
    expect(line).toEqual({ transport: 'relay_anthropic_messages', toolLoop: false, exact: true });
    const history = await buildChatHistory([userMessage([attachment])], model, line);
    const content = history[0].content;
    return typeof content === 'string' ? content : convertToAnthropicParts(content);
  }

  const textPdf = () => markerPdfAttachment({
    extractionErrorCode: undefined, base64Data: 'extracted body', extractedTotalLines: 1,
  });

  it('Relay Anthropic: a text PDF follows the model pdfNativeDefault (the same rule as direct)', async () => {
    expect(findNativeFileBlock(await relayAnthropicParts(textPdf()))).toBe('document');
    const parts = await relayAnthropicParts(textPdf(), catalogModel('claude-y'));
    expect(findNativeFileBlock(parts)).toBeNull();
    expect(JSON.stringify(parts)).toContain('extracted body');
  });

  it('Relay Anthropic: a scanned PDF goes as a native document block', async () => {
    const parts = await relayAnthropicParts(markerPdfAttachment());
    expect(findNativeFileBlock(parts)).toBe('document');
    expect(JSON.stringify(parts)).not.toContain('ATTACHMENT_FILE');
  });

  it('a relay model that missed the official catalog has no allowlist: always injected as text', async () => {
    const parts = await relayAnthropicParts(markerPdfAttachment(), catalogModel('unknown', { nativeFileMimes: undefined }));
    expect(findNativeFileBlock(parts)).toBeNull();
    expect(JSON.stringify(parts)).toContain('<FILE_NAME>marker.pdf</FILE_NAME>');
  });

  it('a relay request with tools goes through /api/chat/stream as Chat Completions: always text', async () => {
    const line = await resolveAttachmentLine({
      provider: provider('relay'), model: relayModel,
      streamOptions: { relayTransport: 'anthropic_messages' }, toolLoop: true,
    });
    expect(line.transport).toBe('relay_openai_chat');
  });

  it('subscriptions: Codex takes the declared subscription line; Grok with no declared protocol cannot be determined', async () => {
    expect(await resolveAttachmentLine({
      provider: provider('openAI', { authMode: 'subscription' }), model: catalogModel('gpt-sub'),
    })).toEqual({ transport: 'openai_subscription_codex', toolLoop: false, exact: true });
    expect(await resolveAttachmentLine({
      provider: provider('grok', { authMode: 'subscription' }), model: catalogModel('grok-sub', { upstreamApiBackend: 'responses' }),
    })).toEqual({ transport: 'grok_subscription_responses', toolLoop: false, exact: true });
    expect(await resolveAttachmentLine({
      provider: provider('grok', { authMode: 'subscription' }), model: catalogModel('grok-sub'),
    })).toEqual({ transport: 'grok_subscription_chat', toolLoop: false, exact: false });
  });
});

describe('tool leg', () => {
  it('the OpenRouter tool leg keeps the native file block; the OpenAI Responses tool leg degrades to text', async () => {
    const orModel = catalogModel('openai/gpt-x');
    const orLine = await resolveAttachmentLine({
      provider: provider('openRouter'), model: orModel, toolLoop: true,
      officialMetadata: async () => officialMetadata('openRouter', 'openai/gpt-x'),
    });
    expect(orLine).toEqual({ transport: 'openrouter_chat', toolLoop: true, exact: true });
    const orHistory = await buildChatHistory([userMessage([markerPdfAttachment()])], orModel, orLine);
    const orRequest = await buildProviderRequest({
      providerKind: 'openRouter', apiKey: 'k', modelID: orModel.id,
      messages: orHistory as ProxyMessage[], tools: [TOOL], toolChoice: 'auto',
    }, async () => officialMetadata('openRouter', 'openai/gpt-x'));
    expect(findNativeFileBlock(orRequest.body)).toBe('file');
    expect(JSON.stringify(orRequest.body)).not.toContain('ATTACHMENT_FILE');

    const oaModel = catalogModel('gpt-x');
    const oaMetadata = officialMetadata('openAI', 'gpt-x', { transport: 'openai_responses' });
    const oaLine = await resolveAttachmentLine({
      provider: provider('openAI'), model: oaModel, toolLoop: true, officialMetadata: async () => oaMetadata,
    });
    expect(oaLine).toEqual({ transport: 'openai_responses', toolLoop: true, exact: true });
    const oaHistory = await buildChatHistory([userMessage([markerPdfAttachment()])], oaModel, oaLine);
    const oaRequest = await buildProviderRequest({
      providerKind: 'openAI', apiKey: 'k', modelID: oaModel.id,
      messages: oaHistory as ProxyMessage[], tools: [TOOL], toolChoice: 'auto',
    }, async () => oaMetadata);
    expect(findNativeFileBlock(oaRequest.body)).toBeNull();
    expect(JSON.stringify(oaRequest.body)).toContain('<FILE_NAME>marker.pdf</FILE_NAME>');
  });
});

describe('line cannot be determined', () => {
  it('catalog not loaded: falls back to the text line and is marked inexact', async () => {
    const line = await resolveAttachmentLine({
      provider: provider('openAI'), model: catalogModel('gpt-x'), officialMetadata: async () => null,
    });
    expect(line).toEqual({ transport: 'openai_chat', toolLoop: false, exact: false });
  });
});
