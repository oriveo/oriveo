import { describe, it, expect } from 'vitest';
import {
  exportAsMarkdown,
  exportAsJSON,
  copyAllToClipboard,
  sanitizeFilename,
} from '../../utils/export-utils';
import type { Conversation } from '@oriveo/shared';

function makeConversation(): Conversation {
  return {
    id: 'c1',
    title: 'Test Chat',
    hasCustomTitle: false,
    providerID: 'p1',
    modelID: 'm1',
    previewText: 'Hello',
    estimatedCost: 0.001,
    isDraft: false,
    messages: [
      {
        id: 'msg1',
        role: 'user',
        text: 'Hello AI',
        providerKind: 'openAI',
        providerName: 'OpenAI',
        modelName: 'gpt-4o',
        estimatedCost: 0,
        state: 'delivered',
      },
      {
        id: 'msg2',
        role: 'assistant',
        text: 'Hello! How can I help?',
        providerKind: 'openAI',
        providerName: 'OpenAI',
        modelName: 'gpt-4o',
        estimatedCost: 0.001,
        state: 'delivered',
      },
    ],
    draftText: '',
    updatedAt: '2024-01-01T00:00:00.000Z',
  };
}

describe('exportAsMarkdown', () => {
  it('should generate markdown with title and messages', () => {
    const md = exportAsMarkdown(makeConversation());
    expect(md).toContain('# Test Chat');
    expect(md).toContain('## User');
    expect(md).toContain('Hello AI');
    expect(md).toContain('## Assistant');
    expect(md).toContain('Hello! How can I help?');
  });

  it('should include model info for assistant messages', () => {
    const md = exportAsMarkdown(makeConversation());
    expect(md).toContain('gpt-4o');
  });
});

describe('exportAsJSON', () => {
  it('should generate valid JSON', () => {
    const json = exportAsJSON(makeConversation());
    const parsed = JSON.parse(json);
    expect(parsed.title).toBe('Test Chat');
    expect(parsed.messages).toHaveLength(2);
    expect(parsed.messages[0].role).toBe('user');
    expect(parsed.messages[0].text).toBe('Hello AI');
  });
});

describe('sanitizeFilename', () => {
  it('should replace illegal characters', () => {
    expect(sanitizeFilename('file/name:test')).toBe('file-name-test');
  });

  it('should truncate to 100 chars', () => {
    const long = 'a'.repeat(200);
    expect(sanitizeFilename(long).length).toBe(100);
  });
});
