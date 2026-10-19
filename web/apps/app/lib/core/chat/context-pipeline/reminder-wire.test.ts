import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Conversation instructions are handed to the assembler through buildChatContextSources;
 * with featureFlags.context_reminder_enabled=false only the reminder is turned off, and instructions stay in system.
 * Assertions are on the request body the production sendMessage actually sent through the Relay orchestration layer's transport.fetch.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';
import { CONTEXT_ASSEMBLE_CONSTANTS, ContextAssembler, type ContextPlan } from '@oriveo/core/context/assemble';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  store: null as unknown,
  flags: {} as Record<string, boolean>,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store, tryGetVanillaStore: () => mocks.store }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../metadata/metadata-client')>();
  return {
    ...actual,
    isRuntimeFeatureEnabled: (key: string) => (key in mocks.flags ? mocks.flags[key] : actual.isRuntimeFeatureEnabled(key)),
  };
});

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest } from '../../metadata/metadata-client';
import { sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';
import { requestCompactionSummary } from './chat-context';
import type { ReadySummaryRequest } from './compaction-coordinator';

const provider = {
  id: 'relay-rem', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;
const model = {
  id: 'rem-model', name: 'rem-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
} as AIModel;

const INSTRUCTIONS = 'Always answer in French.';

interface WireMessage { role: string; content: string | Array<{ type: string; text?: string }> }
const sentBodies: Array<{ messages: WireMessage[] }> = [];
const ok = () => new Response(['data: {"choices":[{"delta":{"content":"ok"}}]}', 'data: [DONE]'].map((f) => `${f}\n\n`).join(''), {
  status: 200, headers: { 'Content-Type': 'text/event-stream' },
});

function textOf(message: WireMessage): string {
  return typeof message.content === 'string'
    ? message.content
    : message.content.filter((part) => part.type === 'text').map((part) => part.text ?? '').join('');
}

/** n turns of old conversation already delivered (n user messages + n assistant messages). */
function priorTurns(n: number): ChatMessage[] {
  const out: ChatMessage[] = [];
  for (let i = 1; i <= n; i += 1) {
    out.push({ id: `u${i}`, role: 'user', text: `Turn ${i}`, state: 'delivered' } as ChatMessage);
    out.push({ id: `a${i}`, role: 'assistant', text: `Answer ${i}`, state: 'delivered' } as ChatMessage);
  }
  return out;
}

let assembleSpy: ReturnType<typeof vi.spyOn>;
const chatPlans = (): ContextPlan[] => assembleSpy.mock.results
  .map((result: { value: unknown }) => result.value as ContextPlan)
  .filter((plan: ContextPlan) => plan.purpose === 'chat');

async function sendWithHistory(prevMessages: ChatMessage[]) {
  const conv = {
    id: 'conv-rem', title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, providerKind: 'relay', previewText: '', estimatedCost: 0,
    isDraft: false, messages: prevMessages, draftText: '', updatedAt: '2026-10-15T00:00:00.000Z', createdAt: '2026-10-15T00:00:00.000Z',
    instructions: INSTRUCTIONS,
  };
  const store = createAppStore({ providers: [provider], conversations: [conv as never] });
  mocks.store = store;
  await sendMessage({ store, appendChunk: (chunk: string) => batchAppendStreaming('conv-rem', chunk), te: (key: string) => key }, {
    text: 'Next turn', prevMessages, conversation: store.getState().conversations[0], provider, model, reasoningMode: 'automatic',
  }).done;
  expect(sentBodies).toHaveLength(1);
  return sentBodies[0];
}

const EXPECTED_SYSTEM = `${CONTEXT_ASSEMBLE_CONSTANTS.instructionsHeader}\n${INSTRUCTIONS}`;

beforeEach(() => {
  localStorage.clear();
  sentBodies.length = 0;
  mocks.flags = {};
  __resetMetadataClientForTest();
  assembleSpy = vi.spyOn(ContextAssembler, 'assemble');
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: {
        fetch: async (_url, init) => {
          sentBodies.push(JSON.parse(String(init.body)) as { messages: WireMessage[] });
          return ok();
        },
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    }));
});

afterEach(() => {
  assembleSpy.mockRestore();
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('conversation instructions on the send path', () => {
  it('pipeline_instructions_in_system', async () => {
    const body = await sendWithHistory([]);

    expect(body.messages[0]).toEqual({ role: 'system', content: EXPECTED_SYSTEM });
    expect(body.messages.filter((m) => m.role === 'system')).toHaveLength(1);
    expect(JSON.stringify(body)).not.toContain('<oriveo-reminder>');
    const plan = chatPlans().at(-1)!;
    expect(plan.system).toBe(EXPECTED_SYSTEM);
    expect(plan.reminder).toBe(false);
  });

  it('pipeline_reminder_after_six_user_messages', async () => {
    const body = await sendWithHistory(priorTurns(5));

    expect(body.messages[0]).toEqual({ role: 'system', content: EXPECTED_SYSTEM });
    const last = body.messages[body.messages.length - 1];
    expect(last.role).toBe('user');
    expect(textOf(last)).toContain('Next turn');
    expect(textOf(last)).toContain(`<oriveo-reminder>\n<note>${CONTEXT_ASSEMBLE_CONSTANTS.notes['oriveo-reminder']}</note>\n${INSTRUCTIONS}\n</oriveo-reminder>`);
    expect(chatPlans().at(-1)!.reminder).toBe(true);
  });

  it('pipeline_reminder_disabled_by_remote_flag', async () => {
    mocks.flags = { context_reminder_enabled: false };
    const body = await sendWithHistory(priorTurns(5));

    expect(body.messages[0]).toEqual({ role: 'system', content: EXPECTED_SYSTEM });
    expect(JSON.stringify(body)).not.toContain('oriveo-reminder');
    const last = body.messages[body.messages.length - 1];
    expect(textOf(last)).toContain('Next turn');
    expect(chatPlans().at(-1)!.reminder).toBe(false);
  });

  it('compaction_assemble_input_carries_instructions', async () => {
    const chatSystem = EXPECTED_SYSTEM;
    const req = { system: null, messages: [{ role: 'user', text: 'Summarize the turns above.' }], maxOutputTokens: 512 } as unknown as ReadySummaryRequest;

    await requestCompactionSummary({ provider, model, req, chatSystem, instructions: INSTRUCTIONS });

    type AssembleCall = { purpose: string; conversation: { instructions?: string } };
    const calls: AssembleCall[] = assembleSpy.mock.calls.map((call: unknown[]) => call[0] as AssembleCall);
    const compaction = calls.filter((input) => input.purpose === 'compaction');
    expect(compaction).toHaveLength(1);
    expect(compaction[0].conversation.instructions).toBe(INSTRUCTIONS);
    // On the wire, system is still taken verbatim from the chat plan system the caller chose, and appears only once.
    expect(sentBodies).toHaveLength(1);
    expect(sentBodies[0].messages[0]).toEqual({ role: 'system', content: chatSystem });
    expect(sentBodies[0].messages.filter((m) => m.role === 'system')).toHaveLength(1);
  });
});
