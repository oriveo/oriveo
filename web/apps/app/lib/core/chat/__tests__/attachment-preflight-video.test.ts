/**
  * How the pre-send check decides about video: it uses the outbound history produced by the same builder as outbound (buildOutboundMessages)
  * to decide; an attachment of video type counts regardless of bytes. The result is carried into the wire dry run as historyHasVideo.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, ChatMessage, Provider } from '@oriveo/shared';

const { probe } = vi.hoisted(() => ({
  probe: vi.fn(async (_input: unknown) => ({ transport: 'gemini_generate', toolLoop: false, exact: false })),
}));
// Only the resolveAttachmentLine used by the pre-check is replaced; the outbound resolveAttachmentLineForMessages is still the production implementation.
vi.mock('../../attachments/attachment-transport-resolver', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../attachments/attachment-transport-resolver')>()),
  resolveAttachmentLine: probe,
}));

import { resolveAttachmentLineForMessages } from '../../attachments/attachment-transport-resolver';
import { findUnsendableAttachmentsBeforeSend } from '../attachment-preflight';
import { buildOutboundMessages, modelPanelOutboundHasVideo } from '../outbound-history';

const repoRoot = resolve(process.cwd(), '../../..');
const selection = JSON.parse(readFileSync(resolve(repoRoot, 'shared/test-fixtures/provider-toolcall/gemini_interactions.selection.v1.json'), 'utf8')) as {
  model: { providerKind: string; modelId: string; transport: string }; capability_controls: Record<string, unknown>;
};
const golden = JSON.parse(readFileSync(resolve(repoRoot, 'shared/test-fixtures/provider-toolcall/gemini_interactions.request-golden.v1.json'), 'utf8')) as { reasoning_recipe: { id: string } };
const registry = JSON.parse(readFileSync(resolve(repoRoot, 'shared/capabilityrecipe/capability_runtime.v1.json'), 'utf8')) as {
  schemaVersion: number; recipes: Record<string, unknown>; sourceIndex: Record<string, unknown>; controlDefinitions: Record<string, unknown>;
};
const metadata = async () => ({
  version: 2, updatedAt: '2026-10-13T00:00:00Z',
  profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
  capabilityRuntime: {
    schemaVersion: registry.schemaVersion, revision: 'preflight', generatedAt: '2026-10-13T00:00:00Z',
    recipes: { ...registry.recipes, [golden.reasoning_recipe.id]: golden.reasoning_recipe },
    controlDefinitions: registry.controlDefinitions, sourceIndex: registry.sourceIndex,
  },
  providers: { gemini: { resolveMap: { [selection.model.modelId]: selection.model.modelId }, models: { [selection.model.modelId]: { transport: selection.model.transport, capabilityControls: selection.capability_controls } } } },
}) as never;

const provider = { id: 'p', kind: 'gemini', authMode: 'apiKey', baseURLText: '' } as unknown as Provider;
const model = { id: selection.model.modelId, capabilities: ['text', 'file', 'video', 'web'] } as unknown as AIModel;
const streamOptions = { capabilityPreferences: { web: 'automatic' as const } };
const file = { id: 'f', kind: 'file', fileName: 'a.pdf', mimeType: 'application/pdf' } as unknown as Attachment;
const video = { id: 'v', kind: 'video', fileName: 'a.mp4', mimeType: 'video/mp4', base64Data: 'AAAA' } as unknown as Attachment;
const videoWithoutData = { id: 'v0', kind: 'video', fileName: 'b.mp4', mimeType: 'video/mp4' } as unknown as Attachment;

function message(id: string, role: 'user' | 'assistant', text: string, extra: Partial<ChatMessage> = {}): ChatMessage {
  return { id, role, text, ...extra } as ChatMessage;
}

function probeFlags() {
  return probe.mock.calls.map((call) => (call[0] as { historyHasVideo?: boolean }).historyHasVideo === true);
}

async function preflight(outboundMessages: ChatMessage[], attachments: Attachment[]) {
  await findUnsendableAttachmentsBeforeSend({ attachments, provider, model, webSearchEnabled: true, outboundMessages });
}

describe('attachment preflight — video judged on the outbound history', () => {
  beforeEach(() => probe.mockClear());

  it('GI_PREFLIGHT_USES_OUTBOUND_HISTORY', async () => {
    // After the failed turn is dropped by outbound normalization, two user messages become adjacent and merge into one (contract sanitize.v1):
    // the earlier message's video attachment is concatenated into the merged message and judged with the outbound history.
    const conversation = [
      message('u0', 'user', 'What happens in this clip?', { attachments: [video] }),
      message('a0', 'assistant', '', { state: 'failed' } as Partial<ChatMessage>),
      message('u1', 'user', 'Summarize the file', { attachments: [file] }),
    ];
    const outbound = buildOutboundMessages({ messages: conversation, currentTurnId: 'u1', provider, model, streamOptions });
    expect(outbound.map((item) => item.id)).toEqual(['u1']);
    expect(outbound[0].attachments?.map((item) => item.id)).toEqual(['v', 'f']);
    const line = await resolveAttachmentLineForMessages(outbound, { provider, model, streamOptions, officialMetadata: metadata });
    expect(line?.transport).toBe('gemini_generate');
    await preflight(outbound, [file]);
    expect(probeFlags()).toEqual([true]);
  });

  it('video still in the outbound history → probe carries it', async () => {
    const conversation = [
      message('u0', 'user', 'What happens in this clip?', { attachments: [videoWithoutData] }),
      message('a0', 'assistant', 'A ball rolls.'),
      message('u1', 'user', 'Summarize the file', { attachments: [file] }),
    ];
    const outbound = buildOutboundMessages({ messages: conversation, currentTurnId: 'u1', provider, model, streamOptions });
    const line = await resolveAttachmentLineForMessages(outbound, { provider, model, streamOptions, officialMetadata: metadata });
    expect(line?.transport).toBe('gemini_generate');
    await preflight(outbound, [file]);
    expect(probeFlags()).toEqual([true]);
  });

  it('video in this turn without loaded bytes → probe carries it', async () => {
    await preflight([message('u1', 'user', 'clip', { attachments: [file, videoWithoutData] })], [file, videoWithoutData]);
    expect(probeFlags()).toEqual([true]);
  });
});

describe('model panel file card — same outbound history with a placeholder turn', () => {
  const panel = (messages: ChatMessage[], forProvider: Provider = provider) =>
    modelPanelOutboundHasVideo({ messages, provider: forProvider, model, streamOptions });

  it('[u0(video), a0 failed] → the placeholder turn merges with u0, its video stays (sanitize.v1, matches send / iOS / Android)', async () => {
    expect(await panel([
      message('u0', 'user', 'What happens in this clip?', { attachments: [video] }),
      message('a0', 'assistant', '', { state: 'failed' } as Partial<ChatMessage>),
    ])).toBe(true);
  });

  it('[u0(video), a0 delivered] → video stays in the outbound history', async () => {
    expect(await panel([
      message('u0', 'user', 'What happens in this clip?', { attachments: [videoWithoutData] }),
      message('a0', 'assistant', 'A ball rolls.'),
    ])).toBe(true);
  });

  it('only a Gemini connection is judged', async () => {
    const openAI = { id: 'o', kind: 'openAI', authMode: 'apiKey', baseURLText: '' } as unknown as Provider;
    expect(await panel([
      message('u0', 'user', 'clip', { attachments: [video] }),
      message('a0', 'assistant', 'A ball rolls.'),
    ], openAI)).toBe(false);
  });
});
