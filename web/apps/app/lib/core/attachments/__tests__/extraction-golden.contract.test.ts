/**
 * Shared fixtures of attachment extraction output spec v2, used by all three platforms (`shared/test-fixtures/attachments/extraction/`).
 *
 * Covered here: type detection (section 2, supported-types + golden classification), plain-text decoding (section 4, charset-tables +
 * golden `text_*`), HTML / EPUB / RTF (sections 8, 10, 11, golden `html_*` `epub_*` `rtf_*` and EPUB DRM),
 * OOXML / ODF (sections 5-7, 9, golden `docx_*` `xlsx_*` `pptx_*` `odt_*` `ods_*` `odp_*`, section 15 DOCTYPE, non-zip),
 * encrypted Office (section 16), PDF (section 12, golden `pdfCases`; Web does no OCR, fully scanned files are asserted via `scannedWithoutOcr`, section 13),
 * legacy-format hint copy (legacy-format-copy), edge cases added to the spec during implementation (extraction-golden-edges),
 * PDF radical code point mapping table (cjk-radicals).
 * Each case goes from fixture bytes through the production entry FileTextExtractor.extract and compares expect.content / expect.error byte for byte;
 * Case counts are locked: if the fixtures add or remove cases and this file is not updated, it fails instead of silently skipping.
 */
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { GlobalWorkerOptions } from 'pdfjs-dist/legacy/build/pdf.mjs';
import { beforeAll, describe, expect, it, vi } from 'vitest';
import { DEFAULT_LIMITS, ExtractionError, FileTextExtractor } from '../file-text-extractor';
import { SUPPORTED_ATTACHMENT_TYPES, classifyAttachmentFile } from '../attachment-file-types';
import {
  CHARSET_CANDIDATES,
  CHARSET_COMMON_CHARS,
  CHARSET_LOCALE_TIE_BREAK,
  CHARSET_OK_1251,
  CHARSET_PUNCT_1252,
} from '../extractors/text-decoding';
import { CJK_RADICAL_EQUIVALENTS, foldRadicals } from '../extractors/pdf-text-extractor';

vi.mock('../../telemetry', () => ({ trackEvent: vi.fn() }));
// Tests run on Node 22 (jsdom), which lacks the new browser APIs the pdfjs main build uses, such as `Promise.try` and `Uint8Array#toHex`;
// switch to the same-version legacy build (same engine, ships these polyfills); the code under test is still the production extractPdfText.
vi.mock('pdfjs-dist', () => import('pdfjs-dist/legacy/build/pdf.mjs'));

const FIXTURE_DIR = resolve(__dirname, '../../../../../../../shared/test-fixtures/attachments/extraction');
const MESSAGES_DIR = resolve(__dirname, '../../../../messages');
const readJson = <T,>(path: string): T => JSON.parse(readFileSync(path, 'utf8')) as T;

interface GoldenCase {
  id: string;
  file: string;
  fileName: string;
  mime: string;
  uiLanguage: string;
  expect: { content?: string; error?: string };
}

interface PdfExpect {
  markers?: string[];
  contains?: string[];
  notContains?: string[];
  scanned?: boolean;
  error?: string;
  scannedWithoutOcr?: { error: string };
}

interface PdfGoldenCase extends Omit<GoldenCase, 'expect'> {
  expect: PdfExpect;
}

interface Golden {
  cases: GoldenCase[];
  errorCases: GoldenCase[];
  classification: { fileName: string; mime: string; kind: string }[];
  pdfCases: PdfGoldenCase[];
}

const GOLDEN = readJson<Golden>(resolve(FIXTURE_DIR, 'extraction-golden.v1.json'));
const SUPPORTED = readJson<Record<string, unknown>>(resolve(FIXTURE_DIR, 'supported-types.v1.json'));
const CHARSETS = readJson<{
  candidates: string[];
  localeTieBreak: Record<string, string>;
  commonChars: Record<string, string[]>;
  punct1252: string[];
  ok1251: string[];
}>(resolve(FIXTURE_DIR, 'charset-tables.v1.json'));
const EDGES = readJson<Pick<Golden, 'cases' | 'errorCases'>>(resolve(FIXTURE_DIR, 'extraction-golden-edges.v1.json'));
const RADICALS = readJson<{ map: Record<string, string> }>(resolve(FIXTURE_DIR, 'cjk-radicals.v1.json'));
const LEGACY_COPY = readJson<{ copy: Record<string, string> }>(resolve(FIXTURE_DIR, 'legacy-format-copy.v1.json'));

/** Golden cases already covered: text decoding, HTML / EPUB / RTF, OOXML / ODF, binary, encrypted Office, EPUB DRM, DOCTYPE, non-zip. Other formats come later. */
const TEXT_CASES = GOLDEN.cases.filter((c) => c.id.startsWith('text_'));
const MARKUP_CASES = GOLDEN.cases.filter((c) => /^(html|epub|rtf)_/.test(c.id));
const OFFICE_CASES = GOLDEN.cases.filter((c) => /^(docx|xlsx|pptx|odt|ods|odp)_/.test(c.id));
const ERROR_CASE_IDS = [
  'text_binary_png', 'docx_ole_encrypted', 'xlsx_ole_encrypted', 'epub_drm_aes', 'epub_drm_lcp',
  'docx_doctype', 'docx_not_zip',
];
const ERROR_CASES = GOLDEN.errorCases.filter((c) => ERROR_CASE_IDS.includes(c.id));
/** PDF body text differs across the three engines, so only page marker count and order, included / excluded snippets, error code and `scanned` are locked (section 12). */
const PDF_CASES = GOLDEN.pdfCases;

function fixtureFile(entry: Pick<GoldenCase, 'file' | 'fileName' | 'mime'>): File {
  const bytes = readFileSync(resolve(FIXTURE_DIR, entry.file));
  return new File([new Uint8Array(bytes)], entry.fileName, { type: entry.mime });
}

const hex = (value: number, width: number) => value.toString(16).toUpperCase().padStart(width, '0');

describe('extraction golden: case count lock', () => {
  it('text_* 12 cases, html_* / epub_* / rtf_* 9 cases, Office 23 cases, errors 7 cases, type detection 24 cases', () => {
    expect(TEXT_CASES).toHaveLength(12);
    expect(MARKUP_CASES.map((c) => c.id).sort()).toEqual([
      'epub_font_obfuscation', 'epub_oebps_relative', 'epub_root_opf',
      'html_basic', 'html_gbk_meta',
      'rtf_big5_trail', 'rtf_gbk', 'rtf_structures', 'rtf_unicode',
    ]);
    expect(OFFICE_CASES.map((c) => c.id).sort()).toEqual([
      'docx_fields', 'docx_hidden', 'docx_inline_marks', 'docx_lists', 'docx_lists_no_numbering', 'docx_notes',
      'docx_rels_path', 'docx_revisions', 'docx_sdt', 'docx_styles_localized', 'docx_tables', 'docx_textbox',
      'odp_slides', 'ods_sheets', 'odt_document',
      'pptx_deck', 'pptx_no_presentation',
      'xlsx_cell_types', 'xlsx_date1904', 'xlsx_dates', 'xlsx_layout', 'xlsx_numbers', 'xlsx_sheet_order',
    ]);
    expect(ERROR_CASES.map((c) => c.id).sort()).toEqual([...ERROR_CASE_IDS].sort());
    expect(GOLDEN.classification).toHaveLength(24);
    expect(PDF_CASES.map((c) => c.id).sort()).toEqual([
      'pdf_full_scan', 'pdf_image_page', 'pdf_owner_password', 'pdf_two_pages', 'pdf_user_password',
    ]);
  });
});

describe('extraction golden: plain-text decoding (section 4)', () => {
  it.each(TEXT_CASES.map((c) => [c.id, c] as const))('%s', async (_id, entry) => {
    const extracted = await FileTextExtractor.extract(fixtureFile(entry), DEFAULT_LIMITS, 'file', entry.uiLanguage);
    expect(extracted.content).toBe(entry.expect.content);
  });
});

describe('extraction golden: HTML / EPUB / RTF (sections 8, 10, 11)', () => {
  it.each(MARKUP_CASES.map((c) => [c.id, c] as const))('%s', async (_id, entry) => {
    const extracted = await FileTextExtractor.extract(fixtureFile(entry), DEFAULT_LIMITS, 'file', entry.uiLanguage);
    expect(extracted.content).toBe(entry.expect.content);
  });
});

describe('extraction golden: DOCX / XLSX / PPTX / ODF (sections 5, 6, 7, 9)', () => {
  it.each(OFFICE_CASES.map((c) => [c.id, c] as const))('%s', async (_id, entry) => {
    const extracted = await FileTextExtractor.extract(fixtureFile(entry), DEFAULT_LIMITS, 'file', entry.uiLanguage);
    expect(extracted.content).toBe(entry.expect.content);
  });
});

describe('extraction golden: errors (section 4 binary, section 10 EPUB DRM, section 15 DOCTYPE, section 16 encrypted Office, non-zip)', () => {
  it.each(ERROR_CASES.map((c) => [c.id, c] as const))('%s', async (_id, entry) => {
    const failure = await FileTextExtractor.extract(fixtureFile(entry), DEFAULT_LIMITS, 'file', entry.uiLanguage)
      .then(() => null, (e: unknown) => e);
    expect(failure).toBeInstanceOf(ExtractionError);
    expect((failure as ExtractionError).code).toBe(entry.expect.error);
  });
});

describe('extraction golden edges: edge cases added during implementation (sections 3.3, 4A, 5, 7, 8, 9, 11)', () => {
  it('5 success cases, 3 error cases', () => {
    expect(EDGES.cases.map((c) => c.id).sort()).toEqual([
      'docx_edge', 'html_edge', 'odt_table_repeat', 'pptx_missing_slide', 'rtf_edge',
    ]);
    expect(EDGES.errorCases.map((c) => c.id).sort()).toEqual(['docx_empty_zip', 'docx_no_main', 'ods_no_content']);
  });

  it.each(EDGES.cases.map((c) => [c.id, c] as const))('%s', async (_id, entry) => {
    const extracted = await FileTextExtractor.extract(fixtureFile(entry), DEFAULT_LIMITS, 'file', entry.uiLanguage);
    expect(extracted.content).toBe(entry.expect.content);
  });

  it.each(EDGES.errorCases.map((c) => [c.id, c] as const))('%s', async (_id, entry) => {
    const failure = await FileTextExtractor.extract(fixtureFile(entry), DEFAULT_LIMITS, 'file', entry.uiLanguage)
      .then(() => null, (e: unknown) => e);
    expect(failure).toBeInstanceOf(ExtractionError);
    expect((failure as ExtractionError).code).toBe(entry.expect.error);
  });
});

describe('cjk-radicals.v1.json matches the embedded radical map entry by entry (section 12)', () => {
  it('328 entries, key sets match', () => {
    const embedded = Object.keys(CJK_RADICAL_EQUIVALENTS).map((key) => hex(Number(key), 4));
    expect(embedded.sort()).toEqual(Object.keys(RADICALS.map).sort());
    expect(embedded).toHaveLength(328);
  });

  it.each(Object.entries(RADICALS.map))('U+%s', (radical, unified) => {
    const source = String.fromCodePoint(parseInt(radical, 16));
    expect(foldRadicals(source)).toBe(String.fromCodePoint(parseInt(unified, 16)));
  });

  it('code points outside the table stay as-is (U+2E80, unassigned U+2E9A, after U+2FE0)', () => {
    expect(foldRadicals('\u2E80\u2E9A\u2FE0\u7B2C\u2F06\u2EDA')).toBe('\u2E80\u2E9A\u2FE0\u7B2C\u4E8C\u9875');
  });
});

describe('extraction golden: PDF (section 12; Web does no OCR, section 13)', () => {
  beforeAll(() => {
    // jsdom has no real Web Worker: pdfjs uses a fake worker, so the local worker module is imported dynamically here.
    // Do not override if the production entry already configured it.
    const worker = createRequire(import.meta.url).resolve('pdfjs-dist/legacy/build/pdf.worker.min.mjs');
    GlobalWorkerOptions.workerSrc = pathToFileURL(worker).href;
  });

  it.each(PDF_CASES.map((c) => [c.id, c] as const))('%s', async (_id, entry) => {
    const expected = entry.expect;
    const errorCode = expected.error ?? expected.scannedWithoutOcr?.error;
    const outcome = await FileTextExtractor.extract(fixtureFile(entry), DEFAULT_LIMITS, 'file', entry.uiLanguage)
      .then((extracted) => ({ extracted, failure: null }), (e: unknown) => ({ extracted: null, failure: e }));
    if (errorCode) {
      expect(outcome.failure).toBeInstanceOf(ExtractionError);
      expect((outcome.failure as ExtractionError).code).toBe(errorCode);
      return;
    }
    expect(outcome.failure).toBeNull();
    const content = outcome.extracted!.content;
    expect(content.split('\n').filter((line) => line.startsWith('--- Page '))).toEqual(expected.markers);
    for (const fragment of expected.contains ?? []) expect(content).toContain(fragment);
    for (const fragment of expected.notContains ?? []) expect(content).not.toContain(fragment);
    expect(outcome.extracted!.scanned ?? false).toBe(expected.scanned);
  });
});

describe('extraction golden: type detection (section 2)', () => {
  it.each(GOLDEN.classification.map((c) => [`${c.fileName} | ${c.mime || '(no mime)'}`, c] as const))(
    '%s',
    (_label, entry) => {
      expect(classifyAttachmentFile(entry.fileName, entry.mime)).toBe(entry.kind);
    },
  );
});

describe('supported-types.v1.json matches the built-in list entry by entry', () => {
  it('category sets match', () => {
    const fixtureKinds = Object.keys(SUPPORTED).filter((key) => key !== 'v' && key !== 'doc');
    expect(Object.keys(SUPPORTED_ATTACHMENT_TYPES)).toEqual(fixtureKinds);
  });

  it.each(Object.keys(SUPPORTED_ATTACHMENT_TYPES))('%s', (kind) => {
    expect(SUPPORTED_ATTACHMENT_TYPES[kind as keyof typeof SUPPORTED_ATTACHMENT_TYPES]).toEqual(SUPPORTED[kind]);
  });
});

describe('charset-tables.v1.json matches the built-in scoring table entry by entry', () => {
  it('candidate order', () => {
    expect([...CHARSET_CANDIDATES]).toEqual(CHARSETS.candidates);
  });

  it('UI language breaks ties', () => {
    expect(CHARSET_LOCALE_TIE_BREAK).toEqual(CHARSETS.localeTieBreak);
  });

  it.each(Object.keys(CHARSETS.commonChars))('common character table %s', (candidate) => {
    const embedded = CHARSET_COMMON_CHARS[candidate as keyof typeof CHARSET_COMMON_CHARS];
    expect(embedded.map((code) => hex(code, 4))).toEqual(CHARSETS.commonChars[candidate]);
  });

  it('every multi-byte candidate has a common character table', () => {
    expect(Object.keys(CHARSET_COMMON_CHARS).sort()).toEqual(Object.keys(CHARSETS.commonChars).sort());
  });

  it('windows-1252 punctuation, windows-1251 no-penalty bytes', () => {
    expect(CHARSET_PUNCT_1252.map((b) => hex(b, 2))).toEqual(CHARSETS.punct1252);
    expect(CHARSET_OK_1251.map((b) => hex(b, 2))).toEqual(CHARSETS.ok1251);
  });
});

describe('legacy-format-copy.v1.json matches errorLegacyFormat in all 16 languages', () => {
  it('covers 16 languages', () => {
    expect(Object.keys(LEGACY_COPY.copy)).toHaveLength(16);
  });

  it.each(Object.keys(LEGACY_COPY.copy))('%s', (locale) => {
    const messages = readJson<{ pages: { chat: { fileExtraction: Record<string, string> } } }>(
      resolve(MESSAGES_DIR, `${locale}.json`),
    );
    expect(messages.pages.chat.fileExtraction.errorLegacyFormat).toBe(LEGACY_COPY.copy[locale]);
  });
});
