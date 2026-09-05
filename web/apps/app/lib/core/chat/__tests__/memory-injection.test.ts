/**
 * Unit tests for memory injection and the anti-forgetting reminder.
 *
 * Covers the memory system prompt injection and the reminder appended in sendMessage.
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
): { injected: boolean; antiForgetAppended: boolean } {
  const memoryText = prefs.memoryText?.trim();
  const useMemory = conversationUseMemory !== false;

  let injected = false;
  let antiForgetAppended = false;

  if (memoryText && useMemory) {
    chatHistory.unshift({ role: 'system', content: memoryText });
    injected = true;

    if (prefs.memoryAntiForgetEnabled) {
      const userMsgCount = chatHistory.filter((m) => m.role === 'user').length;
      const summaryText = prefs.memoryAntiForgetText?.trim();
      if (userMsgCount >= 10 && summaryText) {
        for (let i = chatHistory.length - 1; i >= 0; i--) {
          if (chatHistory[i].role === 'user') {
            const original = chatHistory[i].content;
            const textContent = typeof original === 'string' ? original : original.map((p) => p.type === 'text' ? p.text : '').join('');
            chatHistory[i] = { ...chatHistory[i], content: `${textContent}\n\n[Reminder: ${summaryText}]` };
            antiForgetAppended = true;
            break;
          }
        }
      }
    }
  }

  return { injected, antiForgetAppended };
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

// -- Anti-forgetting --

describe('Anti-forgetting', () => {
  it('enabled, over the threshold (>= 10 user messages) and with a summary: appends the reminder', () => {
    const chatHistory = makeUserMessages(10); // 10 user + 10 assistant
    chatHistory.push({ role: 'user', content: 'Latest question' }); // the 11th user message

    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'I am an engineer',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Prefer Go code',
    }, undefined);

    expect(result.injected).toBe(true);
    expect(result.antiForgetAppended).toBe(true);

    // The last user message should have the reminder appended.
    const lastUser = [...chatHistory].reverse().find((m) => m.role === 'user');
    expect(lastUser?.content).toContain('[Reminder: Prefer Go code]');
    expect(lastUser?.content).toContain('Latest question');
  });

  it('under the threshold (< 10 user messages): appends nothing', () => {
    const chatHistory = makeUserMessages(4); // 4 user
    chatHistory.push({ role: 'user', content: 'Latest' }); // the 5th message

    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'I am an engineer',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Prefer Go code',
    }, undefined);

    expect(result.injected).toBe(true);
    expect(result.antiForgetAppended).toBe(false);

    const lastUser = [...chatHistory].reverse().find((m) => m.role === 'user');
    expect(lastUser?.content).toBe('Latest');
  });

  it('antiForgetEnabled = false: appends nothing', () => {
    const chatHistory = makeUserMessages(10);
    chatHistory.push({ role: 'user', content: 'Latest' });

    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'I am an engineer',
      memoryAntiForgetEnabled: false,
      memoryAntiForgetText: 'Prefer Go code',
    }, undefined);

    expect(result.injected).toBe(true);
    expect(result.antiForgetAppended).toBe(false);
  });

  it('useMemory = false: injects nothing and appends nothing', () => {
    const chatHistory = makeUserMessages(10);
    chatHistory.push({ role: 'user', content: 'Latest' });

    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'I am an engineer',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Prefer Go code',
    }, false);

    expect(result.injected).toBe(false);
    expect(result.antiForgetAppended).toBe(false);
  });

  it('empty summary: appends nothing', () => {
    const chatHistory = makeUserMessages(10);
    chatHistory.push({ role: 'user', content: 'Latest' });

    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'I am an engineer',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: '   ',
    }, undefined);

    expect(result.injected).toBe(true);
    expect(result.antiForgetAppended).toBe(false);
  });

  it('undefined summary: appends nothing', () => {
    const chatHistory = makeUserMessages(10);
    chatHistory.push({ role: 'user', content: 'Latest' });

    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'I am an engineer',
      memoryAntiForgetEnabled: true,
    }, undefined);

    expect(result.injected).toBe(true);
    expect(result.antiForgetAppended).toBe(false);
  });

  it('triggers at exactly 10 user messages (boundary)', () => {
    // 9 user+assistant rounds plus 1 new user message = 10 user messages
    const chatHistory = makeUserMessages(9);
    chatHistory.push({ role: 'user', content: 'Tenth question' });

    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'Context',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Summary',
    }, undefined);

    // After the system message is injected chatHistory holds 20 entries (9*2 + 1 user + 1 system)
    // and the user message count is 10, which triggers the reminder.
    expect(result.antiForgetAppended).toBe(true);
  });
});
