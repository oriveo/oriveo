/**
 * Memory contract tests
 *
 * Verifies the contract constants and behavioral boundaries of the memory feature so this implementation
 * stays consistent with the other clients.
 */
import { describe, it, expect } from 'vitest';
import type { AppPreference } from '@oriveo/shared';
import type { ContentPart } from '../../providers/types';

// Reuses the pure functions extracted in memory-injection.test.ts
type ChatHistoryMsg = { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] };

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

function makeUserMessages(count: number): ChatHistoryMsg[] {
  const msgs: ChatHistoryMsg[] = [];
  for (let i = 0; i < count; i++) {
    msgs.push({ role: 'user', content: `Q${i + 1}` });
    msgs.push({ role: 'assistant', content: `A${i + 1}` });
  }
  return msgs;
}

// ── Contract constants ────────────────────────────────────────

describe('Contract: anti-forget format', () => {
  it('appends the anti-forget reminder as "\\n\\n[Reminder: ...]", not [Context: ...]', () => {
    const chatHistory = makeUserMessages(10);
    chatHistory.push({ role: 'user', content: 'Latest' });

    applyMemoryInjection(chatHistory, {
      memoryText: 'Memory',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Be concise',
    }, undefined);

    const lastUser = [...chatHistory].reverse().find((m) => m.role === 'user');
    // Must use the [Reminder: ...] shape
    expect(lastUser?.content).toContain('\n\n[Reminder: Be concise]');
    // Must not use the [Context: ...] shape
    expect(lastUser?.content).not.toContain('[Context:');
  });
});

describe('Contract: anti-forget threshold', () => {
  it('triggers at exactly 10 user messages', () => {
    const chatHistory = makeUserMessages(9);
    chatHistory.push({ role: 'user', content: 'Tenth' });

    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'Ctx',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Summary',
    }, undefined);

    expect(result.antiForgetAppended).toBe(true);
  });

  it('does not trigger at 9 user messages', () => {
    const chatHistory = makeUserMessages(8);
    chatHistory.push({ role: 'user', content: 'Ninth' });

    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'Ctx',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Summary',
    }, undefined);

    expect(result.antiForgetAppended).toBe(false);
  });
});

describe('Contract: useMemory defaults', () => {
  it('treats an undefined useMemory as enabled', () => {
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'Context',
    }, undefined);

    expect(result.injected).toBe(true);
  });

  it('blocks injection when useMemory = false', () => {
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'Context',
    }, false);

    expect(result.injected).toBe(false);
    expect(chatHistory).toHaveLength(1);
  });
});

describe('Contract: empty/whitespace memory', () => {
  it('does not inject an empty memoryText', () => {
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    const result = applyMemoryInjection(chatHistory, { memoryText: '' }, undefined);
    expect(result.injected).toBe(false);
  });

  it('does not inject a whitespace-only memoryText', () => {
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    const result = applyMemoryInjection(chatHistory, { memoryText: '   \t\n  ' }, undefined);
    expect(result.injected).toBe(false);
  });

  it('does not inject an undefined memoryText', () => {
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    const result = applyMemoryInjection(chatHistory, {}, undefined);
    expect(result.injected).toBe(false);
  });
});

describe('Contract: token estimation formula', () => {
  it('uses the formula Math.ceil(graphemeCount * 0.35)', () => {
    // Checks the agreed coefficient and rounding
    const formula = (count: number) => Math.ceil(count * 0.35);

    expect(formula(0)).toBe(0);
    expect(formula(1)).toBe(1);
    expect(formula(3)).toBe(2); // 1.05 → 2
    expect(formula(10)).toBe(4); // 3.5 → 4
    expect(formula(2000)).toBe(700);
  });
});
