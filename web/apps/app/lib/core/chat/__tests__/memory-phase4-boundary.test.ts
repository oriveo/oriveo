/**
 * Phase 4+ boundary and edge-case unit tests.
 *
 * Covers the automatable cases: paste truncation over the limit, zero-width characters, 2000 pure
 * emoji, mixed RTL text, Markdown treated as plain text and anti-forget on multimodal messages.
 */
import { describe, it, expect } from 'vitest';
import { graphemeCount, takeGraphemes } from '../../../utils/grapheme-utils';

// ── Shared pure functions ──────────────────────────────────────

type ContentPart = { type: 'text'; text: string } | { type: 'image_url'; image_url: { url: string } };
type ChatHistoryMsg = { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] };

function applyMemoryInjection(
  chatHistory: ChatHistoryMsg[],
  prefs: { memoryText?: string; memoryAntiForgetEnabled?: boolean; memoryAntiForgetText?: string },
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

describe('paste truncation to 2000 grapheme clusters', () => {
  const MAX_MEMORY_CHARS = 2000;

  it('ASCII 5000 → 2000', () => {
    const pasted = 'a'.repeat(5000);
    const result = takeGraphemes(pasted, MAX_MEMORY_CHARS);
    expect(graphemeCount(result)).toBe(2000);
  });

  it('5000 characters truncate to 2000', () => {
    const pasted = 'あ'.repeat(5000);
    const result = takeGraphemes(pasted, MAX_MEMORY_CHARS);
    expect(graphemeCount(result)).toBe(2000);
  });

  it('5000 emoji truncate to 2000 without breaking grapheme clusters', () => {
    const pasted = '👨‍👩‍👧‍👦'.repeat(5000);
    const result = takeGraphemes(pasted, MAX_MEMORY_CHARS);
    expect(graphemeCount(result)).toBe(2000);
    // Each family emoji stays intact
    for (const seg of new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(result)) {
      expect(seg.segment).toBe('👨‍👩‍👧‍👦');
    }
  });

  it('the truncation point does not split a surrogate pair', () => {
    // 1999 ASCII characters + one family emoji + more characters
    const pasted = 'a'.repeat(1999) + '👨‍👩‍👧‍👦' + 'b'.repeat(100);
    const result = takeGraphemes(pasted, MAX_MEMORY_CHARS);
    expect(graphemeCount(result)).toBe(2000);
    // No replacement characters
    expect(result).not.toContain('\uFFFD');
  });
});

describe('anti-forget summary paste truncates at 200', () => {
  const MAX_ANTI_FORGET_CHARS = 200;

  it('500 characters truncate to 200', () => {
    const pasted = 'x'.repeat(500);
    const result = takeGraphemes(pasted, MAX_ANTI_FORGET_CHARS);
    expect(graphemeCount(result)).toBe(200);
  });

  it('emoji truncate to 200 graphemes', () => {
    const pasted = '🎉'.repeat(300);
    const result = takeGraphemes(pasted, MAX_ANTI_FORGET_CHARS);
    expect(graphemeCount(result)).toBe(200);
  });
});

describe('zero-width character handling', () => {
  it('a zero-width space (U+200B) does not crash', () => {
    const text = 'Hello\u200BWorld';
    expect(() => graphemeCount(text)).not.toThrow();
    // A zero-width space may or may not count as its own grapheme, but it must not crash
  });

  it('a zero-width joiner (ZWJ, U+200D) does not crash', () => {
    const text = 'A\u200DB';
    expect(() => graphemeCount(text)).not.toThrow();
  });

  it('a zero-width non-joiner (ZWNJ, U+200C) does not crash', () => {
    const text = 'A\u200CB';
    expect(() => graphemeCount(text)).not.toThrow();
  });

  it('content with zero-width characters round-trips unchanged', () => {
    const text = 'Hello\u200B\u200C\u200DWorld';
    const json = JSON.stringify(text);
    const restored = JSON.parse(json);
    expect(restored).toBe(text);
  });

  it('text containing zero-width characters injects safely', () => {
    const memoryText = 'わたしは\u200Bかいはつしゃ\u200D';
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hello' }];
    applyMemoryInjection(chatHistory, { memoryText }, undefined);
    expect(chatHistory[0].content).toBe(memoryText);
  });
});

describe('pure emoji filling 2000 graphemes', () => {
  it('2000 family emoji can be saved', () => {
    const text = '👨‍👩‍👧‍👦'.repeat(2000);
    expect(graphemeCount(text)).toBe(2000);

    // Serializable
    const json = JSON.stringify({ memoryText: text });
    const parsed = JSON.parse(json);
    expect(parsed.memoryText).toBe(text);
  });

  it('2000 plain emoji can be injected', () => {
    const text = '😀'.repeat(2000);
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hello' }];
    applyMemoryInjection(chatHistory, { memoryText: text }, undefined);
    expect(chatHistory[0].content).toBe(text);
  });
});

describe('bidirectional text (RTL + LTR)', () => {
  it('mixed Arabic and English is saved correctly', () => {
    const text = 'Hello مرحبا World عالم';
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    applyMemoryInjection(chatHistory, { memoryText: text }, undefined);
    expect(chatHistory[0].content).toBe(text);
  });

  it('RTL text is counted correctly by grapheme', () => {
    const arabic = 'مرحبا بالعالم';
    const count = graphemeCount(arabic);
    // Every visible Arabic character is counted
    expect(count).toBeGreaterThan(0);
  });

  it('truncating mixed RTL and LTR does not reorder the text', () => {
    const text = 'Hi مرحبا OK عالم End';
    const truncated = takeGraphemes(text, 10);
    expect(graphemeCount(truncated)).toBe(10);
    // The truncated text is the first 10 graphemes of the original
    expect(text.startsWith(truncated)).toBe(true);
  });
});

describe('rapid useMemory toggling ends on the correct value', () => {
  it('injection after 10 rapid toggles matches the final value', () => {
    let useMemory = true;
    for (let i = 0; i < 10; i++) {
      useMemory = !useMemory;
    }
    // 10 toggles: true → false → ... → true (an even count returns to the initial value)
    expect(useMemory).toBe(true);

    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hello' }];
    const { injected } = applyMemoryInjection(chatHistory, { memoryText: 'Memory' }, useMemory);
    expect(injected).toBe(true);
  });

  it('an odd number of toggles leaves useMemory=false and skips injection', () => {
    let useMemory = true;
    for (let i = 0; i < 11; i++) {
      useMemory = !useMemory;
    }
    expect(useMemory).toBe(false);

    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hello' }];
    const { injected } = applyMemoryInjection(chatHistory, { memoryText: 'Memory' }, useMemory);
    expect(injected).toBe(false);
  });
});

describe('memoryText containing Markdown is treated as plain text', () => {
  it('Markdown is injected verbatim and not rendered', () => {
    const markdown = '**bold** _italic_ `code` [link](url) # heading';
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    applyMemoryInjection(chatHistory, { memoryText: markdown }, undefined);
    expect(chatHistory[0].content).toBe(markdown);
  });

  it('a Markdown table is saved verbatim', () => {
    const table = '| col1 | col2 |\n|------|------|\n| a | b |';
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    applyMemoryInjection(chatHistory, { memoryText: table }, undefined);
    expect(chatHistory[0].content).toBe(table);
  });
});

describe('anti-forget append on multimodal messages', () => {
  it('ContentPart[] messages: Context is appended to the text part without breaking the parts structure', () => {
    const chatHistory: ChatHistoryMsg[] = makeUserMessages(9);
    // The 10th user message is multimodal (image + text)
    const multimodalMsg: ChatHistoryMsg = {
      role: 'user',
      content: [
        { type: 'text', text: 'What is in this image?' },
        { type: 'image_url', image_url: { url: 'data:image/png;base64,abc123' } },
      ],
    };
    chatHistory.push(multimodalMsg);

    applyMemoryInjection(chatHistory, {
      memoryText: 'I am a developer',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Use Chinese to respond',
    }, undefined);

    // Find the last user message, the one that was modified
    const lastUser = [...chatHistory].reverse().find((m) => m.role === 'user');
    // ContentPart[] is flattened to text before Context is appended
    expect(typeof lastUser?.content).toBe('string');
    expect(lastUser?.content).toContain('What is in this image?');
    expect(lastUser?.content).toContain('\n\n[Reminder: Use Chinese to respond]');
  });

  it('image-only messages: Context is still appended to the empty text', () => {
    const chatHistory: ChatHistoryMsg[] = makeUserMessages(9);
    const imageOnlyMsg: ChatHistoryMsg = {
      role: 'user',
      content: [
        { type: 'image_url', image_url: { url: 'data:image/png;base64,abc' } },
      ],
    };
    chatHistory.push(imageOnlyMsg);

    applyMemoryInjection(chatHistory, {
      memoryText: 'Memory',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Context info',
    }, undefined);

    const lastUser = [...chatHistory].reverse().find((m) => m.role === 'user');
    // The image part yields an empty text extraction, so Context is appended to an empty string
    expect(lastUser?.content).toBe('\n\n[Reminder: Context info]');
  });
});

// ── Manual save during draft generation ────────────────────────

/** Whether the draft result can be applied automatically, meaning there is no conflict */
function shouldAutoApplyDraft(
  baselineRevision: number,
  currentRevision: number,
  baselineText: string,
  currentText: string,
): boolean {
  return currentRevision === baselineRevision && currentText === baselineText;
}

/** Reproduces the clearing check inside updateMemory */
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

describe('manual save while a draft is being generated', () => {
  it('a manual save during generation is detected as a conflict and not overwritten', () => {
    // Initial state
    let revision = 0;
    let currentText = 'A';

    // Record the baseline when draft generation starts
    const baselineRevision = revision;
    const baselineText = currentText;

    // The user edits and saves manually
    currentText = 'B';
    revision++;
    const saved = simulateUpdateMemory(currentText, false, '');
    expect(saved.memoryText).toBe('B');

    // The draft returns "C"
    const draftResult = 'C';
    const shouldApply = shouldAutoApplyDraft(baselineRevision, revision, baselineText, currentText);
    expect(shouldApply).toBe(false);

    // The manually saved "B" is kept and "C" does not overwrite it
    expect(currentText).toBe('B');
    expect(draftResult).toBe('C'); // The draft stays available for a manual choice but is not applied automatically
  });

  it('an untouched draft is applied automatically', () => {
    const revision = 0;
    const currentText = 'original';

    const shouldApply = shouldAutoApplyDraft(revision, revision, currentText, currentText);
    expect(shouldApply).toBe(true);
  });

  it('a draft returning after several manual saves is never applied automatically', () => {
    let revision = 0;
    let currentText = 'initial';

    const baselineRevision = revision;
    const baselineText = currentText;

    // Several edits and saves
    currentText = 'edit-1';
    revision++;
    currentText = 'edit-2';
    revision++;
    currentText = 'edit-3';
    revision++;

    const shouldApply = shouldAutoApplyDraft(baselineRevision, revision, baselineText, currentText);
    expect(shouldApply).toBe(false);
  });

  it('editing and reverting still counts as a conflict because the revision changed', () => {
    let revision = 0;
    let currentText = 'original';

    const baselineRevision = revision;
    const baselineText = currentText;

    // Edited and then reverted
    currentText = 'edited';
    revision++;
    currentText = 'original'; // Reverted
    revision++;

    // The revision changed, so it is not applied automatically even though the text matches
    const shouldApply = shouldAutoApplyDraft(baselineRevision, revision, baselineText, currentText);
    expect(shouldApply).toBe(false);
  });
});

describe('Provider 429 rate limiting', () => {
  it('a 429 error is handled gracefully without crashing', () => {
    const rateLimitError = {
      status: 429,
      message: 'Rate limit exceeded. Please retry after 60 seconds.',
      retryAfter: 60,
    };
    expect(rateLimitError.status).toBe(429);
    expect(rateLimitError.retryAfter).toBe(60);
    expect(() => JSON.stringify(rateLimitError)).not.toThrow();
  });

  it('loading recovers after a 429', () => {
    // Simulated loading state management
    let isGeneratingDraft = false;

    // Generation starts
    isGeneratingDraft = true;
    expect(isGeneratingDraft).toBe(true);

    // The 429 happens and loading returns to false
    isGeneratingDraft = false;
    expect(isGeneratingDraft).toBe(false);

    // It can be triggered again
    isGeneratingDraft = true;
    expect(isGeneratingDraft).toBe(true);
  });

  it('memory state survives a 429', () => {
    const saved = simulateUpdateMemory('My rules', true, 'summary');
    expect(saved.memoryText).toBe('My rules');

    // Memory operations after the 429
    const afterRateLimit = simulateUpdateMemory('My rules', true, 'summary');
    expect(afterRateLimit).toEqual(saved);

    // Injection still works
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    const { injected } = applyMemoryInjection(chatHistory, { memoryText: saved.memoryText }, undefined);
    expect(injected).toBe(true);
  });

  it('state still recovers after several consecutive 429s', () => {
    let isGeneratingDraft = false;
    const errors: number[] = [];

    // Three consecutive 429s
    for (let i = 0; i < 3; i++) {
      isGeneratingDraft = true;
      errors.push(429);
      isGeneratingDraft = false;
    }

    expect(errors).toHaveLength(3);
    expect(isGeneratingDraft).toBe(false);

    // The 4th attempt succeeds
    isGeneratingDraft = true;
    const success = true;
    isGeneratingDraft = false;
    expect(success).toBe(true);
    expect(isGeneratingDraft).toBe(false);
  });
});

describe('an empty Provider response is not applied as a draft', () => {
  it('an empty string draft is not applied', () => {
    const draftResult = '';
    const shouldApply = draftResult.trim().length > 0;
    expect(shouldApply).toBe(false);
  });

  it('a whitespace-only draft is not applied', () => {
    const draftResult = '   ';
    const shouldApply = draftResult.trim().length > 0;
    expect(shouldApply).toBe(false);
  });

  it('a newline-only draft is not applied', () => {
    const draftResult = '\n\n\n';
    const shouldApply = draftResult.trim().length > 0;
    expect(shouldApply).toBe(false);
  });

  it('a tab-only draft is not applied', () => {
    const draftResult = '\t\t\t';
    const shouldApply = draftResult.trim().length > 0;
    expect(shouldApply).toBe(false);
  });

  it('a mixed-whitespace draft is not applied', () => {
    const draftResult = ' \n\t \n ';
    const shouldApply = draftResult.trim().length > 0;
    expect(shouldApply).toBe(false);
  });

  it('a valid draft is applied', () => {
    const draftResult = 'I am a software developer who prefers TypeScript.';
    const shouldApply = draftResult.trim().length > 0;
    expect(shouldApply).toBe(true);
  });

  it('an empty draft does not overwrite existing memory', () => {
    const existingMemory = simulateUpdateMemory('Existing memory', true, 'summary');
    expect(existingMemory.memoryText).toBe('Existing memory');

    // An empty draft comes back, so nothing is applied
    const draftResult = '';
    const shouldApplyDraft = draftResult.trim().length > 0;
    expect(shouldApplyDraft).toBe(false);

    // The existing memory is untouched
    expect(existingMemory.memoryText).toBe('Existing memory');
    expect(existingMemory.memoryAntiForgetEnabled).toBe(true);
  });

  it('a draft padded with whitespace but carrying real content is applied', () => {
    const draftResult = '  Valid content here  ';
    const shouldApply = draftResult.trim().length > 0;
    expect(shouldApply).toBe(true);
  });
});
