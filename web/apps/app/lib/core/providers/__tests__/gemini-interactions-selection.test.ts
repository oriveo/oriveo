/**
 * Gemini Interactions production route selection (same-named cases on all three clients).
 *
 * Fixtures are read-only: shared/test-fixtures/provider-toolcall/gemini_interactions.selection.v1.json;
 * the reasoning recipe comes from reasoning_recipe in gemini_interactions.request-golden.v1.json,
 * and the web recipe from gemini.interactions.web.v1 in the Server registry. Everything goes through the production dispatch entry
 * buildProviderRequest, never calling the builder directly. Fixture messages are first converted to this client's ChatMessage, then go through the production outbound history
 * build (buildChatHistory) and video detection (outboundHistoryHasVideo) to get the request.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import type { ChatMessage } from '@oriveo/shared';
import { outboundHistoryHasVideo, resolveAttachmentLineForMessages } from '../../attachments/attachment-transport-resolver';
import { buildChatHistory } from '../../../utils/chat-stream-utils';

const repoRoot = resolve(process.cwd(), '../../..');
const fixtureDir = resolve(repoRoot, 'shared/test-fixtures/provider-toolcall');
const selection = JSON.parse(readFileSync(resolve(fixtureDir, 'gemini_interactions.selection.v1.json'), 'utf8')) as Selection;
const golden = JSON.parse(readFileSync(resolve(fixtureDir, 'gemini_interactions.request-golden.v1.json'), 'utf8')) as { reasoning_recipe: Record<string, unknown> & { id: string } };
const registry = JSON.parse(readFileSync(
  resolve(repoRoot, 'shared/capabilityrecipe/capability_runtime.v1.json'),
  'utf8',
)) as { schemaVersion: number; recipes: Record<string, unknown>; sourceIndex: Record<string, unknown>; controlDefinitions: Record<string, unknown> };

interface SelectionPart { type: 'text' | 'video'; text?: string; mime_type?: string; data?: string | null }
interface SelectionCase {
  id: string;
  input: {
    web: boolean;
    reasoning: 'off' | 'low' | 'balanced' | 'deep' | null;
    messages: Array<{ role: 'user' | 'assistant'; parts: SelectionPart[] }>;
  };
  expected: {
    route: 'interactions' | 'generate_content';
    path_suffix?: string;
    generation_config?: Record<string, unknown> | null;
    tools?: unknown[];
    video_inline?: { mimeType: string; data: string } | null;
  };
}
interface Selection {
  model: { providerKind: string; modelId: string; transport: string };
  capability_controls: Record<string, unknown>;
  cases: SelectionCase[];
}

function metadata() {
  const { model } = selection;
  return {
    version: 2,
    updatedAt: '2026-10-13T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    capabilityRuntime: {
      schemaVersion: registry.schemaVersion,
      revision: 'gemini-interactions-selection',
      generatedAt: '2026-10-13T00:00:00Z',
      // Server delivers gemini.interactions.reasoning.v1; this client installs the golden one (field-by-field identical to the Server's same id) into the registry.
      recipes: { ...registry.recipes, [golden.reasoning_recipe.id]: golden.reasoning_recipe },
      controlDefinitions: registry.controlDefinitions,
      sourceIndex: registry.sourceIndex,
    },
    providers: {
      [model.providerKind]: {
        resolveMap: { [model.modelId]: model.modelId },
        models: { [model.modelId]: { transport: model.transport, capabilityControls: selection.capability_controls } },
      },
    },
  } as never;
}

/** Fixture message -> this client's ChatMessage: a video part is a kind=video attachment, and data=null means the bytes are not loaded (no base64Data). */
function toChatMessages(item: SelectionCase): ChatMessage[] {
  return item.input.messages.map((message, index) => ({
    id: `m${index}`,
    role: message.role,
    text: message.parts.filter((part) => part.type === 'text').map((part) => part.text ?? '').join('\n'),
    attachments: message.parts.filter((part) => part.type === 'video').map((part, at) => ({
      id: `v${index}-${at}`, kind: 'video', fileName: 'clip.mp4', mimeType: part.mime_type ?? 'video/mp4',
      ...(part.data ? { base64Data: part.data } : {}),
    })),
  })) as unknown as ChatMessage[];
}

async function send(item: SelectionCase) {
  const chat = toChatMessages(item);
  const hasVideo = await outboundHistoryHasVideo(chat);
  return buildProviderRequest({
    providerKind: selection.model.providerKind as never,
    apiKey: 'key',
    modelID: selection.model.modelId,
    messages: await buildChatHistory(chat),
    stream: true,
    options: {
      capabilityPreferences: {
        web: item.input.web ? 'automatic' : 'off',
        ...(item.input.reasoning ? { reasoningIntent: item.input.reasoning } : {}),
      },
      ...(hasVideo ? { outboundHistoryHasVideo: true } : {}),
    },
  }, async () => metadata());
}

function keysAnywhere(value: unknown, out = new Set<string>()): Set<string> {
  if (Array.isArray(value)) value.forEach((item) => keysAnywhere(item, out));
  else if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) { out.add(key); keysAnywhere(child, out); }
  }
  return out;
}

describe('Gemini Interactions selection — production dispatch', () => {
  for (const item of selection.cases) {
    it(item.id, async () => {
      const request = await send(item);
      const body = JSON.parse(JSON.stringify(request.body)) as Record<string, any>;
      const path = new URL(request.url).pathname;
      const expected = item.expected;
      if (expected.route === 'interactions') {
        expect(path.endsWith(expected.path_suffix!), path).toBe(true);
        expect(request.responseAdapter).toBe('gemini_interactions');
        if (expected.generation_config === null) expect(Object.hasOwn(body, 'generation_config')).toBe(false);
        else expect(body.generation_config).toEqual(expected.generation_config);
        expect(body.tools).toEqual(expected.tools);
        return;
      }
      expect(path).toContain(':streamGenerateContent');
      for (const key of ['input', 'store', 'generation_config', 'tools']) expect(Object.hasOwn(body, key), key).toBe(false);
      const keys = keysAnywhere(body);
      for (const key of ['thinking_summaries', 'thinking_level']) expect(keys.has(key), key).toBe(false);
      // On the generateContent line the gemini_interactions recipe does not enter the body and records no execution fact.
      for (const ref of request.capabilityExecution?.recipeRefs ?? []) {
        expect(ref.startsWith('gemini.interactions.'), ref).toBe(false);
      }
      if (expected.video_inline) {
        const parts = (body.contents as Array<{ parts: Array<{ inlineData?: unknown }> }>).flatMap((content) => content.parts);
        expect(parts.filter((part) => part.inlineData)).toEqual([{ inlineData: expected.video_inline }]);
      } else {
        expect(JSON.stringify(body.contents)).not.toContain('inlineData');
      }
    });
  }
});

describe('Gemini Interactions selection — attachment line follows the same video rule', () => {
  const file = { id: 'f', kind: 'file', fileName: 'a.pdf', mimeType: 'application/pdf' };
  const video = { id: 'v', kind: 'video', fileName: 'a.mp4', mimeType: 'video/mp4', base64Data: 'AAAAIGZ0eXBpc29t' };
  const videoWithoutData = { id: 'v0', kind: 'video', fileName: 'b.mp4', mimeType: 'video/mp4' };
  const line = (attachments: unknown[][]) => resolveAttachmentLineForMessages(
    attachments.map((items, index) => ({ id: `m${index}`, role: index % 2 === 0 ? 'user' : 'assistant', text: 'x', attachments: items })) as unknown as ChatMessage[],
    {
      provider: { kind: 'gemini', authMode: 'apiKey', baseURLText: '' } as never,
      model: { id: selection.model.modelId } as never,
      streamOptions: { capabilityPreferences: { web: 'automatic' } },
      officialMetadata: async () => metadata(),
    },
  );

  it('history without video resolves the Interactions line', async () => {
    expect((await line([[file]]))?.transport).toBe('gemini_interactions');
  });

  it('video anywhere in history resolves the generateContent line', async () => {
    expect((await line([[video], [], [file]]))?.transport).toBe('gemini_generate');
  });

  it('video without loaded bytes still counts as video', async () => {
    expect((await line([[videoWithoutData], [], [file]]))?.transport).toBe('gemini_generate');
  });
});
