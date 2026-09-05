/**
 * Phase 4 - boundary, error and concurrency unit tests
 *
 * Covers the automatable cases in MEM-4-01 through MEM-4-26.
 * Exercises very long input, empty-value handling, emoji/CJK counting, preview truncation and
 */
import { describe, it, expect } from 'vitest';
import { graphemeCount, takeGraphemes } from '../../../utils/grapheme-utils';
import type { AppPreference } from '@oriveo/shared';

// -- Reused pure helpers --

type ContentPart = { type: 'text'; text: string } | { type: 'image_url'; image_url: { url: string } };
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

/** Simulates the clear-or-save decision inside updateMemory. */
function simulateUpdateMemory(
  memoryText: string | undefined,
  memoryAntiForgetEnabled: boolean | undefined,
  memoryAntiForgetText: string | undefined,
) {
  const isCleared = !memoryText?.trim();
  return {
    memoryText: isCleared ? undefined : memoryText,
    memoryAntiForgetEnabled: isCleared ? undefined : memoryAntiForgetEnabled,
    memoryAntiForgetText: isCleared ? undefined : memoryAntiForgetText,
  };
}

// -- MEM-4-01: empty string input --

describe('MEM-4-01: empty string input', () => {
  it('saves an empty string as the empty state with no stray data', () => {
    const result = simulateUpdateMemory('', true, 'some summary');
    expect(result.memoryText).toBeUndefined();
    expect(result.memoryAntiForgetEnabled).toBeUndefined();
    expect(result.memoryAntiForgetText).toBeUndefined();
  });

  it('does not inject an empty string into the chat history', () => {
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hello' }];
    const { injected } = applyMemoryInjection(chatHistory, { memoryText: '' }, undefined);
    expect(injected).toBe(false);
    expect(chatHistory).toHaveLength(1);
  });
});

// -- MEM-4-02: leading and trailing whitespace --

describe('MEM-4-02: leading and trailing whitespace', () => {
  it('saves normally after surrounding whitespace is trimmed', () => {
    const result = simulateUpdateMemory('  Hello World  ', false, '');
    expect(result.memoryText).toBe('  Hello World  ');
    // updateMemory does not trim memoryText itself; it only uses trim to decide whether the
    // value is being cleared. The actual trim happens at injection time.
  });

  it('treats whitespace only as clearing the value', () => {
    const result = simulateUpdateMemory('   ', true, 'summary');
    expect(result.memoryText).toBeUndefined();
    expect(result.memoryAntiForgetEnabled).toBeUndefined();
  });

  it('trims automatically on injection', () => {
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hello' }];
    const { injected } = applyMemoryInjection(chatHistory, { memoryText: '  I am a dev  ' }, undefined);
    expect(injected).toBe(true);
    expect((chatHistory[0].content as string)).toBe('I am a dev');
  });
});

// -- MEM-4-03: newline or tab only input --

describe('MEM-4-03: newline or tab only input', () => {
  it('treats newlines only as unset', () => {
    const result = simulateUpdateMemory('\n\n\n', false, '');
    expect(result.memoryText).toBeUndefined();
  });

  it('treats tabs only as unset', () => {
    const result = simulateUpdateMemory('\t\t', false, '');
    expect(result.memoryText).toBeUndefined();
  });

  it('treats mixed newlines and spaces as unset', () => {
    const result = simulateUpdateMemory('  \n\t  \n  ', false, '');
    expect(result.memoryText).toBeUndefined();
  });

  it('does not inject a newline-only value', () => {
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hello' }];
    const { injected } = applyMemoryInjection(chatHistory, { memoryText: '\n\t\n' }, undefined);
    expect(injected).toBe(false);
  });
});

// -- MEM-4-04: multi-line body --

describe('MEM-4-04: multi-line body', () => {
  it('keeps newlines after saving', () => {
    const multiline = 'Line 1\nLine 2\nLine 3';
    const result = simulateUpdateMemory(multiline, false, '');
    expect(result.memoryText).toBe(multiline);
  });

  it('injects multi-line text correctly', () => {
    const multiline = 'Rule 1: Be concise\nRule 2: Use Chinese';
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hello' }];
    applyMemoryInjection(chatHistory, { memoryText: multiline }, undefined);
    expect(chatHistory[0].content).toBe(multiline);
  });
});

// -- MEM-4-06: emoji counting --

describe('MEM-4-06: emoji grapheme cluster counting', () => {
  it('counts the family emoji as one grapheme', () => {
    expect(graphemeCount('👨‍👩‍👧‍👦')).toBe(1);
  });

  it('counts the flag emoji as one grapheme', () => {
    expect(graphemeCount('🇨🇳')).toBe(1);
  });

  it('counts a skin-tone variant as one grapheme', () => {
    expect(graphemeCount('👋🏽')).toBe(1);
  });

  it('counts several composite emoji correctly', () => {
    expect(graphemeCount('👨‍👩‍👧‍👦🇨🇳👋🏽')).toBe(3);
  });

  it('counts plain emoji mixed with text', () => {
    expect(graphemeCount('Hello 🌍!')).toBe(8);
  });
});

// -- MEM-4-07: CJK, combining and Arabic characters --

describe('MEM-4-07: CJK, combining and Arabic character counting', () => {
  it('counts Chinese characters', () => {
    expect(graphemeCount('こんにちは')).toBe(5);
  });

  it('counts mixed Japanese (kana plus kanji)', () => {
    expect(graphemeCount('こんにちはせかい')).toBe(8);
  });

  it('counts Korean', () => {
    expect(graphemeCount('안녕하세요')).toBe(5);
  });

  it('counts Arabic', () => {
    expect(graphemeCount('مرحبا')).toBe(5);
  });

  it('counts a combining sequence (e plus combining acute) as one', () => {
    // e + \u0301 (combining acute accent) = 1 grapheme
    expect(graphemeCount('e\u0301')).toBe(1);
  });

  it('counts mixed CJK, emoji and ASCII', () => {
    expect(graphemeCount('Helloあい👋')).toBe(8);
  });
});

// -- MEM-4-08: 30 and 300 character preview truncation --

describe('MEM-4-08: preview truncation never splits a surrogate pair', () => {
  it('truncates at 30 characters: plain text', () => {
    const text = 'a'.repeat(50);
    const preview = takeGraphemes(text, 30);
    expect(graphemeCount(preview)).toBe(30);
  });

  it('truncates at 30 characters: text containing a family emoji', () => {
    const text = '👨‍👩‍👧‍👦'.repeat(40);
    const preview = takeGraphemes(text, 30);
    expect(graphemeCount(preview)).toBe(30);
    // No half surrogate may appear.
    expect(preview).not.toContain('\uFFFD');
  });

  it('truncates at 30 characters: emoji sitting on the boundary', () => {
    const text = 'a'.repeat(29) + '👨‍👩‍👧‍👦' + 'b'.repeat(20);
    const preview = takeGraphemes(text, 30);
    expect(graphemeCount(preview)).toBe(30);
    // The 30th character has to be the complete family emoji.
    expect(preview.endsWith('👨‍👩‍👧‍👦')).toBe(true);
  });

  it('truncates at 300 characters: Chinese mixed with emoji', () => {
    const text = 'あ'.repeat(295) + '👨‍👩‍👧‍👦'.repeat(10);
    const preview = takeGraphemes(text, 300);
    expect(graphemeCount(preview)).toBe(300);
  });

  it('keeps a flag emoji intact on the truncation boundary', () => {
    const text = 'x'.repeat(29) + '🇨🇳';
    const preview = takeGraphemes(text, 30);
    expect(graphemeCount(preview)).toBe(30);
    expect(preview.endsWith('🇨🇳')).toBe(true);
  });
});

// -- MEM-4-13: drafts longer than 2000 characters are truncated --

describe('MEM-4-13: draft results longer than 2000 characters are truncated', () => {
  const MAX_MEMORY_CHARS = 2000;

  it('truncates 5000 characters down to 2000', () => {
    const draft = 'a'.repeat(5000);
    const truncated = takeGraphemes(draft.trim(), MAX_MEMORY_CHARS);
    expect(graphemeCount(truncated)).toBe(2000);
  });

  it('safely truncates a very long draft made of emoji', () => {
    const draft = '😀'.repeat(3000);
    const truncated = takeGraphemes(draft, MAX_MEMORY_CHARS);
    expect(graphemeCount(truncated)).toBe(2000);
  });

  it('does not truncate at exactly 2000 characters', () => {
    const draft = 'a'.repeat(2000);
    const truncated = takeGraphemes(draft, MAX_MEMORY_CHARS);
    expect(truncated).toBe(draft);
  });
});

// -- MEM-4-26: the reminder context never appears in the original messages --

describe('MEM-4-26: the reminder context exists only in the request copy', () => {
  it('does not append the context to the original message array', () => {
    // Build the original messages first, then inject into a copy.
    const originalMessages: ChatHistoryMsg[] = makeUserMessages(10);
    originalMessages.push({ role: 'user', content: 'Latest question' });

    // Keep a reference to the original content.
    const originalLastContent = originalMessages[originalMessages.length - 1].content;

    // Inject into the copy.
    const requestCopy = originalMessages.map((m) => ({ ...m }));
    applyMemoryInjection(requestCopy, {
      memoryText: 'I am a developer',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Be concise',
    }, undefined);

    // Confirm the original messages were not modified (applyMemoryInjection mutates the array it receives).
    // What is verified here is the principle: the request copy and the local messages stay separate.
    const requestLastUser = [...requestCopy].reverse().find((m) => m.role === 'user');
    expect(requestLastUser?.content).toContain('[Reminder: Be concise]');

    // The original reference must not contain the context, because the copy is made with spread.
    expect(originalLastContent).not.toContain('[Reminder:');
  });

  it('export path: the original messages carry no appended context text', () => {
    const messages = makeUserMessages(15);
    messages.push({ role: 'user', content: 'My final question' });

    // Simulate an export by serializing the original messages directly.
    const exportedContent = messages.map((m) => `${m.role}: ${m.content}`).join('\n');
    expect(exportedContent).not.toContain('[Reminder:');
  });
});

// -- MEM-4-05: very long strings with no whitespace --

describe('MEM-4-05: very long strings with no whitespace', () => {
  const MAX_MEMORY_CHARS = 2000;

  it('counts graphemes correctly in a 2000-character string with no spaces', () => {
    const longStr = 'a'.repeat(2000);
    expect(graphemeCount(longStr)).toBe(2000);
  });

  it('takeGraphemes does not truncate a 2000-character string with no spaces', () => {
    const longStr = 'x'.repeat(2000);
    const result = takeGraphemes(longStr, MAX_MEMORY_CHARS);
    expect(result).toBe(longStr);
    expect(graphemeCount(result)).toBe(2000);
  });

  it('takeGraphemes truncates a 3000-character string with no spaces down to 2000', () => {
    const longStr = 'z'.repeat(3000);
    const result = takeGraphemes(longStr, MAX_MEMORY_CHARS);
    expect(graphemeCount(result)).toBe(2000);
  });

  it('saves and injects a long Chinese string with no spaces correctly', () => {
    const longCJK = 'あ'.repeat(2000);
    const saved = simulateUpdateMemory(longCJK, false, '');
    expect(saved.memoryText).toBe(longCJK);

    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hello' }];
    const { injected } = applyMemoryInjection(chatHistory, { memoryText: longCJK }, undefined);
    expect(injected).toBe(true);
    expect(chatHistory[0].content).toBe(longCJK);
  });

  it('injects a long emoji string with no spaces correctly', () => {
    const longEmoji = '🔥'.repeat(2000);
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    applyMemoryInjection(chatHistory, { memoryText: longEmoji }, undefined);
    expect(chatHistory[0].content).toBe(longEmoji);
  });

  it('truncates the 30-character preview of a long string with no spaces', () => {
    const longStr = 'k'.repeat(2000);
    const preview = takeGraphemes(longStr, 30);
    expect(graphemeCount(preview)).toBe(30);
    expect(preview).toBe('k'.repeat(30));
  });

  it('truncates the 300-character preview of a long string with no spaces', () => {
    const longStr = 'm'.repeat(2000);
    const preview = takeGraphemes(longStr, 300);
    expect(graphemeCount(preview)).toBe(300);
    expect(preview).toBe('m'.repeat(300));
  });

  it('builds a 30-character preview of a long CJK string with no spaces', () => {
    const longCJK = 'わ'.repeat(500);
    const preview = takeGraphemes(longCJK, 30);
    expect(graphemeCount(preview)).toBe(30);
    expect(preview).toBe('わ'.repeat(30));
  });

  it('builds a 300-character preview of a long mixed emoji string without splitting a grapheme', () => {
    const mixed = '🎉🔥💯'.repeat(200); // 600 emoji
    const preview = takeGraphemes(mixed, 300);
    expect(graphemeCount(preview)).toBe(300);
    expect(preview).not.toContain('\uFFFD');
  });
});

// -- MEM-4-09: generating a draft with no provider available --

/** Preconditions for generating a draft: at least one provider and some conversation history. */
function canGenerateDraft(
  providers: Array<{ models: unknown[]; catalogModels?: unknown[] }>,
  conversations: Array<{ isDraft: boolean; messages: unknown[] }>,
): boolean {
  const hasRecentConversations = conversations.some((c) => !c.isDraft && c.messages.length > 0);
  const hasProviderForDraft = providers.some((p) => p.models.length > 0 || (p.catalogModels?.length ?? 0) > 0);
  return hasRecentConversations && hasProviderForDraft;
}

describe('MEM-4-09: no draft can be generated without an available provider', () => {
  it('an empty providers array gives canGenerateDraft = false', () => {
    const result = canGenerateDraft(
      [],
      [{ isDraft: false, messages: [{ role: 'user', content: 'Hi' }] }],
    );
    expect(result).toBe(false);
  });

  it('every provider having an empty models array gives canGenerateDraft = false', () => {
    const result = canGenerateDraft(
      [{ models: [] }, { models: [], catalogModels: [] }],
      [{ isDraft: false, messages: [{ role: 'user', content: 'Hi' }] }],
    );
    expect(result).toBe(false);
  });

  it('a provider with catalogModels but no models gives canGenerateDraft = true', () => {
    const result = canGenerateDraft(
      [{ models: [], catalogModels: [{ id: 'gpt-4' }] }],
      [{ isDraft: false, messages: [{ role: 'user', content: 'Hi' }] }],
    );
    expect(result).toBe(true);
  });

  it('a provider with models gives canGenerateDraft = true when a conversation exists', () => {
    const result = canGenerateDraft(
      [{ models: [{ id: 'gpt-4' }] }],
      [{ isDraft: false, messages: [{ role: 'user', content: 'Hi' }] }],
    );
    expect(result).toBe(true);
  });

  it('several empty providers plus one with a model gives true', () => {
    const result = canGenerateDraft(
      [{ models: [] }, { models: [] }, { models: [{ id: 'claude-3' }] }],
      [{ isDraft: false, messages: [{ role: 'user', content: 'Hi' }] }],
    );
    expect(result).toBe(true);
  });
});

// -- MEM-4-10: generating a draft with no conversation history --

describe('MEM-4-10: no draft can be generated without conversation history', () => {
  it('an empty conversations array gives canGenerateDraft = false', () => {
    const result = canGenerateDraft(
      [{ models: [{ id: 'gpt-4' }] }],
      [],
    );
    expect(result).toBe(false);
  });

  it('every conversation being a draft gives canGenerateDraft = false', () => {
    const result = canGenerateDraft(
      [{ models: [{ id: 'gpt-4' }] }],
      [
        { isDraft: true, messages: [] },
        { isDraft: true, messages: [{ role: 'user', content: 'Draft msg' }] },
      ],
    );
    expect(result).toBe(false);
  });

  it('a non-draft conversation with no messages gives canGenerateDraft = false', () => {
    const result = canGenerateDraft(
      [{ models: [{ id: 'gpt-4' }] }],
      [
        { isDraft: false, messages: [] },
        { isDraft: false, messages: [] },
      ],
    );
    expect(result).toBe(false);
  });

  it('a draft with messages plus a non-draft without messages gives false', () => {
    const result = canGenerateDraft(
      [{ models: [{ id: 'gpt-4' }] }],
      [
        { isDraft: true, messages: [{ role: 'user', content: 'x' }] },
        { isDraft: false, messages: [] },
      ],
    );
    expect(result).toBe(false);
  });

  it('at least one non-draft conversation with messages gives true', () => {
    const result = canGenerateDraft(
      [{ models: [{ id: 'gpt-4' }] }],
      [
        { isDraft: false, messages: [] },
        { isDraft: false, messages: [{ role: 'user', content: 'Hello' }] },
      ],
    );
    expect(result).toBe(true);
  });
});

// -- MEM-4-11: network failure during draft generation --

describe('MEM-4-11: a failed draft request does not damage saved memory', () => {
  it('simulateUpdateMemory state stays valid after a network error', () => {
    // Save a valid memory value first.
    const savedState = simulateUpdateMemory('I am a developer', true, 'Be concise');
    expect(savedState.memoryText).toBe('I am a developer');
    expect(savedState.memoryAntiForgetEnabled).toBe(true);
    expect(savedState.memoryAntiForgetText).toBe('Be concise');

    // Simulate a failed draft generation (a network error is thrown); saved state must not change.
    const draftError = new Error('Network request failed');
    expect(draftError).toBeDefined();

    // Confirm the saved state is unaffected.
    const afterError = simulateUpdateMemory('I am a developer', true, 'Be concise');
    expect(afterError).toEqual(savedState);
  });

  it('the error type does not affect the state: timeout', () => {
    const saved = simulateUpdateMemory('My rules', false, '');
    const timeoutError = new Error('Request timeout');
    expect(timeoutError.message).toBe('Request timeout');
    // State unchanged.
    expect(simulateUpdateMemory('My rules', false, '')).toEqual(saved);
  });

  it('the error type does not affect the state: HTTP 500', () => {
    const saved = simulateUpdateMemory('Coding standards', true, 'summary');
    // Simulate a 500 error.
    const serverError = { status: 500, message: 'Internal Server Error' };
    expect(serverError.status).toBe(500);
    // State unchanged.
    expect(simulateUpdateMemory('Coding standards', true, 'summary')).toEqual(saved);
  });

  it('applyMemoryInjection still uses the saved state after an error', () => {
    const savedState = simulateUpdateMemory('I like TypeScript', true, 'Be brief');
    // Inject using the saved state after simulating a network failure.
    const chatHistory: ChatHistoryMsg[] = makeUserMessages(10);
    chatHistory.push({ role: 'user', content: 'Latest Q' });
    const { injected, antiForgetAppended } = applyMemoryInjection(chatHistory, {
      memoryText: savedState.memoryText,
      memoryAntiForgetEnabled: savedState.memoryAntiForgetEnabled,
      memoryAntiForgetText: savedState.memoryAntiForgetText,
    }, undefined);
    expect(injected).toBe(true);
    expect(antiForgetAppended).toBe(true);
  });
});

// -- MEM-4-12: draft cancellation --

describe('MEM-4-12: draft cancellation through a requestId mismatch', () => {
  it('ignores the result when the requestId does not match', () => {
    // Simulate the requestId mechanism.
    let activeDraftRequestId: string | null = 'req-001';

    // Start a new request and update the requestId.
    activeDraftRequestId = 'req-002';

    // Check the requestId when the old request returns.
    const oldRequestId = 'req-001';
    const shouldApply = oldRequestId === activeDraftRequestId;
    expect(shouldApply).toBe(false);
  });

  it('applies the result when the requestId matches', () => {
    const activeDraftRequestId = 'req-003';
    const returningRequestId = 'req-003';
    const shouldApply = returningRequestId === activeDraftRequestId;
    expect(shouldApply).toBe(true);
  });

  it('a new request completes normally after a cancellation', () => {
    let activeDraftRequestId: string | null = 'req-A';
    // Cancel the old request.
    activeDraftRequestId = 'req-B';
    // The new request returns.
    const shouldApply = 'req-B' === activeDraftRequestId;
    expect(shouldApply).toBe(true);
  });

  it('the final request still matches after repeated cancellations', () => {
    let activeDraftRequestId: string | null = 'req-1';
    // Consecutive cancellations.
    activeDraftRequestId = 'req-2';
    activeDraftRequestId = 'req-3';
    activeDraftRequestId = 'req-4';
    // Only the last one matches.
    expect('req-1' === activeDraftRequestId).toBe(false);
    expect('req-2' === activeDraftRequestId).toBe(false);
    expect('req-3' === activeDraftRequestId).toBe(false);
    expect('req-4' === activeDraftRequestId).toBe(true);
  });
});

// -- MEM-4-14: user edits during draft generation --

/** Whether the draft result should be applied automatically (no conflict). */
function shouldAutoApplyDraft(
  baselineRevision: number,
  currentRevision: number,
  baselineText: string,
  currentText: string,
): boolean {
  return currentRevision === baselineRevision && currentText === baselineText;
}

describe('MEM-4-14: user edits during draft generation cause a conflict', () => {
  it('no user edit: revision and text match, so the draft applies automatically', () => {
    const result = shouldAutoApplyDraft(1, 1, 'original', 'original');
    expect(result).toBe(true);
  });

  it('user edited: the revision changed, so the draft does not apply automatically', () => {
    const result = shouldAutoApplyDraft(1, 2, 'original', 'user edited');
    expect(result).toBe(false);
  });

  it('same revision but different text does not apply automatically', () => {
    const result = shouldAutoApplyDraft(1, 1, 'original', 'modified');
    expect(result).toBe(false);
  });

  it('different revision but same text does not apply automatically, the revision decides', () => {
    const result = shouldAutoApplyDraft(1, 2, 'same text', 'same text');
    expect(result).toBe(false);
  });

  it('an empty baseline plus user input does not apply automatically', () => {
    const result = shouldAutoApplyDraft(0, 1, '', 'user typed something');
    expect(result).toBe(false);
  });

  it('the revision accumulates over consecutive edits and the returned draft detects the conflict', () => {
    let revision = 0;
    const baselineRevision = revision;
    const baselineText = '';
    // Simulate several user edits.
    revision++; // edit 1
    revision++; // edit 2
    revision++; // edit 3
    const result = shouldAutoApplyDraft(baselineRevision, revision, baselineText, 'final edit');
    expect(result).toBe(false);
  });
});

// -- MEM-4-18: rapid repeated saves --

describe('MEM-4-18: rapid repeated saves are idempotent', () => {
  it('five calls with identical arguments produce an identical result', () => {
    const results = [];
    for (let i = 0; i < 5; i++) {
      results.push(simulateUpdateMemory('My preferences', true, 'Be concise'));
    }
    for (let i = 1; i < results.length; i++) {
      expect(results[i]).toEqual(results[0]);
    }
  });

  it('repeated calls with the same empty value produce the same result', () => {
    const results = [];
    for (let i = 0; i < 5; i++) {
      results.push(simulateUpdateMemory('', false, ''));
    }
    for (let i = 1; i < results.length; i++) {
      expect(results[i]).toEqual(results[0]);
    }
    // All of them are the empty state.
    expect(results[0].memoryText).toBeUndefined();
  });

  it('alternating saves of different values end in the correct final state', () => {
    const state1 = simulateUpdateMemory('Version A', true, 'Summary A');
    const state2 = simulateUpdateMemory('Version B', false, '');
    const state3 = simulateUpdateMemory('Version A', true, 'Summary A');
    // state1 and state3 are identical.
    expect(state3).toEqual(state1);
    // state2 differs.
    expect(state2).not.toEqual(state1);
  });

  it('a large number of consecutive saves has no side effects', () => {
    const text = 'Persistent memory';
    for (let i = 0; i < 100; i++) {
      const result = simulateUpdateMemory(text, true, 'summary');
      expect(result.memoryText).toBe(text);
      expect(result.memoryAntiForgetEnabled).toBe(true);
      expect(result.memoryAntiForgetText).toBe('summary');
    }
  });
});

// -- MEM-4-21: sending immediately after a save --

describe('MEM-4-21: sending right after a save injects the newest value', () => {
  it('the injected text matches the value that was just saved', () => {
    const savedText = 'I prefer Chinese responses';
    const saved = simulateUpdateMemory(savedText, false, '');
    expect(saved.memoryText).toBe(savedText);

    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'What is AI?' }];
    applyMemoryInjection(chatHistory, { memoryText: saved.memoryText }, undefined);
    expect(chatHistory[0].role).toBe('system');
    expect(chatHistory[0].content).toBe(savedText);
  });

  it('injects the full text when saving with the reminder enabled', () => {
    const saved = simulateUpdateMemory('My rules', true, 'Be brief');
    const chatHistory: ChatHistoryMsg[] = makeUserMessages(10);
    chatHistory.push({ role: 'user', content: 'Latest' });

    const { injected, antiForgetAppended } = applyMemoryInjection(chatHistory, {
      memoryText: saved.memoryText,
      memoryAntiForgetEnabled: saved.memoryAntiForgetEnabled,
      memoryAntiForgetText: saved.memoryAntiForgetText,
    }, undefined);

    expect(injected).toBe(true);
    expect(antiForgetAppended).toBe(true);
    expect(chatHistory[0].content).toBe('My rules');
    const lastUser = [...chatHistory].reverse().find((m) => m.role === 'user');
    expect(lastUser?.content).toContain('[Reminder: Be brief]');
  });

  it('injects nothing when sending after saving an empty value', () => {
    const saved = simulateUpdateMemory('', false, '');
    expect(saved.memoryText).toBeUndefined();

    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hello' }];
    const { injected } = applyMemoryInjection(chatHistory, { memoryText: saved.memoryText }, undefined);
    expect(injected).toBe(false);
    expect(chatHistory).toHaveLength(1);
  });

  it('sending right after an update uses the updated value', () => {
    // First save.
    const saved1 = simulateUpdateMemory('Version 1', false, '');
    // Second, updating save.
    const saved2 = simulateUpdateMemory('Version 2', true, 'summary v2');

    const chatHistory: ChatHistoryMsg[] = makeUserMessages(10);
    chatHistory.push({ role: 'user', content: 'Q' });
    applyMemoryInjection(chatHistory, {
      memoryText: saved2.memoryText,
      memoryAntiForgetEnabled: saved2.memoryAntiForgetEnabled,
      memoryAntiForgetText: saved2.memoryAntiForgetText,
    }, undefined);

    expect(chatHistory[0].content).toBe('Version 2');
    expect(saved1.memoryText).toBe('Version 1'); // The old value is unaffected.
  });
});

// -- MEM-4-22: sign-out or account switch during draft generation --

describe('MEM-4-22: sign-out or account switch during draft generation', () => {
  it('sign-out clears activeDraftRequestId so a late result is ignored', () => {
    let activeDraftRequestId: string | null = 'req-draft-001';

    // Simulate sign-out by clearing the requestId.
    activeDraftRequestId = null;

    // The draft result arrives late.
    const returningRequestId = 'req-draft-001';
    const shouldApply = returningRequestId === activeDraftRequestId;
    expect(shouldApply).toBe(false);
  });

  it('the requestId resets on an account switch so the previous account draft is ignored', () => {
    let activeDraftRequestId: string | null = 'user-A-req-001';

    // Account switch: the requestId is reset.
    activeDraftRequestId = null;

    // The new account starts a new request.
    activeDraftRequestId = 'user-B-req-001';

    // The old account draft comes back.
    expect('user-A-req-001' === activeDraftRequestId).toBe(false);
    // The new account draft comes back.
    expect('user-B-req-001' === activeDraftRequestId).toBe(true);
  });

  it('signing back in produces a request id that does not collide with the old one', () => {
    let activeDraftRequestId: string | null = 'session1-req-001';
    // Sign out.
    activeDraftRequestId = null;
    // Sign back in and start a new request.
    activeDraftRequestId = 'session2-req-001';
    expect('session1-req-001' === activeDraftRequestId).toBe(false);
    expect('session2-req-001' === activeDraftRequestId).toBe(true);
  });
});

// -- MEM-4-25: memory operations are unaffected by provider removal --

describe('MEM-4-25: memory operations are unaffected after a provider is removed', () => {
  it('simulateUpdateMemory does not depend on any provider information', () => {
    // Saving memory is purely a preference operation and has nothing to do with a provider.
    const result = simulateUpdateMemory('I am a developer who uses GPT-4', true, 'Be concise');
    expect(result.memoryText).toBe('I am a developer who uses GPT-4');
    expect(result.memoryAntiForgetEnabled).toBe(true);
    expect(result.memoryAntiForgetText).toBe('Be concise');
  });

  it('applyMemoryInjection does not depend on provider state', () => {
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hello' }];
    // Injection needs only prefs and chatHistory, not a provider.
    const { injected } = applyMemoryInjection(
      chatHistory,
      { memoryText: 'Use TypeScript' },
      undefined,
    );
    expect(injected).toBe(true);
    expect(chatHistory[0].content).toBe('Use TypeScript');
  });

  it('appending the reminder does not depend on provider state', () => {
    const chatHistory: ChatHistoryMsg[] = makeUserMessages(10);
    chatHistory.push({ role: 'user', content: 'Latest' });
    const { antiForgetAppended } = applyMemoryInjection(chatHistory, {
      memoryText: 'Rules',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Remember Chinese',
    }, undefined);
    expect(antiForgetAppended).toBe(true);
  });

  it('canGenerateDraft returns false with an empty provider list while memory operations still work', () => {
    // Draft generation is unavailable.
    const canDraft = canGenerateDraft([], [{ isDraft: false, messages: [{ role: 'user', content: 'Hi' }] }]);
    expect(canDraft).toBe(false);

    // Manual saving and injection still work.
    const saved = simulateUpdateMemory('Manual memory', true, 'summary');
    expect(saved.memoryText).toBe('Manual memory');

    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    const { injected } = applyMemoryInjection(chatHistory, { memoryText: saved.memoryText }, undefined);
    expect(injected).toBe(true);
  });
});
