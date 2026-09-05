// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { indexedDB as fakeIndexedDB } from 'fake-indexeddb';
import { createProxyChunkParser } from '@oriveo/core/providers/proxy-chunk-parser';
import { LocalContinuationStore } from '../local-continuation-store';
import { readStream } from '../../../utils/chat-stream-utils';
import {
  continuationCaptured,
  continuationForExplicitContinue,
  continuationSendCompleted,
  continuationSendInterrupted,
  continuationSendStarted,
  deleteLocalConversationContinuation,
  deleteLocalMessageContinuation,
} from '../continuation-lifecycle';

const CONVERSATION = 'conv-continuation';
const MESSAGE = 'msg-continuation';
const opaque = '----MOONSHOT ENCRYPTED BEGIN----opaque----MOONSHOT ENCRYPTED END----';

beforeEach(() => vi.stubGlobal('indexedDB', fakeIndexedDB));
afterEach(async () => {
  await new Promise<void>((resolve) => {
    const request = fakeIndexedDB.deleteDatabase('oriveo-continuation-v1');
    request.onsuccess = request.onerror = request.onblocked = () => resolve();
  });
  vi.unstubAllGlobals();
});

describe('local continuation lifecycle', () => {
  it('persists a real proxy continuation event before completion and exposes it only to an explicit continue', async () => {
    await continuationSendStarted(CONVERSATION, MESSAGE);
    const parser = createProxyChunkParser('openAI', {
      kind: 'previous_id', protocol: 'openai_responses', responseParserKind: 'openai_responses_reasoning_v1',
    });
    const events = parser('response.completed', JSON.stringify({
      type: 'response.completed', response: { id: 'resp_exact', status: 'completed' },
    }));
    await readStream(new ReadableStream({
      start(controller) { for (const event of events) controller.enqueue(event); controller.close(); },
    }), '', vi.fn(), undefined, undefined, undefined, (continuation) => {
      continuationCaptured(CONVERSATION, MESSAGE, continuation);
    });
    // This is deliberately immediate: it proves completion cannot race ahead and delete the just
    // captured complete leg.
    await continuationSendCompleted(CONVERSATION, MESSAGE);
    await expect(continuationForExplicitContinue(CONVERSATION, MESSAGE)).resolves.toEqual({
      kind: 'previous_id', step: 1, state: { previousResponseId: 'resp_exact' },
    });
  });

  it('keeps interrupted state local but explicit resend restarts without continuation', async () => {
    continuationCaptured(CONVERSATION, MESSAGE, {
      kind: 'tool_loop', variant: 'fiber', step: 1,
      state: { completedMessages: completeToolMessages('complete', opaque) },
    });
    await continuationSendInterrupted(CONVERSATION, MESSAGE);
    await expect(continuationForExplicitContinue(CONVERSATION, MESSAGE)).resolves.toBeUndefined();
    deleteLocalMessageContinuation(CONVERSATION, `${MESSAGE}-deleted`);
    await expect(continuationForExplicitContinue(CONVERSATION, MESSAGE)).resolves.toBeUndefined();
  });

  it('rejects a persisted continuation after the page process session changes', async () => {
    const firstProcess = new LocalContinuationStore('page-process-a');
    await firstProcess.save({
      conversationId: CONVERSATION,
      messageId: MESSAGE,
      state: { continuation: {
        kind: 'tool_loop', variant: 'fiber', step: 1,
        state: { completedMessages: completeToolMessages('complete', opaque) },
      } },
    });
    await expect(firstProcess.load(CONVERSATION, MESSAGE)).resolves.not.toBeNull();
    await expect(new LocalContinuationStore('page-process-b').load(CONVERSATION, MESSAGE)).resolves.toBeNull();
  });

  it('clears a consumed prior continuation before a new explicit leg, so stale opaque state cannot be reused', async () => {
    continuationCaptured(CONVERSATION, MESSAGE, {
      kind: 'previous_id', step: 1, state: { previousResponseId: 'resp_once' },
    });
    await expect(continuationForExplicitContinue(CONVERSATION, MESSAGE)).resolves.toMatchObject({ state: { previousResponseId: 'resp_once' } });
    await continuationSendStarted(CONVERSATION, MESSAGE);
    await continuationSendCompleted(CONVERSATION, MESSAGE);
    await expect(continuationForExplicitContinue(CONVERSATION, MESSAGE)).resolves.toBeUndefined();
  });

  it('message tombstone blocks a queued and a late SSE capture from recreating a deleted sidecar', async () => {
    const messageId = `${MESSAGE}-message-delete-race`;
    continuationCaptured(CONVERSATION, messageId, { kind: 'previous_id', step: 1, state: { previousResponseId: 'queued-before-delete' } });
    const deletion = deleteLocalMessageContinuation(CONVERSATION, messageId);
    await continuationSendStarted(CONVERSATION, messageId);
    continuationCaptured(CONVERSATION, messageId, { kind: 'previous_id', step: 1, state: { previousResponseId: 'late-after-delete' } });
    await continuationSendCompleted(CONVERSATION, messageId);
    await continuationSendInterrupted(CONVERSATION, messageId);
    await deletion;
    expect((await continuationRows()).filter((row) => row.conversationId === CONVERSATION && row.messageId === messageId)).toEqual([]);
  });

  it('conversation tombstone waits queued message writes then prevents any late capture from reviving the conversation', async () => {
    const conversationId = `${CONVERSATION}-conversation-delete-race`;
    continuationCaptured(conversationId, 'first', { kind: 'previous_id', step: 1, state: { previousResponseId: 'queued-first' } });
    continuationCaptured(conversationId, 'second', { kind: 'previous_id', step: 1, state: { previousResponseId: 'queued-second' } });
    const deletion = deleteLocalConversationContinuation(conversationId);
    await continuationSendStarted(conversationId, 'late');
    continuationCaptured(conversationId, 'late', { kind: 'previous_id', step: 1, state: { previousResponseId: 'late-after-delete' } });
    await continuationSendCompleted(conversationId, 'late');
    await continuationSendInterrupted(conversationId, 'late');
    await deletion;
    expect((await continuationRows()).filter((row) => row.conversationId === conversationId)).toEqual([]);
  });
});

async function continuationRows(): Promise<Array<{ conversationId: string; messageId: string }>> {
  const db = await new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open('oriveo-continuation-v1', 1);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  try {
    const transaction = db.transaction('message-state');
    const values = await new Promise<unknown[]>((resolve, reject) => {
      const request = transaction.objectStore('message-state').getAll();
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    return values as Array<{ conversationId: string; messageId: string }>;
  } finally {
    db.close();
  }
}

function completeToolMessages(id: string, content: string) {
  return [
    { role: 'assistant', content: '', reasoning_content: 'opaque reasoning', tool_calls: [{ id, type: 'function', function: { name: 'web_search', arguments: '{}' } }] },
    { role: 'tool', tool_call_id: id, name: 'web_search', content },
  ];
}
