/**
 * Attachment delivery golden (shared fixture): Web's actual output -> shared/test-fixtures/attachments/delivery-golden.v1.json.
 *
 * Each case goes through the production path from the fixture's input: FileTextExtractor.truncate (truncation at import) ->
 * buildChatHistory (native / text injection / error when this turn does not fit) -> line image placeholder + text block
 * flattening, and the produced expect must equal the fixture value by value. With `UPDATE_GOLDEN=1` the fixture is rewritten.
 */
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { AIModel, Attachment, ChatMessage, Provider } from '@oriveo/shared';
import {
  type AttachmentTransport,
  attachmentTransportProfile,
} from '@oriveo/core/providers/attachment-transport';
import type { ProxyMessage } from '@oriveo/core/providers/request-builders/runtime';
import {
  AttachmentOverLimitError,
  findUnsendableTextAttachments,
  resolveFileAttachmentDelivery,
} from '../attachment-delivery';
import { AttachmentInjector, type AttachmentPayload } from '../attachment-injector';
import { FileTextExtractor, resolveFileExtractionLimits } from '../file-text-extractor';
import { buildChatHistory } from '../../../utils/chat-stream-utils';
import { withoutUnreceivableImages } from '../../chat/attachment-policy';
import { resolveInputCapabilityProjections } from '../../capability/truth/input-truth-adapter';

const FIXTURE_PATH = resolve(__dirname, '../../../../../../../shared/test-fixtures/attachments/delivery-golden.v1.json');
const UPDATE = process.env.UPDATE_GOLDEN === '1';
/** A body over this many bytes is stored only as a digest and byte count. */
const INLINE_BODY_MAX_BYTES = 4096;

const KB = 1024;
const MB = 1024 * KB;
const PDF = 'application/pdf';

interface GenSpec { line: string; count: number; repeat?: number }
interface InputAttachment {
  id: string;
  kind: 'file' | 'image';
  fileName: string;
  mimeType: string;
  content?: string;
  gen?: GenSpec;
  fileBytes?: number;
  originalBytes?: number;
  extractionErrorCode?: string;
}
interface CaseInput {
  text: string;
  attachments: InputAttachment[];
  line: AttachmentTransport;
  model: Partial<Pick<AIModel, 'nativeFileMimes' | 'pdfNativeDefault' | 'attachmentExtraction'>>;
}
interface CaseExpect {
  native: string[];
  text: string[];
  blocked: { id: string; reason: string }[];
  body?: string;
  bodySha256?: string;
  bodyBytes?: number;
  systemSuffix?: string;
}
interface GoldenCase { id: string; input: CaseInput; expect: CaseExpect }

const COMMENT = 'Chat attachment delivery golden, generated from the Web production path (UPDATE_GOLDEN=1 in apps/app/lib/core/attachments/__tests__/delivery-golden.contract.test.ts). '
  + 'Each case: input.text is the user text; input.attachments are files as picked (content = raw extracted text, or gen = {line, count, repeat?}: count lines, each line = `line` with {n} replaced by the 1-based line number, repeated `repeat` times, joined by "\\n"; fileBytes = original file size, defaults to the UTF-8 length of the raw text; originalBytes = size of the kept original binary, used for native upload and judged on that raw byte length against the route cap; extractionErrorCode = extraction failed with no text); '
  + 'input.line is the Web transport name (attachment-transport.ts); input.model holds the model fields that drive delivery (nativeFileMimes, pdfNativeDefault, attachmentExtraction overrides). '
  + 'The raw text is truncated at import with the model limits (500 lines / 204800 UTF-8 bytes by default, a single over-long line is cut at a UTF-8 character boundary). '
  + 'expect.native / expect.text list attachment ids uploaded natively / injected as text blocks; expect.blocked lists files the injector cannot fit (too_many_files / total_cap_exceeded): the request is not sent, and body is then the injector output with the blocked files left out. '
  + 'body is the final user message text sent to the model: user text plus injected blocks (xml-v1 or markdown-v1 per route), image parts replaced by the route image placeholder when the route declares one, text parts joined by a blank line; native file and image blocks are not part of body. '
  + `Bodies over ${INLINE_BODY_MAX_BYTES} bytes are stored as bodySha256 (hex of UTF-8) + bodyBytes. systemSuffix is appended to the system prompt (after a blank line) when the user turn has attachments.`;

const lines = (count: number, line = 'L{n}'): GenSpec => ({ line, count });
const txt = (id: string, extra: Partial<InputAttachment> = {}): InputAttachment => ({ id, kind: 'file', fileName: id, mimeType: 'text/plain', ...extra });
const xs = (bytes: number): GenSpec => ({ line: 'x', count: 1, repeat: bytes });

/** Case inputs (written to the fixture on UPDATE; when verifying, the fixture's input is authoritative and the id list must match this one). */
const INPUTS: Array<{ id: string; input: CaseInput }> = [
  // ── attachment-delivery.test.ts ──
  { id: 'delivery-no-attachments', input: { text: 'hello', attachments: [], line: 'openai_responses', model: {} } },
  { id: 'delivery-two-100kb-fit', input: { text: 'compare', attachments: [txt('a.txt', { gen: xs(100 * KB) }), txt('b.txt', { gen: xs(100 * KB) })], line: 'openai_responses', model: {} } },
  { id: 'delivery-two-150kb-second-total-cap', input: { text: 'compare', attachments: [txt('a.txt', { gen: xs(150 * KB) }), txt('b.txt', { gen: xs(150 * KB) })], line: 'openai_responses', model: {} } },
  {
    id: 'delivery-native-pdf-gemini-not-budgeted',
    input: {
      text: 'summarize',
      attachments: [txt('notes.txt', { gen: xs(150 * KB) }), { id: 'report.pdf', kind: 'file', fileName: 'report.pdf', mimeType: PDF, gen: xs(150 * KB), fileBytes: 4096, originalBytes: 5 }],
      line: 'gemini_generate',
      model: { nativeFileMimes: [PDF], pdfNativeDefault: true },
    },
  },
  {
    id: 'delivery-pdf-text-route-deepseek-budgeted',
    input: {
      text: 'summarize',
      attachments: [txt('notes.txt', { gen: xs(150 * KB) }), { id: 'report.pdf', kind: 'file', fileName: 'report.pdf', mimeType: PDF, gen: xs(150 * KB), fileBytes: 4096, originalBytes: 5 }],
      line: 'deepseek_chat',
      model: {},
    },
  },
  { id: 'delivery-two-60kb-default-fit', input: { text: 'q', attachments: [txt('a.txt', { gen: xs(60 * KB) }), txt('b.txt', { gen: xs(60 * KB) })], line: 'openai_responses', model: {} } },
  { id: 'delivery-two-60kb-total-cap-100kb', input: { text: 'q', attachments: [txt('a.txt', { gen: xs(60 * KB) }), txt('b.txt', { gen: xs(60 * KB) })], line: 'openai_responses', model: { attachmentExtraction: { totalCap: 100 * KB } } } },
  {
    id: 'delivery-image-not-budgeted',
    input: { text: 'look', attachments: [{ id: 'i.png', kind: 'image', fileName: 'i.png', mimeType: 'image/png' }, txt('a.txt', { gen: xs(10 * KB) })], line: 'openai_responses', model: {} },
  },
  {
    id: 'delivery-tight-cap-mixed',
    input: {
      text: 'question',
      attachments: [
        txt('a.txt', { gen: xs(90 * KB) }),
        { id: 'scan.pdf', kind: 'file', fileName: 'scan.pdf', mimeType: PDF, gen: xs(90 * KB), fileBytes: 4096, originalBytes: 5 },
        txt('b.txt', { gen: xs(90 * KB) }),
        txt('c.txt', { gen: xs(10 * KB) }),
      ],
      line: 'openai_responses',
      model: { attachmentExtraction: { totalCap: 190 * KB } },
    },
  },
  // ── attachment-injector.test.ts ──
  { id: 'injector-xml-two-lines', input: { text: 'Summarize this', attachments: [txt('a.txt', { content: 'hello\nworld' })], line: 'openai_chat', model: {} } },
  { id: 'injector-xml-truncated-700-lines', input: { text: 'read', attachments: [{ ...txt('big.md'), mimeType: 'text/markdown', gen: lines(700) }], line: 'openai_chat', model: {} } },
  { id: 'injector-markdown-truncated-700-lines', input: { text: 'read', attachments: [{ ...txt('big.md'), mimeType: 'text/markdown', gen: lines(700) }], line: 'deepseek_chat', model: {} } },
  { id: 'injector-xml-error-scanned-pdf', input: { text: 'what is this', attachments: [{ id: 'p.pdf', kind: 'file', fileName: 'p.pdf', mimeType: PDF, fileBytes: 12345, extractionErrorCode: 'scanned_pdf' }], line: 'openai_chat', model: {} } },
  { id: 'injector-xml-error-encrypted-pdf', input: { text: 'open it', attachments: [{ id: 'enc.pdf', kind: 'file', fileName: 'enc.pdf', mimeType: PDF, fileBytes: 5000, extractionErrorCode: 'encrypted_pdf' }], line: 'openai_chat', model: {} } },
  { id: 'injector-markdown-error-scanned-pdf', input: { text: 'what is this', attachments: [{ id: 'p.pdf', kind: 'file', fileName: 'p.pdf', mimeType: PDF, fileBytes: 12345, extractionErrorCode: 'scanned_pdf' }], line: 'qwen_chat', model: {} } },
  { id: 'injector-markdown-pdf-text', input: { text: 'summarize', attachments: [{ id: 'doc.pdf', kind: 'file', fileName: 'doc.pdf', mimeType: PDF, content: 'Some PDF text', fileBytes: 1000 }], line: 'qwen_chat', model: {} } },
  { id: 'injector-three-half-cap-third-total-cap', input: { text: 'prompt', attachments: [txt('a.txt', { gen: xs(102_400) }), txt('b.txt', { gen: xs(102_400) }), txt('c.txt', { gen: xs(102_400) })], line: 'openai_chat', model: {} } },
  { id: 'injector-xml-exact-extraction-cap', input: { text: 'prompt', attachments: [txt('full.txt', { gen: xs(204_800) })], line: 'openai_chat', model: {} } },
  { id: 'injector-markdown-exact-extraction-cap', input: { text: 'prompt', attachments: [txt('full.txt', { gen: xs(204_800) })], line: 'deepseek_chat', model: {} } },
  { id: 'injector-zh-budget-exact-fit', input: { text: '', attachments: [txt('zh.txt', { gen: { line: '\u4e2d', count: 1, repeat: 68_266 } })], line: 'openai_chat', model: {} } },
  { id: 'injector-zh-one-over-truncated', input: { text: '', attachments: [txt('zh.txt', { gen: { line: '\u4e2d', count: 1, repeat: 68_267 } })], line: 'openai_chat', model: {} } },
  { id: 'injector-fourth-file-too-many', input: { text: 'msg', attachments: ['a.txt', 'b.txt', 'c.txt', 'd.txt'].map((id) => txt(id, { content: 'hi' })), line: 'openai_chat', model: {} } },
  { id: 'injector-empty-user-text', input: { text: '', attachments: [txt('f.txt', { content: 'hello' })], line: 'openai_chat', model: {} } },
  // ── file-text-extractor.test.ts ──
  { id: 'extractor-100-lines-not-truncated', input: { text: 'read', attachments: [txt('a.txt', { gen: lines(100, 'line {n}') })], line: 'openai_chat', model: {} } },
  { id: 'extractor-single-line-over-max-bytes', input: { text: 'read', attachments: [txt('one.txt', { gen: xs(204_900) })], line: 'openai_chat', model: {} } },
  { id: 'extractor-bytes-50-lines-of-5000', input: { text: 'read', attachments: [txt('wide.txt', { gen: { line: 'a', count: 50, repeat: 5000 } })], line: 'openai_chat', model: {} } },
  { id: 'extractor-custom-max-lines-10', input: { text: 'read', attachments: [txt('a.txt', { gen: lines(20) })], line: 'openai_chat', model: { attachmentExtraction: { maxLines: 10 } } } },
  { id: 'extractor-first-line-over-max-bytes-8', input: { text: 'read', attachments: [txt('a.txt', { content: '0123456789\nsecond' })], line: 'openai_chat', model: { attachmentExtraction: { maxBytes: 8 } } } },
  { id: 'extractor-zh-max-bytes-10', input: { text: 'read', attachments: [txt('zh.txt', { content: '\u4e2d\u6587\u5b57\u7b26\u622a\u65ad' })], line: 'openai_chat', model: { attachmentExtraction: { maxBytes: 10 } } } },
  { id: 'extractor-emoji-max-bytes-7', input: { text: 'read', attachments: [txt('e.txt', { content: 'ab😀😀😀' })], line: 'openai_chat', model: { attachmentExtraction: { maxBytes: 7 } } } },
  // -- additional cases --
  { id: 'lines-501-truncated-to-500', input: { text: 'read', attachments: [txt('log.txt', { gen: lines(501) })], line: 'openai_chat', model: {} } },
  { id: 'single-line-300kb-multibyte-utf8-boundary', input: { text: 'read', attachments: [txt('min.json', { mimeType: 'application/json', gen: { line: '\u4e2dabc', count: 1, repeat: 51_200 } })], line: 'openai_chat', model: {} } },
  {
    id: 'openai-responses-pdf-5mb-native',
    input: {
      text: 'summarize the report',
      attachments: [{ id: 'report.pdf', kind: 'file', fileName: 'report.pdf', mimeType: PDF, content: 'Quarterly report', fileBytes: 5 * MB, originalBytes: 5 * MB }],
      line: 'openai_responses',
      model: { nativeFileMimes: [PDF], pdfNativeDefault: true },
    },
  },
  {
    id: 'gemini-pdf-over-native-cap-text',
    input: {
      text: 'summarize the report',
      attachments: [{ id: 'report.pdf', kind: 'file', fileName: 'report.pdf', mimeType: PDF, content: 'Quarterly report', fileBytes: 20 * MB + 1, originalBytes: 20 * MB + 1 }],
      line: 'gemini_generate',
      model: { nativeFileMimes: [PDF], pdfNativeDefault: true },
    },
  },
  { id: 'minimax-markdown', input: { text: 'summarize', attachments: [{ ...txt('notes.md'), mimeType: 'text/markdown', content: '# Title\nbody line' }], line: 'minimax_chat', model: {} } },
];

function rawText(spec: InputAttachment): string | null {
  if (spec.content !== undefined) return spec.content;
  if (!spec.gen) return null;
  const { line, count, repeat = 1 } = spec.gen;
  return Array.from({ length: count }, (_, i) => line.replaceAll('{n}', String(i + 1)).repeat(repeat)).join('\n');
}

function modelOf(input: CaseInput): AIModel {
  return {
    id: 'model-1', name: 'Model 1', capabilities: ['text', 'file', 'image'], reasoningModeAvailable: false,
    isAvailable: true, isDefault: true, priceTier: '$', ...input.model,
  } as AIModel;
}

/** Attachment after import: text is truncated by the model thresholds (the same truncate as the import pipeline). */
function importedAttachment(spec: InputAttachment, model: AIModel): Attachment {
  if (spec.kind === 'image') {
    return { id: spec.id, kind: 'image', fileName: spec.fileName, mimeType: spec.mimeType, base64Data: 'AAAA' };
  }
  const raw = rawText(spec);
  const attachment: Attachment = { id: spec.id, kind: 'file', fileName: spec.fileName, mimeType: spec.mimeType };
  const fileBytes = spec.fileBytes ?? (raw === null ? 0 : new TextEncoder().encode(raw).byteLength);
  if (raw !== null) {
    const extracted = FileTextExtractor.truncate(raw, fileBytes, resolveFileExtractionLimits(model));
    attachment.base64Data = extracted.content;
    attachment.extractedTotalLines = extracted.totalLines;
    attachment.extractedTruncated = extracted.truncated;
  }
  attachment.extractedSizeBytes = fileBytes;
  if (spec.extractionErrorCode) attachment.extractionErrorCode = spec.extractionErrorCode;
  if (spec.originalBytes !== undefined) attachment.originalBase64Data = Buffer.alloc(spec.originalBytes).toString('base64');
  return attachment;
}

/** The final user body sent to the model: text blocks joined by a blank line; image placeholders were already written by the production outbound cleanup. */
function finalUserBody(content: string | ProxyMessage['content']): string {
  if (typeof content === 'string') return content;
  return content.flatMap((part) => (part.type === 'text' && part.text ? [part.text] : [])).join('\n\n');
}

/** The connection for a case: every case uses an official connection. */
function providerOf(model: AIModel): Provider {
  const kind = 'openAI';
  return {
    id: kind, kind, status: { kind: 'connected' }, models: [model], catalogModels: [{ ...model }],
    apiKey: '', apiKeyPreview: '',
  } as unknown as Provider;
}

async function produce(input: CaseInput): Promise<CaseExpect> {
  const model = modelOf(input);
  const line = { transport: input.line };
  const attachments = input.attachments.map((spec) => importedAttachment(spec, model));
  const idOf = (fileName: string) => attachments.find((a) => a.fileName === fileName)!.id;
  const message = {
    id: 'u-1', role: 'user', text: input.text, providerKind: 'openAI', providerName: 'P', modelName: 'm',
    estimatedCost: 0, state: 'delivered', createdAt: '2026-10-15T00:00:00Z',
    ...(attachments.length > 0 ? { attachments } : {}),
  } as unknown as ChatMessage;

  const files = attachments.filter((a) => a.kind === 'file');
  const deliveries = files.map((a) => ({ id: a.id, delivery: resolveFileAttachmentDelivery(a, model, line) }));
  const preflight = findUnsendableTextAttachments(attachments, model, line);

  let body: string;
  let blocked: CaseExpect['blocked'] = [];
  let native: string[];
  try {
    // Production outbound cleanup: images the projection judges unsendable become placeholder lines, and buildChatHistory puts the placeholders after all parts of that turn.
    const provider = providerOf(model);
    const cleaned = withoutUnreceivableImages([message], provider, model, undefined);
    const vision = resolveInputCapabilityProjections(provider, model, undefined)?.vision_input ?? null;
    const history = await buildChatHistory(cleaned, model, line, vision);
    expect(history).toHaveLength(1);
    const content = history[0]!.content;
    native = typeof content === 'string' ? [] : content.flatMap((part) => (part.type === 'file' ? [idOf(part.file.filename)] : []));
    body = finalUserBody(content);
  } catch (error) {
    if (!(error instanceof AttachmentOverLimitError)) throw error;
    blocked = error.skipped.map((s) => ({ id: idOf(s.fileName), reason: s.reason }));
    native = deliveries.filter((d) => d.delivery.route === 'native').map((d) => d.id);
    // The request is not sent; the body is the injector's output for the same payloads (blocked files are not in it).
    const payloads = deliveries.flatMap((d): AttachmentPayload[] => (d.delivery.route === 'client_extract' ? [d.delivery.payload] : []));
    body = AttachmentInjector.injectAll(input.text, payloads, resolveFileExtractionLimits(model), attachmentTransportProfile(input.line).wrapper).text;
  }
  // The pre-send check uses the same criterion as the outbound build.
  expect(preflight.map((s) => ({ id: idOf(s.fileName), reason: s.reason }))).toEqual(blocked);

  const blockedIds = new Set(blocked.map((b) => b.id));
  const text = deliveries.filter((d) => d.delivery.route === 'client_extract' && !blockedIds.has(d.id)).map((d) => d.id);
  expect(deliveries.filter((d) => d.delivery.route === 'native').map((d) => d.id)).toEqual(native);

  const bytes = Buffer.from(body, 'utf8');
  return {
    native,
    text,
    blocked,
    ...(bytes.byteLength > INLINE_BODY_MAX_BYTES
      ? { bodySha256: createHash('sha256').update(bytes).digest('hex'), bodyBytes: bytes.byteLength }
      : { body }),
    ...(attachments.length > 0 ? { systemSuffix: AttachmentInjector.SYSTEM_PROMPT_GUIDANCE } : {}),
  };
}

describe('attachment delivery golden = shared fixture', () => {
  if (UPDATE) {
    it('UPDATE_GOLDEN=1: rewrite the fixture from the Web production path', async () => {
      const cases: GoldenCase[] = [];
      for (const { id, input } of INPUTS) cases.push({ id, input, expect: await produce(input) });
      writeFileSync(FIXTURE_PATH, `${JSON.stringify({ $comment: COMMENT, v: 1, cases }, null, 2)}\n`);
    });
    return;
  }

  const fixture = JSON.parse(readFileSync(FIXTURE_PATH, 'utf8')) as { $comment: string; v: number; cases: GoldenCase[] };

  it('fixture version and case list', () => {
    expect(fixture.v).toBe(1);
    expect(fixture.$comment).toBe(COMMENT);
    expect(fixture.cases.map((c) => c.id)).toEqual(INPUTS.map((c) => c.id));
    expect(fixture.cases.map((c) => c.input)).toEqual(INPUTS.map((c) => c.input));
  });

  for (const golden of fixture.cases) {
    it(`DELIVERY-GOLDEN-${golden.id}`, async () => {
      expect(await produce(golden.input)).toEqual(golden.expect);
    });
  }
});
