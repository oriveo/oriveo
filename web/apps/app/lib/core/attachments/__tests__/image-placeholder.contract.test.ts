/**
 * Image placeholder for text-only wires (attachment delivery contract section 10; capability spec on text-only wires).
 *
 * The placeholder literal is shared by all three clients and the shared fixture is authoritative: each case asserts that the wire's declared placeholder == the fixture bytes.
 * Wires without byModel (this client sends text only): the production request builder, given "one image + one sentence", produces a request body that contains the placeholder line and no image block.
 * Wires with byModel go row by row, per (model, server verdict), through the production outbound path (outbound cleanup -> outbound-history -> server builder):
 * native_part gives a body with an image block and no placeholder; placeholder gives only the placeholder line and no image block.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import {
  type AttachmentTransport,
  attachmentTransportProfile,
} from '@oriveo/core/providers/attachment-transport';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import { buildDeepSeekRequest } from '@oriveo/core/providers/request-builders/deepseek';
import { buildGeminiInteractionsRequest } from '@oriveo/core/providers/request-builders/gemini-interactions';
import { buildMiniMaxRequest } from '@oriveo/core/providers/request-builders/minimax';
import { buildMiniMaxAnthropicMessagesRequest } from '@oriveo/core/providers/request-builders/minimax-anthropic-messages';
import type { ProxyMessage } from '@oriveo/core/providers/request-builders/runtime';
import type { RequestParams } from '@oriveo/core/providers/request-builders/types';
import { buildLlamaCppNativePrompt } from '@oriveo/core/providers/relay-orchestrator';
import { buildOutboundChatHistory, filterOutboundAttachments } from '../../chat/outbound-history';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../chat/stream-options';

interface ByModelRow {
  model: string;
  vision: { state: string; reasonCode?: string; wireFamily?: string };
  outbound: 'native_part' | 'placeholder';
}

interface PlaceholderCase {
  id: string;
  placeholder: string;
  routes: { web: AttachmentTransport };
  byModel?: ByModelRow[];
}

const FIXTURE = JSON.parse(readFileSync(
  resolve(__dirname, '../../../../../../../shared/test-fixtures/attachments/image-placeholder.v1.json'),
  'utf8',
)) as { v: number; cases: PlaceholderCase[] };

const IMAGE_MESSAGE: ProxyMessage[] = [{
  role: 'user',
  content: [
    { type: 'text', text: 'what is in this picture' },
    { type: 'image_url', image_url: { url: 'data:image/png;base64,AAAA' } },
  ],
}];

function params(providerKind: RequestParams['providerKind']): RequestParams {
  return { providerKind, apiKey: 'k', modelID: 'm', messages: IMAGE_MESSAGE };
}

const GEMINI_INTERACTIONS_ROUTE = {
  protocol: 'gemini_interactions', endpointClass: 'interactions', path: '/v1beta/interactions',
  requestMapper: 'gemini_interactions',
};
const MINIMAX_ANTHROPIC_ROUTE = {
  protocol: 'anthropic_messages', endpointClass: 'messages', path: '/anthropic/v1/messages',
  requestMapper: 'anthropic_messages', authHeader: 'x-api-key', headers: {},
};

afterEach(() => {
  vi.restoreAllMocks();
});

function imageTurn(text: string): ChatMessage {
  return {
    id: 'u-image', role: 'user', text, providerKind: 'deepseek', providerName: 'P',
    modelName: 'm', estimatedCost: 0, state: 'delivered', createdAt: '2026-10-12T00:00:00Z',
    attachments: [{ id: 'img-1', kind: 'image', fileName: 'cat.png', mimeType: 'image/png', base64Data: 'AAAA' }],
  } as unknown as ChatMessage;
}

/** Fixture row (model, server verdict) -> connection and model objects: official wires put the verdict into capabilityControls as is. */
function connectionOf(transport: AttachmentTransport, row: ByModelRow): { provider: Provider; model: AIModel } {
  const model = {
    id: row.model, name: row.model, capabilities: ['text'], reasoningModeAvailable: false,
    isAvailable: true, isDefault: true, priceTier: '$',
    transport: 'openai_chat_completions', capabilityControls: { vision_input: row.vision },
  } as unknown as AIModel;
  const kind = transport === 'deepseek_chat' ? 'deepseek' : 'miniMax';
  const provider = {
    id: `official-${kind}`, kind, status: { kind: 'connected' }, models: [model], catalogModels: [{ ...model }],
    apiKey: '', apiKeyPreview: '',
  } as unknown as Provider;
  return { provider, model };
}

/** Production outbound path: outbound cleanup (filterOutboundAttachments) -> outbound-history -> the server builder of that wire. */
async function outboundBody(transport: AttachmentTransport, row: ByModelRow, turn: ChatMessage): Promise<unknown> {
  const { provider, model } = connectionOf(transport, row);
  const streamOptions = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);
  const messages = filterOutboundAttachments({ messages: [turn], currentTurnId: turn.id, provider, model, streamOptions });
  const history = await buildOutboundChatHistory({}, { messages, provider, model, streamOptions }) as ProxyMessage[];
  const built: RequestParams = { providerKind: provider.kind as RequestParams['providerKind'], apiKey: 'k', modelID: model.id, messages: history };
  switch (transport) {
    case 'deepseek_chat': return buildDeepSeekRequest(built, null, false).body;
    case 'minimax_chat': return buildMiniMaxRequest(built, null, null).body;
    case 'minimax_anthropic_messages': return buildMiniMaxAnthropicMessagesRequest(built, MINIMAX_ANTHROPIC_ROUTE as never).body;
    default: throw new Error(`no outbound probe for ${transport}`);
  }
}

/** Wires this client sends as text only (no byModel in the fixture): outbound artifact of the production builder for one image + one sentence. */
const BUILT_BODY: Record<string, () => unknown> = {
  relay_llamacpp_native: () => buildLlamaCppNativePrompt(IMAGE_MESSAGE as never),
  gemini_interactions: () =>
    buildGeminiInteractionsRequest(params('gemini'), GEMINI_INTERACTIONS_ROUTE as never).body,
};

const IMAGE_BLOCK_KEYS = new Set(['image_url', 'inlineData', 'inline_data', 'image', 'input_image']);

function findImageBlock(value: unknown): string | null {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findImageBlock(item);
      if (found) return found;
    }
    return null;
  }
  if (!value || typeof value !== 'object') return null;
  const record = value as Record<string, unknown>;
  if (typeof record.type === 'string' && IMAGE_BLOCK_KEYS.has(record.type)) return record.type;
  for (const [key, child] of Object.entries(record)) {
    if (IMAGE_BLOCK_KEYS.has(key)) return key;
    const found = findImageBlock(child);
    if (found) return found;
  }
  return null;
}

describe('text wire image placeholder = shared fixture', () => {
  it('all five fixture cases are present', () => {
    expect(FIXTURE.v).toBe(1);
    expect(FIXTURE.cases.map((entry) => entry.id)).toEqual([
      'deepseek_chat', 'relay_llamacpp_native', 'minimax_chat', 'minimax_web', 'gemini_interactions'
    ]);
  });

  for (const entry of FIXTURE.cases) {
    if (entry.byModel) continue;
    const caseName = `IMAGE-PLACEHOLDER-${entry.id}`;
    it(`${caseName} wire declaration == fixture, production builder outbound has only the placeholder and no image block`, async () => {
      const transport = entry.routes.web;
      expect(attachmentTransportProfile(transport).imagePlaceholderText).toBe(entry.placeholder);

      const build = BUILT_BODY[transport];
      expect(build, `${caseName}: no builder probe for ${transport}`).toBeTypeOf('function');
      const body = await build!();
      const serialized = typeof body === 'string' ? body : JSON.stringify(body);
      expect(serialized).toContain(entry.placeholder);
      expect(serialized).toContain('what is in this picture');
      expect(findImageBlock(body)).toBeNull();
    });
  }

  for (const entry of FIXTURE.cases) {
    for (const row of entry.byModel ?? []) {
      const caseName = `IMAGE-PLACEHOLDER-${entry.id}-${row.model}`;
      it(`${caseName} verdict ${row.vision.state} -> production outbound ${row.outbound}`, async () => {
        const transport = entry.routes.web;
        expect(attachmentTransportProfile(transport).imagePlaceholderText).toBe(entry.placeholder);

        const body = await outboundBody(transport, row, imageTurn('what is in this picture'));
        const serialized = JSON.stringify(body);
        expect(serialized).toContain('what is in this picture');
        if (row.outbound === 'native_part') {
          expect(findImageBlock(body), caseName).not.toBeNull();
          expect(serialized).not.toContain(entry.placeholder);
        } else {
          expect(serialized).toContain(entry.placeholder);
          expect(findImageBlock(body), caseName).toBeNull();
        }
      });
    }
  }
});

describe('tool leg (MCP / library) uses the same outbound rule as a normal send', () => {
  const TOOL = {
    type: 'function' as const,
    function: { name: 'library_search', description: 'Search', parameters: { type: 'object', properties: {} } },
  };
  const placeholderOf = (id: string) => FIXTURE.cases.find((entry) => entry.id === id)!.placeholder;

  for (const [id, providerKind] of [['deepseek_chat', 'deepseek'], ['minimax_chat', 'miniMax']] as const) {
    it(`TOOL-LEG-IMAGE-PLACEHOLDER-${id} production tool leg writes no placeholder of its own: an image part that arrives goes out as image_url`, async () => {
      // When /api/chat/stream carries tools, dispatch wraps the tool leg wire adapter (same construction as route.ts).
      // An image part only exists when the projection said native_part; on placeholder the outbound cleanup already swapped in the placeholder line, the same as a normal send.
      const request = await buildProviderRequest({
        ...params(providerKind), tools: [TOOL], toolChoice: 'auto',
      }, async () => null);
      const serialized = JSON.stringify(request.body);
      expect(serialized).toContain('"tools"');
      expect(serialized).not.toContain(placeholderOf(id));
      expect(serialized).toContain('what is in this picture');
      expect(findImageBlock(request.body)).toBe('image_url');
    });
  }
});
