import { describe, it, expect } from 'vitest';
import { searchConversation, highlightText } from '../../utils/search-utils';
import type { ChatMessage } from '@oriveo/shared';

function makeMsg(text: string, id = 'msg1'): ChatMessage {
  return {
    id,
    role: 'user',
    text,
    providerKind: 'openAI',
    providerName: 'OpenAI',
    modelName: 'gpt-4o',
    estimatedCost: 0,
    state: 'delivered',
  };
}

describe('searchConversation', () => {
  it('should return empty for empty query', () => {
    const result = searchConversation([makeMsg('hello world')], '');
    expect(result).toHaveLength(0);
  });

  it('should find single match', () => {
    const result = searchConversation([makeMsg('hello world')], 'hello');
    expect(result).toHaveLength(1);
    expect(result[0].ranges).toHaveLength(1);
    expect(result[0].ranges[0]).toEqual({ start: 0, end: 5 });
  });

  it('should find multiple matches in one message', () => {
    const result = searchConversation([makeMsg('hello hello')], 'hello');
    expect(result[0].ranges).toHaveLength(2);
  });

  it('should find matches across messages', () => {
    const msgs = [
      makeMsg('hello world', 'm1'),
      makeMsg('goodbye world', 'm2'),
      makeMsg('hello again', 'm3'),
    ];
    const result = searchConversation(msgs, 'hello');
    expect(result).toHaveLength(2);
  });

  it('should be case insensitive', () => {
    const result = searchConversation([makeMsg('Hello World')], 'hello');
    expect(result).toHaveLength(1);
  });
});

describe('highlightText', () => {
  it('should return unhighlighted text for no ranges', () => {
    const parts = highlightText('hello world', []);
    expect(parts).toEqual([{ text: 'hello world', highlighted: false }]);
  });

  it('should split text around highlights', () => {
    const parts = highlightText('hello world', [{ start: 0, end: 5 }]);
    expect(parts).toEqual([
      { text: 'hello', highlighted: true },
      { text: ' world', highlighted: false },
    ]);
  });

  it('should handle multiple ranges', () => {
    const parts = highlightText('hello hello', [
      { start: 0, end: 5 },
      { start: 6, end: 11 },
    ]);
    expect(parts).toHaveLength(3);
    expect(parts[0]).toEqual({ text: 'hello', highlighted: true });
    expect(parts[1]).toEqual({ text: ' ', highlighted: false });
    expect(parts[2]).toEqual({ text: 'hello', highlighted: true });
  });
});
