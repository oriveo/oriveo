/**
 * Pre-send check: which attachments the injector would skip at send time.
 *
 * The check and outbound-history building share resolveFileAttachmentDelivery; that "the check result matches
 * what is actually sent" is asserted in chat-stream-utils.test.ts against the real output of buildChatHistory.
 */
import { describe, expect, it } from 'vitest';
import type { AIModel, Attachment } from '@oriveo/shared';
import { findUnsendableTextAttachments, resolveFileAttachmentDelivery } from '../attachment-delivery';
import { AttachmentInjector, type AttachmentPayload } from '../attachment-injector';
import { DEFAULT_LIMITS, resolveFileExtractionLimits } from '../file-text-extractor';

const PDF = 'application/pdf';
const KB = 1024;

function model(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: 'model-1',
    name: 'Model 1',
    capabilities: ['text', 'file'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: '$',
    ...overrides,
  } as AIModel;
}

const textFile = (fileName: string, bytes: number): Attachment => ({
  id: fileName,
  kind: 'file',
  fileName,
  mimeType: 'text/plain',
  base64Data: 'x'.repeat(bytes),
});

const pdf = (fileName: string, extractedBytes: number): Attachment => ({
  id: fileName,
  kind: 'file',
  fileName,
  mimeType: PDF,
  base64Data: 'x'.repeat(extractedBytes),
  originalBase64Data: 'JVBERi0=',
  extractedSizeBytes: 4096,
});

describe('findUnsendableTextAttachments', () => {
  it('no attachments, or all of them fit: empty result', () => {
    expect(findUnsendableTextAttachments(undefined, model(), 'openAI')).toEqual([]);
    expect(findUnsendableTextAttachments([textFile('a.txt', 100 * KB), textFile('b.txt', 100 * KB)], model(), 'openAI'))
      .toEqual([]);
  });

  it('two texts summing past the total budget: reports the one that does not fit', () => {
    expect(findUnsendableTextAttachments([textFile('a.txt', 150 * KB), textFile('b.txt', 150 * KB)], model(), 'openAI'))
      .toEqual([{ fileName: 'b.txt', reason: 'total_cap_exceeded' }]);
  });

  it('a PDF sent by native upload does not use the text budget; on a model without native support the same PDF is counted and reported', () => {
    const attachments = [textFile('notes.txt', 150 * KB), pdf('report.pdf', 150 * KB)];
    const nativePdfModel = model({ nativeFileMimes: [PDF], pdfNativeDefault: true });

    expect(resolveFileAttachmentDelivery(attachments[1]!, nativePdfModel, 'gemini').route).toBe('native');
    expect(findUnsendableTextAttachments(attachments, nativePdfModel, 'gemini')).toEqual([]);

    expect(resolveFileAttachmentDelivery(attachments[1]!, model(), 'deepseek').route).toBe('client_extract');
    expect(findUnsendableTextAttachments(attachments, model(), 'deepseek'))
      .toEqual([{ fileName: 'report.pdf', reason: 'total_cap_exceeded' }]);
  });

  it('a model whose totalCap is tighter than the default: a file that fits by default is reported on this model', () => {
    const attachments = [textFile('a.txt', 60 * KB), textFile('b.txt', 60 * KB)];
    expect(findUnsendableTextAttachments(attachments, model(), 'openAI')).toEqual([]);
    expect(findUnsendableTextAttachments(attachments, model({ attachmentExtraction: { totalCap: 100 * KB } }), 'openAI'))
      .toEqual([{ fileName: 'b.txt', reason: 'total_cap_exceeded' }]);
  });

  it('images and videos do not take part in the text budget', () => {
    const image: Attachment = { id: 'i', kind: 'image', fileName: 'i.png', mimeType: 'image/png', base64Data: 'x'.repeat(DEFAULT_LIMITS.totalCap + 1) };
    expect(findUnsendableTextAttachments([image, textFile('a.txt', 10 * KB)], model(), 'openAI')).toEqual([]);
  });

  it('matches the injector\'s skipped list for the same payloads item by item', () => {
    const attachments = [
      textFile('a.txt', 90 * KB),
      pdf('scan.pdf', 90 * KB),
      textFile('b.txt', 90 * KB),
      textFile('c.txt', 10 * KB),
    ];
    const tight = model({ attachmentExtraction: { totalCap: 190 * KB } });
    const payloads = attachments
      .map((attachment) => resolveFileAttachmentDelivery(attachment, tight, 'openAI'))
      .flatMap((delivery): AttachmentPayload[] => (delivery.route === 'client_extract' ? [delivery.payload] : []));
    const injected = AttachmentInjector.injectAll('question', payloads, resolveFileExtractionLimits(tight));

    expect(injected.skipped.length).toBeGreaterThan(0);
    expect(findUnsendableTextAttachments(attachments, tight, 'openAI')).toEqual(injected.skipped);
  });
});
