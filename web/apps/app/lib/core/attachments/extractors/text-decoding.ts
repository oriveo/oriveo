/**
 * Plain-text decoding (attachment extraction output spec section 4): BOM → NUL bytes decide UTF-16 / binary → strict UTF-8 → candidate scoring.
 *
 * All three platforms implement the same deterministic algorithm without a third-party detection library. The scoring tables are embedded here,
 * and extraction-golden.contract.test.ts compares them entry by entry with the shared fixture `charset-tables.v1.json`.
 * Output gets only plain-text normalization (section 3.1): strip BOM, `\r\n` / `\r` → `\n`; no trim, no blank line collapsing.
 */
import { ExtractionError } from '../file-text-extractor';

/** UI language used for encoding detection (section 1). Any other language is treated as `en`. */
export type ExtractionUiLanguage = 'zh-Hans' | 'zh-Hant' | 'ja' | 'ko' | 'ru' | 'en';

/** next-intl locale → `uiLanguage` of spec section 1; falls back to `en` if unavailable. */
export function normalizeExtractionUiLanguage(locale: string | null | undefined): ExtractionUiLanguage {
  const lower = (locale ?? '').toLowerCase();
  if (lower === 'zh-hant' || lower.startsWith('zh-hant') || lower === 'zh-tw' || lower === 'zh-hk' || lower === 'zh-mo') return 'zh-Hant';
  if (lower === 'zh' || lower.startsWith('zh-')) return 'zh-Hans';
  if (lower === 'ja' || lower.startsWith('ja-')) return 'ja';
  if (lower === 'ko' || lower.startsWith('ko-')) return 'ko';
  if (lower === 'ru' || lower.startsWith('ru-')) return 'ru';
  return 'en';
}

export const CHARSET_CANDIDATES = ['gb18030', 'shift_jis', 'big5', 'euc-kr', 'windows-1252', 'windows-1251'] as const;
export type CharsetCandidate = (typeof CHARSET_CANDIDATES)[number];
type MultiByteCandidate = 'gb18030' | 'shift_jis' | 'big5' | 'euc-kr';

/** On equal scores the candidate matching the UI language is chosen first; the UI language only breaks ties and adds no score. */
export const CHARSET_LOCALE_TIE_BREAK: Readonly<Record<string, CharsetCandidate>> = {
  'zh-Hans': 'gb18030',
  'zh-Hant': 'big5',
  ja: 'shift_jis',
  ko: 'euc-kr',
  ru: 'windows-1251',
};

/** Common character code points per multi-byte encoding (lead byte << 8 | trail byte), sourced from node-chardet mbcs.ts commonChars (MIT). */
export const CHARSET_COMMON_CHARS: Readonly<Record<MultiByteCandidate, readonly number[]>> = {
  gb18030: [
    0xA1A1, 0xA1A2, 0xA1A3, 0xA1A4, 0xA1B0, 0xA1B1, 0xA1F1, 0xA1F3, 0xA3A1, 0xA3AC, 0xA3BA, 0xB1A8,
    0xB1B8, 0xB1BE, 0xB2BB, 0xB3C9, 0xB3F6, 0xB4F3, 0xB5BD, 0xB5C4, 0xB5E3, 0xB6AF, 0xB6D4, 0xB6E0,
    0xB7A2, 0xB7A8, 0xB7BD, 0xB7D6, 0xB7DD, 0xB8B4, 0xB8DF, 0xB8F6, 0xB9AB, 0xB9C9, 0xB9D8, 0xB9FA,
    0xB9FD, 0xBACD, 0xBBA7, 0xBBD6, 0xBBE1, 0xBBFA, 0xBCBC, 0xBCDB, 0xBCFE, 0xBDCC, 0xBECD, 0xBEDD,
    0xBFB4, 0xBFC6, 0xBFC9, 0xC0B4, 0xC0ED, 0xC1CB, 0xC2DB, 0xC3C7, 0xC4DC, 0xC4EA, 0xC5CC, 0xC6F7,
    0xC7F8, 0xC8AB, 0xC8CB, 0xC8D5, 0xC8E7, 0xC9CF, 0xC9FA, 0xCAB1, 0xCAB5, 0xCAC7, 0xCAD0, 0xCAD6,
    0xCAF5, 0xCAFD, 0xCCEC, 0xCDF8, 0xCEAA, 0xCEC4, 0xCED2, 0xCEE5, 0xCFB5, 0xCFC2, 0xCFD6, 0xD0C2,
    0xD0C5, 0xD0D0, 0xD0D4, 0xD1A7, 0xD2AA, 0xD2B2, 0xD2B5, 0xD2BB, 0xD2D4, 0xD3C3, 0xD3D0, 0xD3FD,
    0xD4C2, 0xD4DA, 0xD5E2, 0xD6D0,
  ],
  shift_jis: [
    0x8140, 0x8141, 0x8142, 0x8145, 0x815B, 0x8169, 0x816A, 0x8175, 0x8176, 0x82A0, 0x82A2, 0x82A4,
    0x82A9, 0x82AA, 0x82AB, 0x82AD, 0x82AF, 0x82B1, 0x82B3, 0x82B5, 0x82B7, 0x82BD, 0x82BE, 0x82C1,
    0x82C4, 0x82C5, 0x82C6, 0x82C8, 0x82C9, 0x82CC, 0x82CD, 0x82DC, 0x82E0, 0x82E7, 0x82E8, 0x82E9,
    0x82EA, 0x82F0, 0x82F1, 0x8341, 0x8343, 0x834E, 0x834F, 0x8358, 0x835E, 0x8362, 0x8367, 0x8375,
    0x8376, 0x8389, 0x838A, 0x838B, 0x838D, 0x8393, 0x8E96, 0x93FA, 0x95AA,
  ],
  big5: [
    0xA140, 0xA141, 0xA142, 0xA143, 0xA147, 0xA149, 0xA175, 0xA176, 0xA440, 0xA446, 0xA447, 0xA448,
    0xA451, 0xA454, 0xA457, 0xA464, 0xA46A, 0xA46C, 0xA477, 0xA4A3, 0xA4A4, 0xA4A7, 0xA4C1, 0xA4CE,
    0xA4D1, 0xA4DF, 0xA4E8, 0xA4FD, 0xA540, 0xA548, 0xA558, 0xA569, 0xA5CD, 0xA5E7, 0xA657, 0xA661,
    0xA662, 0xA668, 0xA670, 0xA6A8, 0xA6B3, 0xA6B9, 0xA6D3, 0xA6DB, 0xA6E6, 0xA6F2, 0xA740, 0xA751,
    0xA759, 0xA7DA, 0xA8A3, 0xA8A5, 0xA8AD, 0xA8D1, 0xA8D3, 0xA8E4, 0xA8FC, 0xA9C0, 0xA9D2, 0xA9F3,
    0xAA6B, 0xAABA, 0xAABE, 0xAACC, 0xAAFC, 0xAC47, 0xAC4F, 0xACB0, 0xACD2, 0xAD59, 0xAEC9, 0xAFE0,
    0xB0EA, 0xB16F, 0xB2B3, 0xB2C4, 0xB36F, 0xB44C, 0xB44E, 0xB54C, 0xB5A5, 0xB5BD, 0xB5D0, 0xB5D8,
    0xB671, 0xB7ED, 0xB867, 0xB944, 0xBAD8, 0xBB44, 0xBBA1, 0xBDD1, 0xC2C4, 0xC3B9, 0xC440, 0xC45F,
  ],
  'euc-kr': [
    0xB0A1, 0xB0B3, 0xB0C5, 0xB0CD, 0xB0D4, 0xB0E6, 0xB0ED, 0xB0F8, 0xB0FA, 0xB0FC, 0xB1B8, 0xB1B9,
    0xB1C7, 0xB1D7, 0xB1E2, 0xB3AA, 0xB3BB, 0xB4C2, 0xB4CF, 0xB4D9, 0xB4EB, 0xB5A5, 0xB5B5, 0xB5BF,
    0xB5C7, 0xB5E9, 0xB6F3, 0xB7AF, 0xB7C2, 0xB7CE, 0xB8A6, 0xB8AE, 0xB8B6, 0xB8B8, 0xB8BB, 0xB8E9,
    0xB9AB, 0xB9AE, 0xB9CC, 0xB9CE, 0xB9FD, 0xBAB8, 0xBACE, 0xBAD0, 0xBAF1, 0xBBE7, 0xBBF3, 0xBBFD,
    0xBCAD, 0xBCBA, 0xBCD2, 0xBCF6, 0xBDBA, 0xBDC0, 0xBDC3, 0xBDC5, 0xBEC6, 0xBEC8, 0xBEDF, 0xBEEE,
    0xBEF8, 0xBEFA, 0xBFA1, 0xBFA9, 0xBFC0, 0xBFE4, 0xBFEB, 0xBFEC, 0xBFF8, 0xC0A7, 0xC0AF, 0xC0B8,
    0xC0BA, 0xC0BB, 0xC0BD, 0xC0C7, 0xC0CC, 0xC0CE, 0xC0CF, 0xC0D6, 0xC0DA, 0xC0E5, 0xC0FB, 0xC0FC,
    0xC1A4, 0xC1A6, 0xC1B6, 0xC1D6, 0xC1DF, 0xC1F6, 0xC1F8, 0xC4A1, 0xC5CD, 0xC6AE, 0xC7CF, 0xC7D1,
    0xC7D2, 0xC7D8, 0xC7E5, 0xC8AD,
  ],
};

/** Bytes counted as "punctuation" in windows-1252 scoring. */
export const CHARSET_PUNCT_1252: readonly number[] = [0x80, 0x85, 0x91, 0x92, 0x93, 0x94, 0x96, 0x97, 0xA0, 0xA9, 0xAB, 0xAE, 0xB0, 0xBB];
/** Non-letter high bytes that are not penalized in windows-1251 scoring. */
export const CHARSET_OK_1251: readonly number[] = [0x85, 0x93, 0x94, 0x96, 0x97, 0xA0, 0xA8, 0xAB, 0xB8, 0xB9, 0xBB];

const NUL_PROBE_BYTES = 4096;
const SAMPLE_BYTES = 65536;

const COMMON_SETS: Record<MultiByteCandidate, ReadonlySet<number>> = {
  gb18030: new Set(CHARSET_COMMON_CHARS.gb18030),
  shift_jis: new Set(CHARSET_COMMON_CHARS.shift_jis),
  big5: new Set(CHARSET_COMMON_CHARS.big5),
  'euc-kr': new Set(CHARSET_COMMON_CHARS['euc-kr']),
};
const PUNCT_1252 = new Set(CHARSET_PUNCT_1252);
const OK_1251 = new Set(CHARSET_OK_1251);

/**
 * Decode the bytes of a plain-text file into a string.
 * @throws ExtractionError `corrupted_file` (has a BOM but cannot be decoded), `unsupported_format` (binary)
 */
export function decodeTextBytes(bytes: Uint8Array, uiLanguage: string = 'en'): string {
  return detectAndDecode(bytes, uiLanguage).replace(/\r\n?/g, '\n');
}

function detectAndDecode(bytes: Uint8Array, uiLanguage: string): string {
  // 1. BOM: after stripping it, strictly decode the whole file with that encoding; failure means corrupted.
  const bom = bomEncoding(bytes);
  if (bom) {
    const decoded = strictDecode(bom.label, bytes.subarray(bom.length));
    if (decoded === null) throw new ExtractionError('corrupted_file', `invalid ${bom.label} after BOM`);
    return decoded;
  }

  // 2. NUL bytes: look only at the first 4096 bytes; all at odd indexes → UTF-16LE, all at even indexes → UTF-16BE, mixed → binary.
  let nulAtOdd = false;
  let nulAtEven = false;
  const probeEnd = Math.min(bytes.length, NUL_PROBE_BYTES);
  for (let i = 0; i < probeEnd; i++) {
    if (bytes[i] === 0) {
      if (i % 2 === 1) nulAtOdd = true;
      else nulAtEven = true;
    }
  }
  if (nulAtOdd || nulAtEven) {
    if (nulAtOdd && nulAtEven) throw new ExtractionError('unsupported_format', 'binary content');
    const decoded = strictDecode(nulAtOdd ? 'utf-16le' : 'utf-16be', bytes);
    if (decoded === null) throw new ExtractionError('unsupported_format', 'binary content');
    return decoded;
  }

  // 3. Strict UTF-8 (pure ASCII is handled here too).
  const utf8 = strictDecode('utf-8', bytes);
  if (utf8 !== null) return utf8;

  // 4-5. Score candidates and strictly decode the whole file in rank order; the first success is the result.
  for (const candidate of rankCharsetCandidates(bytes, uiLanguage)) {
    const decoded = decodeWhole(candidate, bytes);
    if (decoded !== null) return decoded;
  }
  // windows-1252 / 1251 always decode, so this is unreachable.
  throw new ExtractionError('unsupported_format', 'no charset candidate decoded');
}

/** Step 4: surviving candidates sorted by score descending; on ties the UI-language candidate first, then candidate order. */
export function rankCharsetCandidates(bytes: Uint8Array, uiLanguage: string = 'en'): CharsetCandidate[] {
  const sample = bytes.subarray(0, SAMPLE_BYTES);
  const sampleIsPartial = sample.length < bytes.length;
  const preferred = CHARSET_LOCALE_TIE_BREAK[uiLanguage];
  const survivors: { candidate: CharsetCandidate; score: number; order: number }[] = [];
  CHARSET_CANDIDATES.forEach((candidate, order) => {
    if (isMultiByte(candidate) && !sampleDecodes(candidate, sample, sampleIsPartial)) return;
    survivors.push({ candidate, score: scoreCharsetCandidate(candidate, sample), order });
  });
  survivors.sort((a, b) =>
    b.score - a.score
    || Number(b.candidate === preferred) - Number(a.candidate === preferred)
    || a.order - b.order);
  return survivors.map((entry) => entry.candidate);
}

export function scoreCharsetCandidate(candidate: CharsetCandidate, sample: Uint8Array): number {
  switch (candidate) {
    case 'windows-1252': return score1252(sample);
    case 'windows-1251': return score1251(sample);
    default: return scoreMultiByte(candidate, sample);
  }
}

function isMultiByte(candidate: CharsetCandidate): candidate is MultiByteCandidate {
  return candidate !== 'windows-1252' && candidate !== 'windows-1251';
}

/** Strictly decode the sample; when the sample is shorter than the whole file its end may split a character, so retry dropping 1, 2, 3 bytes in turn. */
function sampleDecodes(candidate: MultiByteCandidate, sample: Uint8Array, sampleIsPartial: boolean): boolean {
  if (strictDecode(candidate, sample) !== null) return true;
  if (!sampleIsPartial) return false;
  for (let drop = 1; drop <= 3 && drop < sample.length; drop++) {
    if (strictDecode(candidate, sample.subarray(0, sample.length - drop)) !== null) return true;
  }
  return false;
}

function decodeWhole(candidate: CharsetCandidate, bytes: Uint8Array): string | null {
  // The two WHATWG single-byte tables cover all 256 bytes, so decoding cannot fail.
  if (!isMultiByte(candidate)) return new TextDecoder(candidate).decode(bytes);
  return strictDecode(candidate, bytes);
}

function strictDecode(label: string, bytes: Uint8Array): string | null {
  try {
    return new TextDecoder(label, { fatal: true, ignoreBOM: true }).decode(bytes);
  } catch {
    return null;
  }
}

function bomEncoding(bytes: Uint8Array): { label: string; length: number } | null {
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) return { label: 'utf-8', length: 3 };
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) return { label: 'utf-16le', length: 2 };
  if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) return { label: 'utf-16be', length: 2 };
  return null;
}

const inRange = (value: number, low: number, high: number) => value >= low && value <= high;

/**
 * Multi-byte scoring: only bytes >= 0x80 count; the byte after a lead byte is always taken as the trail byte, and an incomplete character at the sample end is ignored.
 * Each double-byte character earns a range score, plus 3 more if its code point is in the common character table.
 */
function scoreMultiByte(candidate: MultiByteCandidate, sample: Uint8Array): number {
  const common = COMMON_SETS[candidate];
  let score = 0;
  let i = 0;
  while (i < sample.length) {
    const lead = sample[i];
    if (lead < 0x80) {
      i += 1;
      continue;
    }
    if (candidate === 'shift_jis' && inRange(lead, 0xa1, 0xdf)) {
      score -= 1; // half-width katakana, single byte
      i += 1;
      continue;
    }
    if (i + 1 >= sample.length) break;
    const trail = sample[i + 1];
    if (candidate === 'gb18030' && inRange(trail, 0x30, 0x39)) {
      if (i + 3 >= sample.length) break;
      score -= 2; // four-byte sequence, skipped as a whole
      i += 4;
      continue;
    }
    const code = (lead << 8) | trail;
    score += rangeScore(candidate, lead, trail, code);
    if (common.has(code)) score += 3;
    i += 2;
  }
  return score;
}

function rangeScore(candidate: MultiByteCandidate, lead: number, trail: number, code: number): number {
  switch (candidate) {
    case 'gb18030': {
      const trailOk = inRange(trail, 0xa1, 0xfe);
      if (trailOk && inRange(lead, 0xb0, 0xd7)) return 1;
      if (trailOk && (inRange(lead, 0xa1, 0xa9) || inRange(lead, 0xd8, 0xf7))) return 0;
      return -1;
    }
    case 'big5':
      if (inRange(lead, 0xa4, 0xc6)) return 1;
      if (inRange(lead, 0xa1, 0xa3) || inRange(lead, 0xc9, 0xf9)) return 0;
      if (inRange(lead, 0xc7, 0xc8)) return -1;
      return -2;
    case 'shift_jis':
      if (inRange(code, 0x829f, 0x82f1) || inRange(code, 0x8340, 0x8396) || inRange(code, 0x889f, 0x9872)) return 1;
      if (inRange(code, 0x989f, 0xeaa4) || inRange(lead, 0x81, 0x84)) return 0;
      if (inRange(lead, 0xf0, 0xf9)) return -2;
      return -1;
    case 'euc-kr': {
      const trailOk = inRange(trail, 0xa1, 0xfe);
      if (trailOk && inRange(lead, 0xb0, 0xc8)) return 1;
      if (trailOk && (inRange(lead, 0xa1, 0xac) || inRange(lead, 0xca, 0xfd))) return 0;
      return -1;
    }
  }
}

const isHigh = (byte: number | undefined) => byte !== undefined && byte >= 0x80;
const isAsciiLetter = (byte: number | undefined) =>
  byte !== undefined && (inRange(byte, 0x41, 0x5a) || inRange(byte, 0x61, 0x7a));

function is1252Letter(byte: number): boolean {
  if (inRange(byte, 0xc0, 0xff)) return byte !== 0xd7 && byte !== 0xf7;
  return byte === 0x8a || byte === 0x8c || byte === 0x8e || byte === 0x9a || byte === 0x9c || byte === 0x9e || byte === 0x9f;
}

function score1252(sample: Uint8Array): number {
  let score = 0;
  for (let i = 0; i < sample.length; i++) {
    const b = sample[i];
    if (b < 0x80) continue;
    const p = i > 0 ? sample[i - 1] : undefined;
    const n = i + 1 < sample.length ? sample[i + 1] : undefined;
    if (is1252Letter(b)) {
      if (isHigh(p) && isHigh(n)) score -= 1;
      else if (isAsciiLetter(p) || isAsciiLetter(n) || (!isHigh(p) && !isHigh(n))) score += 1;
    } else if (b === 0xbf || b === 0xa1) {
      if (n !== undefined && n < 0x80 && (p === undefined || p < 0x80)) score += 2;
    } else if (PUNCT_1252.has(b)) {
      if (!isHigh(p) && !isHigh(n)) score += 1;
    }
  }
  return score;
}

function score1251(sample: Uint8Array): number {
  let score = 0;
  for (let i = 0; i < sample.length; i++) {
    const b = sample[i];
    if (b < 0x80) continue;
    const p = i > 0 ? sample[i - 1] : undefined;
    const n = i + 1 < sample.length ? sample[i + 1] : undefined;
    const isLower = (byte: number | undefined) => byte !== undefined && inRange(byte, 0xe0, 0xff);
    const isUpper = (byte: number | undefined) => byte !== undefined && inRange(byte, 0xc0, 0xdf);
    if (isAsciiLetter(p) || isAsciiLetter(n)) {
      score -= 1;
    } else if (isLower(b)) {
      score += 1;
    } else if (isUpper(b)) {
      if (isLower(p) || (isUpper(p) && isLower(n))) score -= 1;
      else score += 0.5;
    } else if (!OK_1251.has(b)) {
      score -= 2;
    }
  }
  return score;
}
