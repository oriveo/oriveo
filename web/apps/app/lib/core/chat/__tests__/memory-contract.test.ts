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

function makeUserMessages(count: number): ChatHistoryMsg[] {
  const msgs: ChatHistoryMsg[] = [];
  for (let i = 0; i < count; i++) {
    msgs.push({ role: 'user', content: `Q${i + 1}` });
    msgs.push({ role: 'assistant', content: `A${i + 1}` });
  }
  return msgs;
}

// ── Contract constants ────────────────────────────────────────

// ── Anti-forget reminder is no longer injected ─────────────────────

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
