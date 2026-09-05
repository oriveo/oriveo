import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { ChatMessage } from '@oriveo/shared';

// Mock infra deps that need browser/storage context
vi.mock('../infra/storage/image-store', () => ({
  loadImageBase64: vi.fn().mockResolvedValue(null),
  // buildChatHistory  
  imageSizeBytes: vi.fn().mockResolvedValue(0),
}));

import { buildChatHistory } from './chat-stream-utils';

describe('buildChatHistory', () => {
  it('returns plain text message', async () => {
    const msgs: ChatMessage[] = [
      {
        id: '1',
        role: 'user',
        text: 'Hello',
        providerKind: 'openAI',
        providerName: 'OpenAI',
        modelID: 'gpt-4o',
        modelName: 'GPT-4o',
        estimatedCost: 0,
        state: 'delivered',
      },
    ];
    const result = await buildChatHistory(msgs);
    expect(result).toHaveLength(1);
    expect(result[0].role).toBe('user');
    expect(result[0].content).toBe('Hello');
  });

  it('wraps file attachment in ATTACHMENT_FILE block', async () => {
    const msgs: ChatMessage[] = [
      {
        id: '1',
        role: 'user',
        text: 'Read this',
        providerKind: 'openAI',
        providerName: 'OpenAI',
        modelID: 'gpt-4o',
        modelName: 'GPT-4o',
        estimatedCost: 0,
        state: 'delivered',
        attachments: [
          {
            id: 'att1',
            kind: 'file',
            fileName: 'doc.txt',
            mimeType: 'text/plain',
            base64Data: 'Hello document content',
            extractedTotalLines: 1,
          },
        ],
      },
    ];
    const result = await buildChatHistory(msgs);
    expect(result).toHaveLength(1);
    const content = result[0].content;
    expect(Array.isArray(content)).toBe(true);
    const textPart = (content as Array<{ type: string; text?: string }>).find((p) => p.type === 'text');
    expect(textPart?.text).toContain('<ATTACHMENT_FILE>');
    expect(textPart?.text).toContain('doc.txt');
    expect(textPart?.text).toContain('Hello document content');
  });

  it('uses markdown-v1 for DeepSeek provider', async () => {
    const msgs: ChatMessage[] = [
      {
        id: '1',
        role: 'user',
        text: 'Summarize',
        providerKind: 'deepseek',
        providerName: 'DeepSeek',
        modelID: 'deepseek-chat',
        modelName: 'DeepSeek Chat',
        estimatedCost: 0,
        state: 'delivered',
        attachments: [
          {
            id: 'att1',
            kind: 'file',
            fileName: 'report.md',
            mimeType: 'text/markdown',
            base64Data: 'Report data here',
            extractedTotalLines: 1,
          },
        ],
      },
    ];
    const result = await buildChatHistory(msgs, undefined, 'deepseek');
    const content = result[0].content;
    const textPart = (content as Array<{ type: string; text?: string }>).find((p) => p.type === 'text');
    expect(textPart?.text).toContain('## Attachment 1: report.md');
    expect(textPart?.text).not.toContain('<ATTACHMENT_FILE>');
  });

  it('keeps PDF as file part when scanned_pdf + model has native_pdf', async () => {
    const msgs: ChatMessage[] = [
      {
        id: '1',
        role: 'user',
        text: 'OCR this',
        providerKind: 'anthropic',
        providerName: 'Anthropic',
        modelID: 'claude-sonnet-4-5',
        modelName: 'Claude Sonnet',
        estimatedCost: 0,
        state: 'delivered',
        attachments: [
          {
            id: 'att1',
            kind: 'file',
            fileName: 'scan.pdf',
            mimeType: 'application/pdf',
            base64Data: '',
            originalBase64Data: 'FAKE_PDF_BASE64',
            extractionErrorCode: 'scanned_pdf',
          },
        ],
      },
    ];
    // v3.1: capabilities.native_pdf feeds metadata.nativeFileMimes, which drives the router
    const model = {
      id: 'claude-sonnet-4-5',
      capabilities: ['text', 'image'],
      nativeFileMimes: ['application/pdf'],
    } as any;
    const result = await buildChatHistory(msgs, model, 'anthropic');
    const content = result[0].content;
    expect(Array.isArray(content)).toBe(true);
    const filePart = (content as Array<{ type: string }>).find((p) => p.type === 'file');
    expect(filePart).toBeDefined();
  });

  it('wraps scanned_pdf in error block when model lacks native_pdf', async () => {
    const msgs: ChatMessage[] = [
      {
        id: '1',
        role: 'user',
        text: 'Read PDF',
        providerKind: 'deepseek',
        providerName: 'DeepSeek',
        modelID: 'deepseek-chat',
        modelName: 'DeepSeek Chat',
        estimatedCost: 0,
        state: 'delivered',
        attachments: [
          {
            id: 'att1',
            kind: 'file',
            fileName: 'scan.pdf',
            mimeType: 'application/pdf',
            base64Data: '',
            originalBase64Data: 'FAKE_PDF_BASE64',
            extractionErrorCode: 'scanned_pdf',
          },
        ],
      },
    ];
    // model without native_pdf
    const model = { id: 'deepseek-chat', capabilities: ['text'] } as any;
    const result = await buildChatHistory(msgs, model, 'deepseek');
    const content = result[0].content;
    const textPart = (content as Array<{ type: string; text?: string }>).find((p) => p.type === 'text');
    expect(textPart?.text).toContain('scanned_pdf');
    expect(textPart?.text).not.toContain('FAKE_PDF_BASE64');
    // No file part (no native fallback)
    const filePart = (content as Array<{ type: string }>).find((p) => p.type === 'file');
    expect(filePart).toBeUndefined();
  });

  it('handles OpenAI messages with attachment in ATTACHMENT_FILE block', async () => {
    const msgs: ChatMessage[] = [
      {
        id: '1',
        role: 'user',
        text: 'summarize',
        providerKind: 'openAI',
        providerName: 'OpenAI',
        modelID: 'gpt-4.1',
        modelName: 'GPT-4.1',
        estimatedCost: 0,
        state: 'delivered',
        attachments: [
          {
            id: 'att1',
            kind: 'file',
            fileName: 'doc.txt',
            mimeType: 'text/plain',
            base64Data: 'hello',
          },
        ],
      },
    ];
    const result = await buildChatHistory(msgs, undefined, 'openAI');
    const content = result[0].content;
    const textPart = (content as Array<{ type: string; text?: string }>).find((p) => p.type === 'text');
    expect(textPart?.text).toContain('<ATTACHMENT_FILE>');
  });
});
