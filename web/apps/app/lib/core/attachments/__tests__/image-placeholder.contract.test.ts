/**
  * Image placeholder for text-only wires (attachment delivery contract; capability spec on text-only wires).
 *
  * The placeholder literal is shared by all three clients and the shared fixture is authoritative: each case asserts that the wire's declared placeholder == the fixture bytes, and that the wire's
  * production request builder, given "one image + one sentence", produces a request body that contains the placeholder line and no image block at all.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
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

interface PlaceholderCase {
  id: string;
  placeholder: string;
  routes: { web: AttachmentTransport };
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

/** Outbound artifact of each wire's production builder for one image + one sentence. */
const BUILT_BODY: Record<string, () => unknown> = {
  deepseek_chat: () => buildDeepSeekRequest(params('deepseek'), null, false).body,
  relay_llamacpp_native: () => buildLlamaCppNativePrompt(IMAGE_MESSAGE as never),
  minimax_chat: () => buildMiniMaxRequest(params('miniMax'), null, null).body,
  minimax_anthropic_messages: () =>
    buildMiniMaxAnthropicMessagesRequest(params('miniMax'), MINIMAX_ANTHROPIC_ROUTE as never).body,
  gemini_interactions: () =>
    buildGeminiInteractionsRequest(params('gemini'), GEMINI_INTERACTIONS_ROUTE as never).body,
  oriveo_free: () => freeProxyBody(IMAGE_MESSAGE),
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
});

describe('tool leg (MCP / library) uses the same wire placeholder as a normal send', () => {
  const TOOL = {
    type: 'function' as const,
    function: { name: 'library_search', description: 'Search', parameters: { type: 'object', properties: {} } },
  };
  const placeholderOf = (id: string) => FIXTURE.cases.find((entry) => entry.id === id)!.placeholder;

  for (const [id, providerKind] of [['deepseek_chat', 'deepseek'], ['minimax_chat', 'miniMax']] as const) {
    it(`TOOL-LEG-IMAGE-PLACEHOLDER-${id} production tool leg request body contains the fixture placeholder and no image_url`, async () => {
      // When /api/chat/stream carries tools, dispatch wraps the tool leg wire adapter (same construction as route.ts).
      const request = await buildProviderRequest({
        ...params(providerKind), tools: [TOOL], toolChoice: 'auto',
      }, async () => null);
      const serialized = JSON.stringify(request.body);
      expect(serialized).toContain('"tools"');
      expect(serialized).toContain(placeholderOf(id));
      expect(serialized).toContain('what is in this picture');
      expect(findImageBlock(request.body)).toBeNull();
    });
  }
});
