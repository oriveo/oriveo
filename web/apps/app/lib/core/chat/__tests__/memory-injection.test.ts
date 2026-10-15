/**
 * Unit tests for memory injection (the anti-forgetting reminder is no longer injected).
 *
 * Covers the memory system prompt injection in sendMessage; turning the anti-forgetting preference
 * on no longer appends a reminder.
 * sendMessage itself is a tightly coupled transactional function (network calls, stream
 * reading), so the extracted pure logic is tested directly: the injection predicate and the
 * chatHistory mutation.
 */
import { describe, it, expect } from 'vitest';
import type { AppPreference } from '@oriveo/shared';
import type { ContentPart } from '../../providers/types';

// The memory injection logic from sendMessage, extracted as a testable pure function.
type ChatHistoryMsg = { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] };

/**
 * Mirrors the memory injection logic in sendMessage.
 * Kept in sync with the implementation in operations.ts.
 */
function applyMemoryInjection(
  chatHistory: ChatHistoryMsg[],
  prefs: Pick<AppPreference, 'memoryText' | 'memoryAntiForgetEnabled' | 'memoryAntiForgetText'>,
  conversationUseMemory: boolean | undefined,
): { injected: boolean } {
  const memoryText = prefs.memoryText?.trim();
  const useMemory = conversationUseMemory !== false;

  let injected = false;

  if (memoryText && useMemory) {
    chatHistory.unshift({ role: 'system', content: memoryText });
    injected = true;

  }

  return { injected };
}

// -- Helpers --

function makeUserMessages(count: number): ChatHistoryMsg[] {
  const msgs: ChatHistoryMsg[] = [];
  for (let i = 0; i < count; i++) {
    msgs.push({ role: 'user', content: `Question ${i + 1}` });
    msgs.push({ role: 'assistant', content: `Answer ${i + 1}` });
  }
  return msgs;
}

// -- Memory injection --

describe('Memory injection', () => {
  it('memoryText set with useMemory defaulted (undefined): injects the system message', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello' },
    ];
    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'I am a Go engineer',
    }, undefined);

    expect(result.injected).toBe(true);
    expect(chatHistory[0]).toEqual({ role: 'system', content: 'I am a Go engineer' });
    expect(chatHistory).toHaveLength(2);
  });

  it('memoryText set with useMemory = true: injects the system message', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello' },
    ];
    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'I am a Go engineer',
    }, true);

    expect(result.injected).toBe(true);
    expect(chatHistory[0].role).toBe('system');
  });

  it('memoryText set with useMemory = false: injects nothing', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello' },
    ];
    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'I am a Go engineer',
    }, false);

    expect(result.injected).toBe(false);
    expect(chatHistory).toHaveLength(1);
    expect(chatHistory[0].role).toBe('user');
  });

  it('empty memoryText: injects nothing', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello' },
    ];
    const result = applyMemoryInjection(chatHistory, {
      memoryText: '',
    }, undefined);

    expect(result.injected).toBe(false);
    expect(chatHistory).toHaveLength(1);
  });

  it('whitespace-only memoryText: injects nothing', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello' },
    ];
    const result = applyMemoryInjection(chatHistory, {
      memoryText: '   ',
    }, undefined);

    expect(result.injected).toBe(false);
    expect(chatHistory).toHaveLength(1);
  });

  it('undefined memoryText: injects nothing', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello' },
    ];
    const result = applyMemoryInjection(chatHistory, {}, undefined);

    expect(result.injected).toBe(false);
  });

  it('injects at the front of chatHistory', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'First' },
      { role: 'assistant', content: 'Response' },
      { role: 'user', content: 'Second' },
    ];
    applyMemoryInjection(chatHistory, { memoryText: 'My context' }, undefined);

    expect(chatHistory[0]).toEqual({ role: 'system', content: 'My context' });
    expect(chatHistory[1]).toEqual({ role: 'user', content: 'First' });
    expect(chatHistory).toHaveLength(4);
  });
});

// -- Anti-forget reminder is no longer injected --

describe('anti-forget reminder is no longer appended', () => {
  it('preference on + >= 10 turns + summary present: the last outbound user message has no [Reminder:', () => {
    const chatHistory = makeUserMessages(10);
    chatHistory.push({ role: 'user', content: 'Latest question' });

    applyMemoryInjection(chatHistory, {
      memoryText: 'I am an engineer',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Prefer Go code',
    }, undefined);

    const lastUser = [...chatHistory].reverse().find((m) => m.role === 'user');
    expect(lastUser?.content).toBe('Latest question');
    expect(JSON.stringify(chatHistory)).not.toContain('[Reminder:');
  });
});
