// @vitest-environment jsdom
/**
 * A local rejection of the additional body through the production send chain: sendMessage is
 * rejected before going out -> no request is sent and the message lands as a standalone error card
 * (body = the reason sentence + "This message wasn't sent.", technical detail = the safe code only).
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  readStream: vi.fn(),
  captureException: vi.fn(),
}));

vi.mock('@sentry/nextjs', () => ({ captureException: mocks.captureException, addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../../utils/chat-stream-utils', async () => ({
  ...await vi.importActual<typeof import('../../../utils/chat-stream-utils')>('../../../utils/chat-stream-utils'),
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
  readStream: (...args: unknown[]) => mocks.readStream(...args),
}));
vi.mock('../../usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../usage/budget-check', () => ({ checkBudgetExceeded: vi.fn() }));
vi.mock('../../sync', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));
vi.mock('../../metadata/metadata-client', async () => ({
  ...await vi.importActual<typeof import('../../metadata/metadata-client')>('../../metadata/metadata-client'),
  getMetadataRevision: () => undefined,
  getCapabilityRuntime: () => null,
  resolveGenerationProfileRef: vi.fn(() => undefined),
  resolveCatalogModel: vi.fn(),
  getDeclaredReasoningLevels: vi.fn(() => []),
  getDeclaredReasoningDefaultLevel: vi.fn(() => undefined),
  getRelayRuntimeConfig: vi.fn(() => null),
}));

import { createAppStore } from '../../store/app-store';
import { sendMessage } from '../operations';
import { additionalBodyScope, loadAdditionalBody, saveAdditionalBody } from '../additional-body-settings';
import { mapErrorKindKey, resolveErrorCopyKey } from '../../../utils/chat-stream-utils';

const provider = {
  id: 'p-1', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-test', apiKeyPreview: '••test',
} as unknown as Provider;
const model = {
  id: 'gpt-4', name: 'GPT-4', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: 'standard',
} as AIModel;

function conversation(): Conversation {
  return {
    id: 'conv-1', title: 'T', hasCustomTitle: false, providerID: 'p-1', modelID: 'gpt-4', previewText: '', estimatedCost: 0,
    isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-08T00:00:00.000Z',
  } as Conversation;
}

beforeEach(() => {
  localStorage.clear();
  mocks.sendStream.mockReset();
  mocks.readStream.mockReset();
  mocks.captureException.mockReset();
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hi' }]);
  mocks.sendStream.mockReturnValue({ stream: {} as ReadableStream, abort: vi.fn() });
});

describe('local rejection of the additional body (production send chain)', () => {
  it('sends no request; standalone error card: reason sentence + line N + not sent, with only the safe code as technical detail', async () => {
    saveAdditionalBody(additionalBodyScope(provider, model, 'conv-1'), { raw: '{\n"top_k": ,\n}', enabled: true });
    const conv = conversation();
    const store = createAppStore({ providers: [provider], conversations: [conv] });
    const te = (key: string, values?: Record<string, unknown>) => (values ? `${key}${JSON.stringify(values)}` : key);
    const handle = sendMessage({ store, appendChunk: vi.fn(), te }, {
      text: 'hello', prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic',
    });
    await handle.done;

    expect(mocks.sendStream).not.toHaveBeenCalled();
    expect(mocks.captureException).not.toHaveBeenCalled();
    const failed = store.getState().conversations[0].messages.find((m) => m.role === 'assistant') as ChatMessage;
    expect(failed.state).toBe('failed');
    expect(failed.errorKind).toBe('additionalBodyRejected');
    expect(failed.errorTitle).toBe('additionalBodyRejected.title');
    expect(failed.errorDetail).toBe(
      'additionalBodyRejected.line{"line":2,"reason":"additionalBodyRejected.reasonInvalidJson"} additionalBodyRejected.message',
    );
    expect(failed.errorTechnicalDetail).toBe('additional_body_rejected:invalid_json@2');
    expect(store.getState().providers[0].status).toEqual({ kind: 'connected' });
  });

  it('the title maps to errors.additionalBodyRejected when rendered and does not fall into the upstream fallback', () => {
    expect(mapErrorKindKey('additionalBodyRejected')).toBe('additionalBodyRejected');
    expect(resolveErrorCopyKey('additionalBodyRejected')).toBe('additionalBodyRejected');
  });
});

describe('retry without the additional body (omits it for this one send only)', () => {
  it('omitAdditionalBody: the real outbound options carry no additional fields, the stored content and switch are unchanged, and the next send includes it as usual', async () => {
    const scope = additionalBodyScope(provider, model, 'conv-1');
    saveAdditionalBody(scope, { raw: '{"top_k":3}', enabled: true });
    mocks.readStream.mockResolvedValue({ fullText: 'ok', reasoningText: '', usage: undefined, imageAttachments: [], toolCalls: [] });
    const conv = conversation();
    const store = createAppStore({ providers: [provider], conversations: [conv] });
    const send = (omitAdditionalBody: boolean) => sendMessage({ store, appendChunk: vi.fn(), te: (key: string) => key }, {
      text: 'hello', prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic', omitAdditionalBody,
    }).done;

    await send(true);
    const omitted = mocks.sendStream.mock.calls.at(-1)!;
    expect(JSON.stringify(omitted)).not.toContain('additionalBody');
    expect(loadAdditionalBody(scope)).toMatchObject({ raw: '{"top_k":3}', enabled: true });

    await send(false);
    expect(JSON.stringify(mocks.sendStream.mock.calls.at(-1))).toContain('{\\"top_k\\":3}');
  });
});
