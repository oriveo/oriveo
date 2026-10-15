/**
 * Memory in the conversation pipeline and in each provider's request shape.
 *
 * Covers:
 * - Memory injected as a system message for new and continued conversations
 * - useMemory = false blocks injection
 * - Empty or whitespace-only memoryText is not injected
 * - Anti-forget is no longer injected: even with the preference on, no [Reminder: ...] is appended
 * - retry/edit-resend use the current memory text
 * - Where each provider adapter places the system message
 */
import { describe, it, expect } from 'vitest';
import type { AppPreference } from '@oriveo/shared';
import type { ContentPart } from '../../providers/types';

// Testable pure functions extracted from operations.ts

type ChatHistoryMsg = { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] };

/**
 * Mirrors the Memory injection logic in operations.ts sendMessage.
 * Returns the injection state.
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

// Helpers

function makeUserMessages(count: number): ChatHistoryMsg[] {
  const msgs: ChatHistoryMsg[] = [];
  for (let i = 0; i < count; i++) {
    msgs.push({ role: 'user', content: `Question ${i + 1}` });
    msgs.push({ role: 'assistant', content: `Answer ${i + 1}` });
  }
  return msgs;
}

/**
 * Simulates request building for OpenAI/OpenRouter/Groq/Together/Fireworks/Relay,
 * which put the system message directly at messages[0].
 */
function buildOpenAIRequest(messages: ChatHistoryMsg[]): { messages: ChatHistoryMsg[] } {
  return { messages: [...messages] };
}

/**
 * Simulates Anthropic request building: the system role is lifted out of messages
 * into the body.system field.
 */
function buildAnthropicRequest(messages: ChatHistoryMsg[]): {
  system?: string;
  messages: { role: 'user' | 'assistant'; content: string | ContentPart[] }[];
} {
  let systemText: string | undefined;
  const apiMessages = messages
    .filter((m) => {
      if (m.role === 'system') {
        systemText = typeof m.content === 'string'
          ? m.content
          : m.content.filter((p) => p.type === 'text').map((p) => (p as { type: 'text'; text: string }).text).join('\n');
        return false;
      }
      return true;
    })
    .map((m) => ({
      role: m.role as 'user' | 'assistant',
      content: m.content,
    }));

  return { system: systemText, messages: apiMessages };
}

/**
 * Simulates Gemini request building: the system role is lifted out of messages
 * into body.systemInstruction.
 */
function buildGeminiRequest(messages: ChatHistoryMsg[]): {
  systemInstruction?: { parts: { text: string }[] };
  contents: { role: 'user' | 'model'; parts: { text: string }[] }[];
} {
  const systemTexts = messages
    .filter((m) => m.role === 'system')
    .map((m) => typeof m.content === 'string'
      ? m.content
      : m.content.map((p) => p.type === 'text' ? (p as { type: 'text'; text: string }).text : '').join(''),
    )
    .filter(Boolean);

  const contents = messages
    .filter((m) => m.role !== 'system')
    .map((m) => ({
      role: (m.role === 'assistant' ? 'model' : 'user') as 'user' | 'model',
      parts: [{ text: typeof m.content === 'string' ? m.content : '' }],
    }));

  return {
    systemInstruction: systemTexts.length > 0 ? { parts: [{ text: systemTexts.join('\n\n') }] } : undefined,
    contents,
  };
}

describe('new conversation first message — Memory injected as system message at position 0', () => {
  it('non-empty memoryText with default useMemory is injected as chatHistory[0] system', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello, this is my first message' },
    ];
    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'I am a senior Go engineer. I prefer concise responses.',
    }, undefined);

    expect(result.injected).toBe(true);
    expect(chatHistory[0]).toEqual({
      role: 'system',
      content: 'I am a senior Go engineer. I prefer concise responses.',
    });
    expect(chatHistory[1].role).toBe('user');
    expect(chatHistory).toHaveLength(2);
  });
});

describe('existing conversation continue — Memory continues to inject', () => {
  it('injects Memory at the front of an existing multi-turn conversation', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'First question' },
      { role: 'assistant', content: 'First answer' },
      { role: 'user', content: 'Follow-up question' },
    ];
    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'Always respond in bullet points',
    }, undefined);

    expect(result.injected).toBe(true);
    expect(chatHistory[0].role).toBe('system');
    expect(chatHistory[0].content).toBe('Always respond in bullet points');
    expect(chatHistory).toHaveLength(4);
  });
});

describe('useMemory = false — no injection', () => {
  it('does not inject a system message when useMemory = false', () => {
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

  it('does not inject when useMemory = false even with the anti-forget preference on', () => {
    const chatHistory = makeUserMessages(10);
    chatHistory.push({ role: 'user', content: 'Latest' });

    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'I am a Go engineer',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Summary',
    }, false);

    expect(result.injected).toBe(false);
  });
});

describe('empty/whitespace-only memory — no injection, no indicator', () => {
  it('does not inject an empty string', () => {
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    const result = applyMemoryInjection(chatHistory, { memoryText: '' }, undefined);
    expect(result.injected).toBe(false);
  });

  it('does not inject whitespace only', () => {
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    const result = applyMemoryInjection(chatHistory, { memoryText: '   ' }, undefined);
    expect(result.injected).toBe(false);
  });

  it('does not inject newlines only', () => {
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    const result = applyMemoryInjection(chatHistory, { memoryText: '\n\t\r' }, undefined);
    expect(result.injected).toBe(false);
  });

  it('does not inject undefined memoryText', () => {
    const chatHistory: ChatHistoryMsg[] = [{ role: 'user', content: 'Hi' }];
    const result = applyMemoryInjection(chatHistory, {}, undefined);
    expect(result.injected).toBe(false);
  });
});

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

describe('retry/regenerate uses current latest Memory', () => {
  it('retry re-injects the memoryText that is current at injection time', () => {
    // retry calls sendMessage, which reads the current memoryText from store.getState().preferences.
    // Simulated here: send with the old memory, update it, then retry.

    // Memory used by the first send
    const chatHistory1: ChatHistoryMsg[] = [{ role: 'user', content: 'Hello' }];
    applyMemoryInjection(chatHistory1, { memoryText: 'Old memory' }, undefined);
    expect(chatHistory1[0].content).toBe('Old memory');

    // Retry uses the updated Memory, with chatHistory rebuilt
    const chatHistory2: ChatHistoryMsg[] = [{ role: 'user', content: 'Hello' }];
    applyMemoryInjection(chatHistory2, { memoryText: 'Updated memory' }, undefined);
    expect(chatHistory2[0].content).toBe('Updated memory');
  });
});

describe('continue/edit & resend follows Memory rules', () => {
  it('edit and resend uses the current Memory', () => {
    // editAndResend ends up in sendMessage, so the injection logic is the same
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Edited message' },
    ];
    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'Current memory',
    }, undefined);

    expect(result.injected).toBe(true);
    expect(chatHistory[0].content).toBe('Current memory');
    expect(chatHistory[1].content).toBe('Edited message');
  });

  it('edit and resend still does not inject when useMemory = false', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Edited message' },
    ];
    const result = applyMemoryInjection(chatHistory, {
      memoryText: 'Current memory',
    }, false);

    expect(result.injected).toBe(false);
    expect(chatHistory).toHaveLength(1);
  });
});

describe('OpenAI/OpenRouter/Groq/Together/Fireworks/Relay — messages[0] is system', () => {
  it('messages[0].role === system after Memory injection', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello' },
    ];
    applyMemoryInjection(chatHistory, { memoryText: 'I am an engineer' }, undefined);

    const request = buildOpenAIRequest(chatHistory);
    expect(request.messages[0].role).toBe('system');
    expect(request.messages[0].content).toBe('I am an engineer');
    expect(request.messages[1].role).toBe('user');
  });

  it('messages[0] is not system without Memory', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello' },
    ];
    applyMemoryInjection(chatHistory, {}, undefined);

    const request = buildOpenAIRequest(chatHistory);
    expect(request.messages[0].role).toBe('user');
  });
});

describe('Anthropic — system field separate from messages', () => {
  it('lifts the system field out so messages carries no system role', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello' },
    ];
    applyMemoryInjection(chatHistory, { memoryText: 'I prefer Rust' }, undefined);

    const request = buildAnthropicRequest(chatHistory);
    expect(request.system).toBe('I prefer Rust');
    expect(request.messages.every((m) => m.role !== 'system')).toBe(true);
    expect(request.messages[0].role).toBe('user');
  });

  it('system field is undefined without Memory', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello' },
    ];
    applyMemoryInjection(chatHistory, {}, undefined);

    const request = buildAnthropicRequest(chatHistory);
    expect(request.system).toBeUndefined();
  });
});

// ── Gemini → systemInstruction.parts[0].text ────

describe('Gemini — systemInstruction.parts[0].text', () => {
  it('systemInstruction contains the Memory text after injection', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello' },
    ];
    applyMemoryInjection(chatHistory, { memoryText: 'I love Python' }, undefined);

    const request = buildGeminiRequest(chatHistory);
    expect(request.systemInstruction).toBeDefined();
    expect(request.systemInstruction!.parts[0].text).toBe('I love Python');
    // contents carries no system role
    expect(request.contents.every((c) => c.role !== 'system' as string)).toBe(true);
  });

  it('systemInstruction is undefined without Memory', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello' },
    ];
    applyMemoryInjection(chatHistory, {}, undefined);

    const request = buildGeminiRequest(chatHistory);
    expect(request.systemInstruction).toBeUndefined();
  });
});

// The Responses API is not used here (only Chat Completions); this checks that an
// instructions field would be populated from the injected Memory.

describe('OpenAI Responses API — instructions field (future-proof)', () => {
  it('the injected system message can be extracted into an instructions field', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Hello' },
    ];
    applyMemoryInjection(chatHistory, { memoryText: 'Be concise' }, undefined);

    // Simulate the Responses API by extracting the system message as instructions
    const systemMsg = chatHistory.find((m) => m.role === 'system');
    const instructions = systemMsg ? (typeof systemMsg.content === 'string' ? systemMsg.content : '') : undefined;

    expect(instructions).toBe('Be concise');
  });
});

describe('Edge case: Memory injection with existing system messages', () => {
  it('Memory is unshifted in front of an existing system message', () => {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'system', content: 'Existing system prompt' },
      { role: 'user', content: 'Hello' },
    ];
    applyMemoryInjection(chatHistory, { memoryText: 'Memory context' }, undefined);

    expect(chatHistory[0].content).toBe('Memory context');
    expect(chatHistory[1].content).toBe('Existing system prompt');
    expect(chatHistory).toHaveLength(3);
  });
});

describe('Cross-provider: Memory system message handling consistency', () => {
  const memoryText = 'I am an engineer who prefers TypeScript';

  function getInjectedHistory(): ChatHistoryMsg[] {
    const chatHistory: ChatHistoryMsg[] = [
      { role: 'user', content: 'Explain closures' },
      { role: 'assistant', content: 'A closure is...' },
      { role: 'user', content: 'Show me an example' },
    ];
    applyMemoryInjection(chatHistory, { memoryText }, undefined);
    return chatHistory;
  }

  it('OpenAI: system at position 0', () => {
    const req = buildOpenAIRequest(getInjectedHistory());
    expect(req.messages[0]).toEqual({ role: 'system', content: memoryText });
  });

  it('Anthropic: system extracted to separate field', () => {
    const req = buildAnthropicRequest(getInjectedHistory());
    expect(req.system).toBe(memoryText);
    expect(req.messages.length).toBe(3); // no system role
  });

  it('Gemini: systemInstruction populated', () => {
    const req = buildGeminiRequest(getInjectedHistory());
    expect(req.systemInstruction!.parts[0].text).toBe(memoryText);
    expect(req.contents.length).toBe(3); // no system role
  });
});
