import { describe, it, expect } from 'vitest';
import type { Provider, AIModel, Attachment } from '@oriveo/shared';
import { createUserMessage, createAssistantMessage, createNewConversation } from '../message-factory';

const mockProvider: Provider = {
  id: 'p1', kind: 'openRouter', name: 'OpenRouter',
  apiKey: 'sk-test', apiKeyPreview: 'sk-...test',
  status: { kind: 'connected' },
  models: [], catalogModels: [],
  createdAt: '', updatedAt: '',
};

const relayProvider: Provider = {
  ...mockProvider, id: 'p2', kind: 'relay', name: 'Relay', customName: 'My Relay',
};

const mockModel: AIModel = {
  id: 'gpt-4', name: 'GPT-4', capabilities: ['text'],
  reasoningModeAvailable: false, isAvailable: true, isDefault: false,
  priceTier: '$$', groupKey: 'openai', groupName: 'OpenAI',
};

describe('message-factory', () => {
  describe('createUserMessage', () => {
    it('builds a plain text message', () => {
      const msg = createUserMessage({ text: 'Hello', provider: mockProvider, model: mockModel });
      expect(msg.role).toBe('user');
      expect(msg.text).toBe('Hello');
      expect(msg.state).toBe('delivered');
      expect(msg.providerKind).toBe('openRouter');
      expect(msg.modelName).toBe('GPT-4');
      expect(msg.id).toBeTruthy();
      expect(msg.createdAt).toBeTruthy();
    });

    it('keeps attachments', () => {
      const att: Attachment = { id: 'a1', kind: 'image', fileName: 'pic.png', mimeType: 'image/png' };
      const msg = createUserMessage({ text: 'Look', provider: mockProvider, model: mockModel, attachments: [att] });
      expect(msg.attachments).toHaveLength(1);
      expect(msg.attachments![0].id).toBe('a1');
    });

    it('a relay provider shows its customName', () => {
      const msg = createUserMessage({ text: 'Hi', provider: relayProvider, model: mockModel });
      expect(msg.providerName).toBe('My Relay');
    });

    it('an empty attachments array leaves attachments unset', () => {
      const msg = createUserMessage({ text: 'Hi', provider: mockProvider, model: mockModel, attachments: [] });
      expect(msg.attachments).toBeUndefined();
    });

    it('keeps a valid QuoteContext snapshot while message text stays the raw input', () => {
      const quoteContext = {
        schemaVersion: 1 as const,
        sourceMessageId: 'source-1',
        sourceRole: 'assistant' as const,
        contentKind: 'code' as const,
        leadingText: 'const ',
        selectedText: 'answer = 42',
        trailingText: ';',
        contextTruncated: false,
      };
      const msg = createUserMessage({
        text: 'Explain this', provider: mockProvider, model: mockModel, quoteContext,
      });
      expect(msg.text).toBe('Explain this');
      expect(msg.quoteContext).toEqual(quoteContext);
    });
  });

  describe('createAssistantMessage', () => {
    it('starts in the generating state', () => {
      const msg = createAssistantMessage({ provider: mockProvider, model: mockModel });
      expect(msg.role).toBe('assistant');
      expect(msg.state).toBe('generating');
      expect(msg.text).toBe('');
      expect(msg.estimatedCost).toBe(0);
    });

    it('with baseCreatedAt, createdAt is exactly 1ms after the base, so a millisecond collision cannot destabilise ordering', () => {
      const baseISO = '2026-03-19T10:00:00.000Z';
      const msg = createAssistantMessage({ provider: mockProvider, model: mockModel, baseCreatedAt: baseISO });
      const baseMs = new Date(baseISO).getTime();
      const assistantMs = new Date(msg.createdAt!).getTime();
      expect(assistantMs - baseMs).toBe(1);
    });

    it('without baseCreatedAt, createdAt uses the current time', () => {
      const before = Date.now();
      const msg = createAssistantMessage({ provider: mockProvider, model: mockModel });
      const after = Date.now();
      const assistantMs = new Date(msg.createdAt!).getTime();
      expect(assistantMs).toBeGreaterThanOrEqual(before);
      expect(assistantMs).toBeLessThanOrEqual(after);
    });
  });

  describe('createNewConversation', () => {
    it('title follows the auto-title rule and preview follows the full preview rule', () => {
      const longText = 'A'.repeat(100);
      const userMessage = createUserMessage({ text: longText, provider: mockProvider, model: mockModel });
      const conv = createNewConversation({
        provider: mockProvider,
        model: mockModel,
        userMessage,
        messages: [userMessage],
      });
      expect(conv.title).toBe('A'.repeat(50));
      expect(conv.previewText).toBe('A'.repeat(100));
    });

    it('carries the right providerID/modelID', () => {
      const userMessage = createUserMessage({ text: 'Hello', provider: mockProvider, model: mockModel });
      const conv = createNewConversation({
        provider: mockProvider,
        model: mockModel,
        userMessage,
        messages: [userMessage],
      });
      expect(conv.providerID).toBe('p1');
      expect(conv.modelID).toBe('gpt-4');
      expect(conv.isDraft).toBe(false);
      expect(conv.hasCustomTitle).toBe(false);
    });

    it('an attachment-only message takes its title and preview from the user message summary', () => {
      const userMessage = createUserMessage({
        text: '',
        provider: mockProvider,
        model: mockModel,
        attachments: [{ id: 'file-1', kind: 'file', fileName: 'report.pdf', mimeType: 'application/pdf' }],
      });
      const conv = createNewConversation({
        provider: mockProvider,
        model: mockModel,
        userMessage,
        messages: [userMessage],
      });
      expect(conv.title).toBe('📎 report.pdf');
      expect(conv.previewText).toBe('📎 report.pdf');
    });

    it('a markdown user message yields a de-marked title and preview', () => {
      const userMessage = createUserMessage({
        text: '# Plan\nHere is a **clear, actionable** approach',
        provider: mockProvider,
        model: mockModel,
      });
      const conv = createNewConversation({
        provider: mockProvider,
        model: mockModel,
        userMessage,
        messages: [userMessage],
      });
      expect(conv.title).toBe('Plan Here is a clear, actionable approach');
      expect(conv.previewText).toBe('Plan Here is a clear, actionable approach');
    });

    it('stores a redundant providerKind so the list icon does not depend on providers.find()', () => {
      const userMessage = createUserMessage({ text: 'hi', provider: mockProvider, model: mockModel });
      const conv = createNewConversation({
        provider: mockProvider,
        model: mockModel,
        userMessage,
        messages: [userMessage],
      });
      expect(conv.providerKind).toBe('openRouter');
      expect(conv.relayKind).toBeUndefined();
    });

    it('a relay provider stores both providerKind and relayKind for brand logo lookup', () => {
      const relayWithKind: Provider = { ...relayProvider, relayKind: 'gemini_compatible' };
      const userMessage = createUserMessage({ text: 'hi', provider: relayWithKind, model: mockModel });
      const conv = createNewConversation({
        provider: relayWithKind,
        model: mockModel,
        userMessage,
        messages: [userMessage],
      });
      expect(conv.providerKind).toBe('relay');
      expect(conv.relayKind).toBe('gemini_compatible');
    });

    it('normalises pending pinnedNoteIds, deduping and keeping the last three', () => {
      const userMessage = createUserMessage({ text: 'hi', provider: mockProvider, model: mockModel });
      const conv = createNewConversation({
        provider: mockProvider,
        model: mockModel,
        userMessage,
        messages: [userMessage],
        pinnedNoteIds: [
          '550e8400-e29b-41d4-a716-446655440000',
          '550E8400-E29B-41D4-A716-446655440000',
          'note-a',
          'note-b',
          'note-c',
        ],
      });

      // Dedupe first-seen -> [550E..., note-a, note-b, note-c], then keep the last 3
      expect(conv.pinnedNoteIds).toEqual([
        'note-a',
        'note-b',
        'note-c',
      ]);
    });
  });
});
