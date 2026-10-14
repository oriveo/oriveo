import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
  * Provider-source failure card title and relay guidance body are stored in the database as English source strings and localized at render time (aligned with iOS).
  * The production send chain (sendMessage -> production Relay orchestration layer -> fake upstream returning an official CLI gate 403) stores the failure message,
  * then MessageRecoveryCard is rendered with real copy in different languages: after switching language the title and body of the same message follow; old data is shown as is.
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';
import { RELAY_GUIDANCE } from '@oriveo/core/providers/relay-error-classifier';

type Dict = Record<string, unknown>;
const dictionaries = new Map<string, Dict>();
function dictionary(locale: string): Dict {
  let dict = dictionaries.get(locale);
  if (!dict) {
    dict = JSON.parse(readFileSync(path.join(process.cwd(), 'messages', `${locale}.json`), 'utf8')) as Dict;
    dictionaries.set(locale, dict);
  }
  return dict;
}

function lookup(locale: string, namespace: string, key: string): string {
  const value = [...namespace.split('.'), ...key.split('.')].filter(Boolean)
    .reduce<unknown>((node, part) => (node as Dict | undefined)?.[part], dictionary(locale));
  return typeof value === 'string' ? value : key;
}

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  store: null as unknown,
  locale: 'en',
  translators: new Map<string, (key: string) => string>(),
}));

vi.mock('next-intl', () => ({
  // One function instance per locale + namespace: the component puts t into deps, and a new instance each time would cause endless re-renders.
  useTranslations: (namespace = '') => {
    const cacheKey = `${mocks.locale}:${namespace}`;
    let translate = mocks.translators.get(cacheKey);
    if (!translate) {
      const locale = mocks.locale;
      translate = (key: string) => lookup(locale, namespace, key);
      mocks.translators.set(cacheKey, translate);
    }
    return translate;
  },
}));
vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn(), addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../../utils/chat-stream-utils', async () => ({
  ...await vi.importActual<typeof import('../../../utils/chat-stream-utils')>('../../../utils/chat-stream-utils'),
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
}));
vi.mock('../../usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../usage/budget-check', () => ({ checkBudgetExceeded: vi.fn() }));
vi.mock('../../sync', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../../store/app-store';
import { sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';
import { MessageRecoveryCard } from '../../../../components/chat/MessageRecoveryCard';

const GATE_BODY = JSON.stringify({
  type: 'error', error: { type: 'permission_error', message: 'This API endpoint is only accessible via the official Claude CLI' },
});

const provider = {
  id: 'relay-1', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'anthropic_messages', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'anthropic_messages', relayResolvedAuthMode: 'x_api_key',
} as unknown as Provider;
const model = {
  id: 'claude-sonnet-4-5', name: 'claude-sonnet-4-5', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
} as AIModel;

function newStore() {
  const conv = {
    id: 'conv-1', title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, previewText: '', estimatedCost: 0,
    isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-13T00:00:00.000Z',
  } as unknown as Conversation;
  const store = createAppStore({ providers: [provider], conversations: [conv] });
  mocks.store = store;
  return store;
}

/** The production send chain produces a provider-source failure message; the UI is Chinese when it is written (te uses zh-Hans), and what is stored must not depend on the UI language. */
async function sendAndFail(): Promise<ChatMessage> {
  const store = newStore();
  const conv = store.getState().conversations[0];
  await sendMessage(
    { store, appendChunk: (chunk: string) => batchAppendStreaming('conv-1', chunk), te: (key: string) => lookup('zh-Hans', 'errors', key) },
    { text: 'hello', prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic' },
  ).done;
  return store.getState().conversations[0].messages.find((m) => m.role === 'assistant') as ChatMessage;
}

function renderCard(message: ChatMessage, locale: string) {
  mocks.locale = locale;
  cleanup();
  render(
    <MessageRecoveryCard
      state="failed"
      errorTitle={message.errorTitle}
      errorDetail={message.errorDetail}
      errorKind={message.errorKind}
      errorSource={message.errorSource}
      technicalDetail={message.errorTechnicalDetail}
    />,
  );
}

beforeEach(() => {
  localStorage.clear();
  mocks.locale = 'en';
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hi' }]);
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: { fetch: async () => new Response(GATE_BODY, { status: 403, headers: { 'Content-Type': 'application/json' } }) },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    }));
});
afterEach(() => cleanup());

describe('RL2-COPY-R1 Provider-source failure card title / guidance body localized at render time', () => {
  it('RL2-COPY-R1-01 the provider-source failure card title is Provider Request Failed (16 languages taken verbatim from iOS)', async () => {
    const failed = await sendAndFail();
    expect(failed.state).toBe('failed');
    expect(failed.errorSource).toBe('provider');
    // What is stored is the English source string, independent of the UI language at write time
    expect(failed.errorTitle).toBe('Provider Request Failed');
    expect(failed.errorDetail).toBe(RELAY_GUIDANCE.clientGated);
    renderCard(failed, 'en');
    expect(screen.getByText('Provider Request Failed')).toBeTruthy();
    expect(screen.queryByText(lookup('en', 'errors', 'requestFailed.title'))).toBeNull();

    const expected: Record<string, string> = {
      ar: 'فشل طلب المزود', de: 'Anbieteranfrage fehlgeschlagen', en: 'Provider Request Failed', es: 'Solicitud al proveedor fallida',
      fr: 'Échec de la requête au fournisseur', hi: 'प्रोवाइडर अनुरोध विफल रहा', id: 'Permintaan Penyedia Gagal', ja: 'プロバイダーへのリクエスト\u5931\u6557',
      ko: '제공업체 요청 실패', 'pt-BR': 'Falha na solicitação ao provedor', ru: 'Запрос к провайдеру не выполнен', th: 'คำขอของผู้ให้บริการล้มเหลว',
      tr: 'Sağlayıcı İsteği Başarısız Oldu', vi: 'Yêu cầu nhà cung cấp không thành công', 'zh-Hans': '\u4f9b\u5e94\u5546\u8bf7\u6c42\u5931\u8d25', 'zh-Hant': '\u4f9b\u61c9\u5546\u8acb\u6c42\u5931\u6557',
    };
    for (const [locale, title] of Object.entries(expected)) {
      expect(lookup(locale, 'errors', 'providerRequestFailed.title'), locale).toBe(title);
    }
  });

  it('RL2-COPY-R1-02 after switching language the title and guidance body of the same stored message follow', async () => {
    const failed = await sendAndFail();
    renderCard(failed, 'en');
    const enTitle = lookup('en', 'errors', 'providerRequestFailed.title');
    const enBody = lookup('en', 'errors', 'relay.clientGated');
    expect(screen.getByText(enTitle)).toBeTruthy();
    expect(screen.getByText(enBody)).toBeTruthy();

    renderCard(failed, 'zh-Hans');
    const zhTitle = lookup('zh-Hans', 'errors', 'providerRequestFailed.title');
    const zhBody = lookup('zh-Hans', 'errors', 'relay.clientGated');
    expect(zhTitle).not.toBe(enTitle);
    expect(zhBody).not.toBe(enBody);
    expect(screen.getByText(zhTitle)).toBeTruthy();
    expect(screen.getByText(zhBody)).toBeTruthy();
    expect(screen.queryByText(enTitle)).toBeNull();
    expect(screen.queryByText(enBody)).toBeNull();
    // The technical detail is still the original upstream text
    expect(screen.getByText(/only accessible via the official Claude CLI/)).toBeTruthy();
  });

  it('RL2-COPY-R1-03 old data (title and body already localized when stored) is shown as is', () => {
    const legacy = {
      id: 'a-old', role: 'assistant', text: '', state: 'failed',
      errorTitle: lookup('zh-Hans', 'errors', 'requestFailed.title'),
      errorDetail: lookup('zh-Hans', 'errors', 'relay.clientGated'),
      errorKind: 'upstream', errorSource: 'provider',
    } as unknown as ChatMessage;
    renderCard(legacy, 'en');
    expect(screen.getByText(legacy.errorTitle!)).toBeTruthy();
    expect(screen.getAllByText(legacy.errorDetail!).length).toBeGreaterThan(0);
    expect(screen.queryByText(lookup('en', 'errors', 'providerRequestFailed.title'))).toBeNull();
    expect(screen.queryByText(lookup('en', 'errors', 'relay.clientGated'))).toBeNull();
  });
});
