import { describe, it, expect } from 'vitest';
import {
  AttachmentInjector,
  attachmentTextBudgetBytes,
  type AttachmentPayload,
} from '../attachment-injector';
import { attachmentTransportProfile } from '@oriveo/core/providers/attachment-transport';
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
    // The marker carries neither a size cap nor a reason
    expect(s).toContain('<TRUNCATED>showing first 500 of 700 lines</TRUNCATED>');
    expect(s).not.toContain('200KB');
  });

  it('the marker carries no size cap when the truncation reason is bytes either', () => {
    const content = Array.from({ length: 300 }, (_, i) => `L${i + 1}`).join('\n');
    const extracted = { ...makeExtracted(content, 700, true), truncationReason: 'bytes' as const };
    const payload = { fileName: 'big.md', mimeType: 'text/markdown', sizeBytes: 50000, extracted };
    expect(AttachmentInjector.formatAttachment('xml-v1', 1, payload))
      .toContain('<TRUNCATED>showing first 300 of 700 lines</TRUNCATED>');
    expect(AttachmentInjector.formatAttachment('markdown-v1', 1, payload))
      .toContain('- Lines: 700 (showing first 300)\n');
  });

  // The payload rebuilt from a persisted attachment at send time has only the truncated flag, no reason.
  // This case used to emit nothing, and the model took the first 500 lines for the whole file.
  it('still emits the TRUNCATED marker (generic wording) when truncated but the reason is missing', () => {
    const content = Array.from({ length: 500 }, (_, i) => `L${i + 1}`).join('\n');
    const s = AttachmentInjector.formatAttachment('xml-v1', 1, {
      fileName: 'big.md',
      mimeType: 'text/markdown',
      sizeBytes: 50000,
      extracted: { ...makeExtracted(content, 700, true), truncationReason: undefined },
    });
    expect(s).toContain('<TRUNCATED>showing first 500 of 700 lines</TRUNCATED>');
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

describe('AttachmentInjector.formatAttachment (markdown-v1) truncation note', () => {
  it('likewise says only the first N lines were given when truncated but the reason is missing', () => {
    const content = Array.from({ length: 500 }, (_, i) => `L${i + 1}`).join('\n');
    const s = AttachmentInjector.formatAttachment('markdown-v1', 1, {
      fileName: 'big.md',
      mimeType: 'text/markdown',
      sizeBytes: 50000,
      extracted: { ...makeExtracted(content, 700, true), truncationReason: undefined },
    });
    expect(s).toContain('- Lines: 700 (showing first 500)\n');
    expect(s).not.toContain('200KB');
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

  // The per-file extraction cap (maxBytes) and the total budget (totalCap) are the same number.
  // If the budget also counted the wrapper header, a file that just fits the extraction cap
  // could never fit and would be skipped whole, silently.
  it.each(['xml-v1', 'markdown-v1'] as const)(
    'injects a single file whose content is exactly the extraction cap (%s)',
    (wrapper) => {
      expect(DEFAULT_LIMITS.maxBytes).toBe(DEFAULT_LIMITS.totalCap);
      const content = 'x'.repeat(DEFAULT_LIMITS.maxBytes);
      const r = AttachmentInjector.injectAll('prompt', [{
        fileName: 'full.txt',
        mimeType: 'text/plain',
        sizeBytes: content.length,
        extracted: makeExtracted(content, 1, true),
      }], DEFAULT_LIMITS, wrapper);
      expect(r.skipped).toEqual([]);
      expect(r.text).toContain(content);
    },
  );

  it('counts multi-byte content in UTF-8 bytes, not UTF-16 length', () => {
    // U+4E2D is 3 bytes in UTF-8: content that exactly fills the budget is allowed, one more character is skipped.
    const fits = '\u4e2d'.repeat(Math.floor(DEFAULT_LIMITS.totalCap / 3));
    const payload = (content: string): AttachmentPayload => ({
      fileName: 'cjk.txt', mimeType: 'text/plain', sizeBytes: content.length, extracted: makeExtracted(content, 1),
    });
    expect(attachmentTextBudgetBytes(fits)).toBeLessThanOrEqual(DEFAULT_LIMITS.totalCap);
    expect(AttachmentInjector.injectAll('', [payload(fits)]).skipped).toEqual([]);
    expect(AttachmentInjector.injectAll('', [payload(`${fits}\u4e2d`)]).skipped).toEqual([
      { fileName: 'cjk.txt', reason: 'total_cap_exceeded' },
    ]);
  });

  it('skips the second of two 150KB files and keeps the first', () => {
    const content = 'x'.repeat(150 * 1024);
    const payload: AttachmentPayload = {
      fileName: 'a.txt', mimeType: 'text/plain', sizeBytes: content.length, extracted: makeExtracted(content, 1),
    };
    const r = AttachmentInjector.injectAll('prompt', [payload, { ...payload, fileName: 'b.txt' }]);
    expect(r.skipped).toEqual([{ fileName: 'b.txt', reason: 'total_cap_exceeded' }]);
    expect(r.text).toContain('<FILE_NAME>a.txt</FILE_NAME>');
    expect(r.text).not.toContain('b.txt');
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

describe('the wrapper format is decided by the line declaration', () => {
  it('Chinese-vendor Chat lines use markdown-v1', () => {
    for (const transport of ['deepseek_chat', 'qwen_chat', 'moonshot_chat', 'moonshot_browser_direct', 'zhipu_chat', 'minimax_chat', 'minimax_anthropic_messages', 'siliconflow_chat'] as const) {
      expect(attachmentTransportProfile(transport).wrapper).toBe('markdown-v1');
    }
  });
  it('all other lines use xml-v1', () => {
    for (const transport of ['openai_chat', 'openai_responses', 'anthropic_messages', 'gemini_generate', 'openrouter_chat', 'relay_openai_chat', 'relay_llamacpp_native'] as const) {
      expect(attachmentTransportProfile(transport).wrapper).toBe('xml-v1');
    }
  });
});
