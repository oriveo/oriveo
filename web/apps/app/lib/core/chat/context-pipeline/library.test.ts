import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Library evidence goes into [D]: evidence from direct access and server-side retrieval goes into dynamic.library, one entry per document.
 * Assertions are on the request body the production Relay orchestration layer actually sent through transport.fetch.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';
import { CONTEXT_ASSEMBLE_CONSTANTS } from '@oriveo/core/context/assemble';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  executeLibraryTool: vi.fn(),
  executeLibraryResearch: vi.fn(),
  store: null as unknown,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../library/api', () => ({
  executeLibraryTool: (...args: unknown[]) => mocks.executeLibraryTool(...args),
  executeLibraryResearch: (...args: unknown[]) => mocks.executeLibraryResearch(...args),
  isLibraryRateLimitError: () => false,
  isLibraryNotFoundError: () => false,
  LibraryAPIError: class LibraryAPIError extends Error {},
}));
vi.mock('../../library/confirmation', () => ({
  requestLibraryConfirmation: vi.fn(async () => 'continue'),
  clearOwnLibraryConfirmation: vi.fn(),
}));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest } from '../../metadata/metadata-client';
import { sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';

const provider = {
  id: 'relay-lib', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;
const model = {
  id: 'lib-model', name: 'lib-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
} as AIModel;

interface WireMessage { role: string; content: string | Array<{ type: string; text?: string }> }
const sentBodies: Array<{ messages: WireMessage[] }> = [];
const ok = () => new Response(['data: {"choices":[{"delta":{"content":"ok"}}]}', 'data: [DONE]'].map((f) => `${f}\n\n`).join(''), {
  status: 200, headers: { 'Content-Type': 'text/event-stream' },
});

const READS: Record<string, unknown> = {
  roadmap: {
    docId: 'roadmap', source: 'notion', title: 'Q3 Roadmap', url: 'https://www.notion.so/roadmap',
    sections: [{ heading: 'Launch', text: 'Ship in September.', anchor: 'launch' }, { text: 'Budget <tight>.' }],
  },
  spec: {
    docId: 'spec', source: 'notion', title: 'Spec', url: 'https://www.notion.so/spec',
    sections: [{ text: 'Use OAuth.' }],
  },
};

function newStore() {
  const conv = {
    id: 'conv-lib', title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, providerKind: 'relay', previewText: '', estimatedCost: 0,
    isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-15T00:00:00.000Z', createdAt: '2026-10-15T00:00:00.000Z',
  };
  const store = createAppStore({ providers: [provider], conversations: [conv as never] });
  mocks.store = store;
  return store;
}

async function send(store: ReturnType<typeof createAppStore>, extra: Partial<Parameters<typeof sendMessage>[1]>) {
  const conv = store.getState().conversations[0];
  await sendMessage({
    store, appendChunk: (chunk: string) => batchAppendStreaming('conv-lib', chunk), te: (key: string) => key,
  }, {
    text: 'When do we ship?', prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic',
    ...extra,
  }).done;
}

function textOf(message: WireMessage): string {
  return typeof message.content === 'string'
    ? message.content
    : message.content.filter((part) => part.type === 'text').map((part) => part.text ?? '').join('');
}

const NOTE = `<note>${CONTEXT_ASSEMBLE_CONSTANTS.notes['oriveo-library']}</note>`;

beforeEach(() => {
  localStorage.clear();
  sentBodies.length = 0;
  __resetMetadataClientForTest();
  mocks.executeLibraryTool.mockReset().mockImplementation(async (_tool: string, args: { docId: string }) => ({ result: READS[args.docId] }));
  mocks.executeLibraryResearch.mockReset().mockResolvedValue({ result: { query: 'q', documents: [], steps: [] } });
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
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('context pipeline library evidence', () => {
  it('library_evidence_in_dynamic_block', async () => {
    const store = newStore();
    await send(store, {
      libraryContextDocuments: [
        { docId: 'roadmap', source: 'notion', title: 'Q3 Roadmap' },
        { docId: 'spec', source: 'notion', title: 'Spec' },
      ],
    });
    const body = sentBodies[sentBodies.length - 1]!;
    const last = body.messages[body.messages.length - 1]!;
    expect(last.role).toBe('user');
    const library = [
      '<oriveo-library>',
      NOTE,
      '<entry citation="1" title="Q3 Roadmap">Launch\nShip in September.\n\nBudget &lt;tight&gt;.</entry>',
      '<entry citation="2" title="Spec">Use OAuth.</entry>',
      '</oriveo-library>',
    ].join('\n');
    expect(textOf(last)).toContain(library);
    const wire = JSON.stringify(body);
    expect(wire).not.toContain('library_context');
    expect(wire).not.toContain('<document');
    expect(wire).not.toContain('untrusted evidence');
    for (const system of body.messages.filter((m) => m.role === 'system')) {
      expect(textOf(system)).not.toContain('Library');
    }
    // Document n = citation n
    const assistant = store.getState().conversations[0]!.messages.find((m) => m.role === 'assistant');
    expect(assistant?.citations?.map((c) => [c.index, c.docId])).toEqual([[1, 'roadmap'], [2, 'spec']]);

    // Server-side retrieval found no evidence: one libraryEmptyEntry
    const empty = newStore();
    await send(empty, { libraryServerResearch: { query: 'When do we ship?' } });
    const emptyBody = sentBodies[sentBodies.length - 1]!;
    const emptyLast = emptyBody.messages[emptyBody.messages.length - 1]!;
    expect(textOf(emptyLast)).toContain(
      `<oriveo-library>\n${NOTE}\n<entry>${CONTEXT_ASSEMBLE_CONSTANTS.libraryEmptyEntry}</entry>\n</oriveo-library>`,
    );
    expect(JSON.stringify(emptyBody)).not.toContain('no_evidence');
  });
});
