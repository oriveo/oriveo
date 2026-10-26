/**
 * Video placeholders for wires that cannot send video (shared fixture media-outbound.v1.json, videoPlaceholderCases).
 *
 * One placeholder line per video, the literal = the image placeholder of the same wire with Image replaced by Video; no file name,
 * and no video block or data URL in the body. The body is what the production request builder produces for "one sentence + N videos".
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER,
  type AttachmentTransport,
  attachmentTransportProfile,
} from '@oriveo/core/providers/attachment-transport';
import { buildAnthropicRequest } from '@oriveo/core/providers/request-builders/anthropic';
import { buildDeepSeekRequest } from '@oriveo/core/providers/request-builders/deepseek';
import { buildMiniMaxRequest } from '@oriveo/core/providers/request-builders/minimax';
import { buildMiniMaxAnthropicMessagesRequest } from '@oriveo/core/providers/request-builders/minimax-anthropic-messages';
import type { ProxyMessage } from '@oriveo/core/providers/request-builders/runtime';
import type { RequestParams } from '@oriveo/core/providers/request-builders/types';
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import { buildOutboundChatHistory, filterOutboundAttachments } from '../../chat/outbound-history';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../chat/stream-options';
import { resolveInputCapabilityProjections } from '../../capability/truth/input-truth-adapter';
import { buildChatHistory } from '../../../utils/chat-stream-utils';

interface VideoPlaceholderCase {
  id: string;
  imageCase: string;
  videos: number;
  placeholder: string;
  expectLines: number;
  separator: string;
  routes: { web: AttachmentTransport | null };
}

interface NativeFileCase {
  id: string;
  connection: 'official';
  routeNativeFiles: boolean;
  fileInputOutbound: 'native_part' | 'placeholder';
  extractedText: boolean;
  expect: { nativeFilePart: boolean; textInjected: boolean; placeholderLine: boolean };
}

const FIXTURE = JSON.parse(readFileSync(
  resolve(__dirname, '../../../../../../../shared/test-fixtures/attachments/media-outbound.v1.json'),
  'utf8',
)) as { v: number; videoPlaceholderCases: VideoPlaceholderCase[]; nativeFileCases: NativeFileCase[] };

const IMAGE_FIXTURE = JSON.parse(readFileSync(
  resolve(__dirname, '../../../../../../../shared/test-fixtures/attachments/image-placeholder.v1.json'),
  'utf8',
)) as { cases: Array<{ id: string; placeholder: string }> };

/** Attachment file name: the video part of a ProxyMessage carries no file name, and it must not appear in the outbound body either. */
const VIDEO_FILE_NAME = 'holiday-clip.mp4';
const VIDEO_DATA_URL = 'data:video/mp4;base64,AAAAIGZ0eXBpc29t';

function videoMessage(videos: number): ProxyMessage[] {
  return [{
    role: 'user',
    content: [
      { type: 'text', text: 'what happens in this clip?' },
      ...Array.from({ length: videos }, () => ({ type: 'video_url' as const, video_url: { url: VIDEO_DATA_URL } })),
    ],
  }];
}

const MINIMAX_ANTHROPIC_ROUTE = {
  protocol: 'anthropic_messages', endpointClass: 'messages', path: '/anthropic/v1/messages',
  requestMapper: 'anthropic_messages', authHeader: 'x-api-key', headers: {},
};

async function builtBody(transport: AttachmentTransport, messages: ProxyMessage[]): Promise<unknown> {
  const params = (providerKind: RequestParams['providerKind']): RequestParams =>
    ({ providerKind, apiKey: 'k', modelID: 'm', messages });
  switch (transport) {
    case 'deepseek_chat': return buildDeepSeekRequest(params('deepseek'), null, false).body;
    case 'minimax_chat': return buildMiniMaxRequest(params('miniMax'), null, null).body;
    case 'minimax_anthropic_messages':
      return buildMiniMaxAnthropicMessagesRequest(params('miniMax'), MINIMAX_ANTHROPIC_ROUTE as never).body;
    default: throw new Error(`no outbound probe for ${transport}`);
  }
}

const VIDEO_BLOCK_KEYS = new Set(['video_url', 'input_video', 'video']);

function findVideoBlock(value: unknown): string | null {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findVideoBlock(item);
      if (found) return found;
    }
    return null;
  }
  if (!value || typeof value !== 'object') return null;
  const record = value as Record<string, unknown>;
  if (typeof record.type === 'string' && VIDEO_BLOCK_KEYS.has(record.type)) return record.type;
  for (const [key, child] of Object.entries(record)) {
    if (VIDEO_BLOCK_KEYS.has(key)) return key;
    const found = findVideoBlock(child);
    if (found) return found;
  }
  return null;
}

function countOccurrences(haystack: string, needle: string): number {
  return haystack.split(needle).length - 1;
}

// The connection support table is not loaded in tests; provide one where the connection takes video, so this turn's video gate looks only at the video_input projection.
vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../metadata/metadata-client')>()),
  getProviderAttachmentSupport: () => ({ image: true, nativeFile: false, textFileInline: true }),
}));

afterEach(() => {
  vi.restoreAllMocks();
});

describe('wires that cannot send video write a video placeholder = shared fixture', () => {
  it('fixture v1, video placeholder = the image placeholder of the same wire with Image -> Video', () => {
    expect(FIXTURE.v).toBe(1);
    for (const entry of FIXTURE.videoPlaceholderCases) {
      const image = IMAGE_FIXTURE.cases.find((candidate) => candidate.id === entry.imageCase);
      expect(image, entry.id).toBeDefined();
      expect(entry.placeholder).toBe(image!.placeholder.replace('Image', 'Video'));
      expect(entry.separator, entry.id).toBe('\n\n');
    }
  });

  for (const entry of FIXTURE.videoPlaceholderCases) {
    const transport = entry.routes.web;
    if (!transport) continue;
    it(`MEDIA-OUTBOUND-${entry.id} ${entry.videos} video(s) -> production outbound has ${entry.expectLines} placeholder line(s) and no video block`, async () => {
      expect(attachmentTransportProfile(transport).videoPlaceholderText).toBe(entry.placeholder);

      const body = await builtBody(transport, videoMessage(entry.videos));
      const serialized = JSON.stringify(body);
      expect(serialized).toContain('what happens in this clip?');
      expect(countOccurrences(serialized, entry.placeholder)).toBe(entry.expectLines);
      expect(findVideoBlock(body)).toBeNull();
      expect(serialized).not.toContain('data:video');
      expect(serialized).not.toContain(VIDEO_FILE_NAME);
    });
  }

  it('WEB-MEDIA-OUTBOUND-minimax_anthropic_messages same placeholder as MiniMax, no data URL in the body', async () => {
    const placeholder = FIXTURE.videoPlaceholderCases.find((entry) => entry.id === 'video_minimax_chat')!.placeholder;
    expect(attachmentTransportProfile('minimax_anthropic_messages').videoPlaceholderText).toBe(placeholder);
    const body = await builtBody('minimax_anthropic_messages', videoMessage(1));
    const serialized = JSON.stringify(body);
    expect(countOccurrences(serialized, placeholder)).toBe(1);
    expect(serialized).not.toContain('data:video');
    expect(findVideoBlock(body)).toBeNull();
  });

  it('WEB-MEDIA-OUTBOUND-current_turn_minimax_anthropic the current turn video picks the wire via streamOptions: outbound cleanup writes the wire placeholder, the builder has no video block', async () => {
    const placeholder = attachmentTransportProfile('minimax_anthropic_messages').videoPlaceholderText!;
    const model = {
      id: 'MiniMax-M2', name: 'MiniMax-M2', capabilities: ['text'], reasoningModeAvailable: false,
      isAvailable: true, isDefault: true, priceTier: '$', transport: 'anthropic_messages',
      capabilityControls: { video_input: { state: 'unavailable' } },
    } as unknown as AIModel;
    const provider = {
      id: 'official-miniMax', kind: 'miniMax', status: { kind: 'connected' }, models: [model],
      catalogModels: [{ ...model }], apiKey: '', apiKeyPreview: '',
    } as unknown as Provider;
    const turn = {
      id: 'u-video', role: 'user', text: 'what happens in this clip?', providerKind: 'miniMax', providerName: 'P',
      modelName: 'm', estimatedCost: 0, state: 'delivered', createdAt: '2026-10-20T00:00:00Z',
      attachments: [{ id: 'vid-1', kind: 'video', fileName: VIDEO_FILE_NAME, mimeType: 'video/mp4', base64Data: 'AAAA' }],
    } as unknown as ChatMessage;
    const streamOptions = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);

    const messages = filterOutboundAttachments({ messages: [turn], currentTurnId: turn.id, provider, model, streamOptions });
    expect(messages[0].attachments).toBeUndefined();
    const separator = FIXTURE.videoPlaceholderCases.find((entry) => entry.id === 'video_minimax_chat')!.separator;
    expect(messages[0].text).toBe(`what happens in this clip?${separator}${placeholder}`);

    const history = await buildOutboundChatHistory({}, { messages, provider, model, streamOptions }) as ProxyMessage[];
    const body = await builtBody('minimax_anthropic_messages', history);
    const serialized = JSON.stringify(body);
    expect(countOccurrences(serialized, placeholder)).toBe(1);
    expect(findVideoBlock(body)).toBeNull();
    expect(serialized).not.toContain('data:video');
    expect(serialized).not.toContain(VIDEO_FILE_NAME);
  });

  it('WEB-MEDIA-OUTBOUND-anthropic_official a wire that sends images natively and has no image placeholder: video gets the generic placeholder, no data URL in the body', () => {
    expect(TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER).toBe('[Video omitted: this route sends text only]');
    const body = buildAnthropicRequest(
      { providerKind: 'anthropic', apiKey: 'k', modelID: 'm', messages: videoMessage(1) } as RequestParams,
      null,
      null,
    ).body;
    const serialized = JSON.stringify(body);
    expect(serialized).toContain('what happens in this clip?');
    expect(countOccurrences(serialized, '[Video omitted: this route sends text only]')).toBe(1);
    expect(findVideoBlock(body)).toBeNull();
    expect(serialized).not.toContain('data:video');
    expect(serialized).not.toContain(VIDEO_FILE_NAME);
  });
});

/* -- On an official connection the native file block goes out only by the file_input projection (nativeFileCases) -- */

const FILE_NAME = 'quarterly-report.pdf';
/** Original bytes (base64): appear only in a native file block. */
const PDF_ORIGINAL_BASE64 = 'JVBERi0xLjQKT1JJVkVPLU5BVElWRS1NQVJLRVI=';
/** Extracted text: appears in the body only through text injection. */
const EXTRACTED_TEXT = 'ORIVEO-EXTRACTED-MARKER-4821';
const FILE_PLACEHOLDER_PREFIX = '[File omitted';

/** Official connection: a wire that takes native files -> Anthropic messages (document block); one that does not -> DeepSeek chat. */
function officialFileRoute(routeNativeFiles: boolean): { kind: Provider['kind']; transport: AttachmentTransport } {
  return routeNativeFiles
    ? { kind: 'anthropic', transport: 'anthropic_messages' }
    : { kind: 'deepSeek', transport: 'deepseek_chat' };
}

async function nativeFileOutboundBody(entry: NativeFileCase): Promise<unknown> {
  const route = officialFileRoute(entry.routeNativeFiles);
  const model = {
    id: 'm', name: 'm', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true,
    priceTier: '$', nativeFileMimes: ['application/pdf'], pdfNativeDefault: true,
    capabilityControls: {
      file_input: entry.fileInputOutbound === 'native_part'
        ? { state: 'auto_available' }
        : { state: 'unavailable', reasonCode: 'model_capability_absent' },
    },
  } as unknown as AIModel;
  const provider = {
    id: `official-${route.kind}`, kind: route.kind, status: { kind: 'connected' }, models: [model],
    catalogModels: [{ ...model }], apiKey: 'k', apiKeyPreview: 'k',
  } as unknown as Provider;
  const turn = {
    id: 'u-file', role: 'user', text: 'summarize the attached report', providerKind: route.kind, providerName: 'P',
    modelName: 'm', estimatedCost: 0, state: 'delivered', createdAt: '2026-10-20T00:00:00Z',
    attachments: [{
      id: 'file-1', kind: 'file', fileName: FILE_NAME, mimeType: 'application/pdf',
      originalBase64Data: PDF_ORIGINAL_BASE64,
      ...(entry.extractedText ? { base64Data: EXTRACTED_TEXT } : { extractionErrorCode: 'scanned_pdf' }),
    }],
  } as unknown as ChatMessage;
  // Production approach: the projection and the outbound build share one copy (an official connection takes file_input).
  const projections = resolveInputCapabilityProjections(provider, model, undefined);
  expect(projections?.file_input.outbound, entry.id).toBe(entry.fileInputOutbound);
  const history = await buildChatHistory(
    [turn], model, { transport: route.transport }, projections?.vision_input ?? null, projections?.file_input ?? null,
  ) as ProxyMessage[];
  const params = (providerKind: RequestParams['providerKind']): RequestParams =>
    ({ providerKind, apiKey: 'k', modelID: 'm', messages: history });
  return route.transport === 'anthropic_messages'
    ? buildAnthropicRequest(params('anthropic'), null, null).body
    : buildDeepSeekRequest(params('deepseek'), null, false).body;
}

describe('on an official connection the native file block goes out only by the file_input projection = shared fixture', () => {
  for (const entry of FIXTURE.nativeFileCases) {
    it(`MEDIA-OUTBOUND-${entry.id} wire native=${entry.routeNativeFiles} projection=${entry.fileInputOutbound}`, async () => {
      const serialized = JSON.stringify(await nativeFileOutboundBody(entry));
      expect(serialized).toContain('summarize the attached report');
      expect(serialized.includes(PDF_ORIGINAL_BASE64), `${entry.id} nativeFilePart`).toBe(entry.expect.nativeFilePart);
      expect(serialized.includes(EXTRACTED_TEXT), `${entry.id} textInjected`).toBe(entry.expect.textInjected);
      expect(serialized.includes(FILE_PLACEHOLDER_PREFIX), `${entry.id} placeholderLine`).toBe(entry.expect.placeholderLine);
    });
  }
});
