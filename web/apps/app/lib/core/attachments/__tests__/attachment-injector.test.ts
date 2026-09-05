import { describe, it, expect } from 'vitest';
import {
  AttachmentInjector,
  resolveWrapperVersion,
  type AttachmentPayload,
} from '../attachment-injector';
import type { ExtractedText } from '../file-text-extractor';
import { DEFAULT_LIMITS } from '../file-text-extractor';

const makeExtracted = (content: string, totalLines: number, truncated = false): ExtractedText => ({
  content,
  totalLines,
  truncated,
  truncationReason: truncated ? 'lines' : undefined,
  sizeBytes: content.length,
});

describe('AttachmentInjector.formatAttachment (xml-v1)', () => {
  it('formats plain text file with content', () => {
    const s = AttachmentInjector.formatAttachment('xml-v1', 1, {
      fileName: 'a.txt',
      mimeType: 'text/plain',
      sizeBytes: 11,
      extracted: makeExtracted('hello\nworld', 2),
    });
    expect(s).toContain('<FILE_INDEX>1</FILE_INDEX>');
    expect(s).toContain('<FILE_NAME>a.txt</FILE_NAME>');
    expect(s).toContain('<FILE_LINES>2</FILE_LINES>');
    expect(s).toContain('hello\nworld');
    expect(s).not.toContain('<TRUNCATED>');
  });

  it('formats truncated file', () => {
    const content = Array.from({ length: 500 }, (_, i) => `L${i + 1}`).join('\n');
    const s = AttachmentInjector.formatAttachment('xml-v1', 2, {
      fileName: 'big.md',
      mimeType: 'text/markdown',
      sizeBytes: 50000,
      extracted: makeExtracted(content, 700, true),
    });
    expect(s).toContain('<TRUNCATED>showing first 500 of 700 lines');
  });

  it('formats error (scanned_pdf)', () => {
    const s = AttachmentInjector.formatAttachment('xml-v1', 1, {
      fileName: 'p.pdf',
      mimeType: 'application/pdf',
      sizeBytes: 12345,
      extracted: null,
      errorCode: 'scanned_pdf',
    });
    expect(s).toContain('[ERROR: extraction failed - scanned_pdf]');
    expect(s).toContain('[INSTRUCTION:');
    expect(s).toContain('DO NOT fabricate');
  });

  it('formats D18 encrypted_pdf error', () => {
    const s = AttachmentInjector.formatAttachment('xml-v1', 1, {
      fileName: 'enc.pdf',
      mimeType: 'application/pdf',
      sizeBytes: 5000,
      extracted: null,
      errorCode: 'encrypted_pdf',
    });
    expect(s).toContain('encrypted_pdf');
    expect(s).toContain('decrypt');
  });
});

describe('AttachmentInjector.formatAttachment (markdown-v1)', () => {
  it('uses markdown format', () => {
    const s = AttachmentInjector.formatAttachment('markdown-v1', 1, {
      fileName: 'doc.pdf',
      mimeType: 'application/pdf',
      sizeBytes: 1000,
      extracted: makeExtracted('Some PDF text', 1),
    });
    expect(s).toContain('## Attachment 1: doc.pdf');
    expect(s).toContain('```');
    expect(s).toContain('Some PDF text');
  });
});

describe('AttachmentInjector.injectAll', () => {
  it('injects one file into userText', () => {
    const r = AttachmentInjector.injectAll('Summarize this', [
      {
        fileName: 'doc.txt',
        mimeType: 'text/plain',
        sizeBytes: 100,
        extracted: makeExtracted('Document content here', 1),
      },
    ]);
    expect(r.text).toContain('Summarize this');
    expect(r.text).toContain('<ATTACHMENT_FILE>');
    expect(r.skipped).toHaveLength(0);
  });

  it('skips when exceeding total cap', () => {
    // Derived from DEFAULT_LIMITS rather than hardcoded: when totalCap moved from 100KB to 200KB a
    // hardcoded 3x60KB=180KB stopped exceeding it (nothing was skipped) and nobody noticed. Taking
    // totalCap/2 gives 3 payloads at 1.5x the cap, which necessarily overflows while each single
    // payload stays under maxBytes, so the total-size rule is what gets exercised.
    const bigContent = 'x'.repeat(Math.ceil(DEFAULT_LIMITS.totalCap / 2));
    const payload: AttachmentPayload = {
      fileName: 'big.txt',
      mimeType: 'text/plain',
      sizeBytes: bigContent.length,
      extracted: makeExtracted(bigContent, 1),
    };
    const r = AttachmentInjector.injectAll('prompt', [
      { ...payload, fileName: 'a.txt' },
      { ...payload, fileName: 'b.txt' },
      { ...payload, fileName: 'c.txt' },
    ]);
    // At least some should be skipped due to the 200KB total cap
    expect(r.skipped.length).toBeGreaterThan(0);
    expect(r.skipped[0].reason).toBe('total_cap_exceeded');
  });

  it('skips when exceeding maxFiles=3', () => {
    const smallPayload: AttachmentPayload = {
      fileName: 'f.txt',
      mimeType: 'text/plain',
      sizeBytes: 10,
      extracted: makeExtracted('hi', 1),
    };
    const r = AttachmentInjector.injectAll('msg', [
      { ...smallPayload, fileName: 'a.txt' },
      { ...smallPayload, fileName: 'b.txt' },
      { ...smallPayload, fileName: 'c.txt' },
      { ...smallPayload, fileName: 'd.txt' }, // the fourth one should be skipped
    ]);
    expect(r.skipped).toHaveLength(1);
    expect(r.skipped[0].fileName).toBe('d.txt');
    expect(r.skipped[0].reason).toBe('too_many_files');
  });

  it('handles empty userText with file', () => {
    const r = AttachmentInjector.injectAll('', [
      {
        fileName: 'f.txt',
        mimeType: 'text/plain',
        sizeBytes: 5,
        extracted: makeExtracted('hello', 1),
      },
    ]);
    expect(r.text).toContain('<ATTACHMENT_FILE>');
    expect(r.skipped).toHaveLength(0);
  });
});

describe('resolveWrapperVersion', () => {
  it('returns markdown-v1 for DeepSeek', () => {
    expect(resolveWrapperVersion('deepseek')).toBe('markdown-v1');
  });
  it('returns xml-v1 for OpenAI', () => {
    expect(resolveWrapperVersion('openAI')).toBe('xml-v1');
  });
  it('returns xml-v1 for Anthropic', () => {
    expect(resolveWrapperVersion('anthropic')).toBe('xml-v1');
  });
  it('returns markdown-v1 for Qwen', () => {
    expect(resolveWrapperVersion('qwen')).toBe('markdown-v1');
  });
  it('returns markdown-v1 for Moonshot', () => {
    expect(resolveWrapperVersion('moonshot')).toBe('markdown-v1');
  });
});
