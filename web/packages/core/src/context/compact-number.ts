/**
 * Compact number formatting (P9 D-C08 / D-C19..D-C22).
 * Spec: context-contracts/compact-number.v1.json — the fixture `rules` text is the algorithm.
 * The table below is a copy of the fixture `locales` (CLDR short decimal formats, U+00A0 kept);
 * the contract test checks it entry by entry. Intl / ICU compact notation is not used.
 */

/** The 16 app languages that carry a compact table. */
export type CompactLocale =
  | 'zh-Hans'
  | 'zh-Hant'
  | 'en'
  | 'ja'
  | 'ko'
  | 'de'
  | 'fr'
  | 'es'
  | 'pt-BR'
  | 'ru'
  | 'tr'
  | 'id'
  | 'vi'
  | 'th'
  | 'hi'
  | 'ar';

export interface CompactNumberTier {
  readonly min: number;
  readonly pattern: string;
  /** Plural "few" form; used when frac == 0 and int % 100 is 3...10 (only ar 1000). */
  readonly few?: string;
}

export interface CompactNumberLocaleTable {
  readonly decimal: string;
  readonly group: string;
  readonly tiers: readonly CompactNumberTier[];
}

export const COMPACT_NUMBER_LOCALES: Readonly<Record<CompactLocale, CompactNumberLocaleTable>> = {
  'zh-Hans': {
    decimal: '.',
    group: ',',
    tiers: [
      { min: 1000, pattern: '0' },
      { min: 10000, pattern: '0万' },
      { min: 100000, pattern: '00万' },
      { min: 1000000, pattern: '000万' },
      { min: 10000000, pattern: '0000万' },
      { min: 100000000, pattern: '0亿' },
      { min: 1000000000, pattern: '00亿' },
      { min: 10000000000, pattern: '000亿' },
      { min: 100000000000, pattern: '0000亿' },
      { min: 1000000000000, pattern: '0万亿' },
    ],
  },
  'zh-Hant': {
    decimal: '.',
    group: ',',
    tiers: [
      { min: 1000, pattern: '0' },
      { min: 10000, pattern: '0萬' },
      { min: 100000, pattern: '00萬' },
      { min: 1000000, pattern: '000萬' },
      { min: 10000000, pattern: '0000萬' },
      { min: 100000000, pattern: '0億' },
      { min: 1000000000, pattern: '00億' },
      { min: 10000000000, pattern: '000億' },
      { min: 100000000000, pattern: '0000億' },
      { min: 1000000000000, pattern: '0兆' },
    ],
  },
  en: {
    decimal: '.',
    group: ',',
    tiers: [
      { min: 1000, pattern: '0K' },
      { min: 10000, pattern: '00K' },
      { min: 100000, pattern: '000K' },
      { min: 1000000, pattern: '0M' },
      { min: 10000000, pattern: '00M' },
      { min: 100000000, pattern: '000M' },
      { min: 1000000000, pattern: '0B' },
      { min: 10000000000, pattern: '00B' },
      { min: 100000000000, pattern: '000B' },
      { min: 1000000000000, pattern: '0T' },
    ],
  },
  ja: {
    decimal: '.',
    group: ',',
    tiers: [
      { min: 1000, pattern: '0' },
      { min: 10000, pattern: '0万' },
      { min: 100000, pattern: '00万' },
      { min: 1000000, pattern: '000万' },
      { min: 10000000, pattern: '0000万' },
      { min: 100000000, pattern: '0億' },
      { min: 1000000000, pattern: '00億' },
      { min: 10000000000, pattern: '000億' },
      { min: 100000000000, pattern: '0000億' },
      { min: 1000000000000, pattern: '0兆' },
    ],
  },
  ko: {
    decimal: '.',
    group: ',',
    tiers: [
      { min: 1000, pattern: '0천' },
      { min: 10000, pattern: '0만' },
      { min: 100000, pattern: '00만' },
      { min: 1000000, pattern: '000만' },
      { min: 10000000, pattern: '0000만' },
      { min: 100000000, pattern: '0억' },
      { min: 1000000000, pattern: '00억' },
      { min: 10000000000, pattern: '000억' },
      { min: 100000000000, pattern: '0000억' },
      { min: 1000000000000, pattern: '0조' },
    ],
  },
  de: {
    decimal: ',',
    group: '.',
    tiers: [
      { min: 1000, pattern: '0' },
      { min: 10000, pattern: '0' },
      { min: 100000, pattern: '0' },
      { min: 1000000, pattern: '0 Mio.' },
      { min: 10000000, pattern: '00 Mio.' },
      { min: 100000000, pattern: '000 Mio.' },
      { min: 1000000000, pattern: '0 Mrd.' },
      { min: 10000000000, pattern: '00 Mrd.' },
      { min: 100000000000, pattern: '000 Mrd.' },
      { min: 1000000000000, pattern: '0 Bio.' },
    ],
  },
  fr: {
    decimal: ',',
    group: ' ',
    tiers: [
      { min: 1000, pattern: '0 k' },
      { min: 10000, pattern: '00 k' },
      { min: 100000, pattern: '000 k' },
      { min: 1000000, pattern: '0 M' },
      { min: 10000000, pattern: '00 M' },
      { min: 100000000, pattern: '000 M' },
      { min: 1000000000, pattern: '0 Md' },
      { min: 10000000000, pattern: '00 Md' },
      { min: 100000000000, pattern: '000 Md' },
      { min: 1000000000000, pattern: '0 Bn' },
    ],
  },
  es: {
    decimal: ',',
    group: '.',
    tiers: [
      { min: 1000, pattern: '0 mil' },
      { min: 10000, pattern: '00 mil' },
      { min: 100000, pattern: '000 mil' },
      { min: 1000000, pattern: '0 M' },
      { min: 10000000, pattern: '00 M' },
      { min: 100000000, pattern: '000 M' },
      { min: 1000000000, pattern: '0000 M' },
      { min: 10000000000, pattern: '00 mil M' },
      { min: 100000000000, pattern: '000 mil M' },
      { min: 1000000000000, pattern: '0 B' },
    ],
  },
  'pt-BR': {
    decimal: ',',
    group: '.',
    tiers: [
      { min: 1000, pattern: '0 mil' },
      { min: 10000, pattern: '00 mil' },
      { min: 100000, pattern: '000 mil' },
      { min: 1000000, pattern: '0 mi' },
      { min: 10000000, pattern: '00 mi' },
      { min: 100000000, pattern: '000 mi' },
      { min: 1000000000, pattern: '0 bi' },
      { min: 10000000000, pattern: '00 bi' },
      { min: 100000000000, pattern: '000 bi' },
      { min: 1000000000000, pattern: '0 tri' },
    ],
  },
  ru: {
    decimal: ',',
    group: ' ',
    tiers: [
      { min: 1000, pattern: '0 тыс.' },
      { min: 10000, pattern: '00 тыс.' },
      { min: 100000, pattern: '000 тыс.' },
      { min: 1000000, pattern: '0 млн' },
      { min: 10000000, pattern: '00 млн' },
      { min: 100000000, pattern: '000 млн' },
      { min: 1000000000, pattern: '0 млрд' },
      { min: 10000000000, pattern: '00 млрд' },
      { min: 100000000000, pattern: '000 млрд' },
      { min: 1000000000000, pattern: '0 трлн' },
    ],
  },
  tr: {
    decimal: ',',
    group: '.',
    tiers: [
      { min: 1000, pattern: '0 B' },
      { min: 10000, pattern: '00 B' },
      { min: 100000, pattern: '000 B' },
      { min: 1000000, pattern: '0 Mn' },
      { min: 10000000, pattern: '00 Mn' },
      { min: 100000000, pattern: '000 Mn' },
      { min: 1000000000, pattern: '0 Mr' },
      { min: 10000000000, pattern: '00 Mr' },
      { min: 100000000000, pattern: '000 Mr' },
      { min: 1000000000000, pattern: '0 Tn' },
    ],
  },
  id: {
    decimal: ',',
    group: '.',
    tiers: [
      { min: 1000, pattern: '0 rb' },
      { min: 10000, pattern: '00 rb' },
      { min: 100000, pattern: '000 rb' },
      { min: 1000000, pattern: '0 jt' },
      { min: 10000000, pattern: '00 jt' },
      { min: 100000000, pattern: '000 jt' },
      { min: 1000000000, pattern: '0 M' },
      { min: 10000000000, pattern: '00 M' },
      { min: 100000000000, pattern: '000 M' },
      { min: 1000000000000, pattern: '0 T' },
    ],
  },
  vi: {
    decimal: ',',
    group: '.',
    tiers: [
      { min: 1000, pattern: '0 N' },
      { min: 10000, pattern: '00 N' },
      { min: 100000, pattern: '000 N' },
      { min: 1000000, pattern: '0 Tr' },
      { min: 10000000, pattern: '00 Tr' },
      { min: 100000000, pattern: '000 Tr' },
      { min: 1000000000, pattern: '0 T' },
      { min: 10000000000, pattern: '00 T' },
      { min: 100000000000, pattern: '000 T' },
      { min: 1000000000000, pattern: '0 NT' },
    ],
  },
  th: {
    decimal: '.',
    group: ',',
    tiers: [
      { min: 1000, pattern: '0K' },
      { min: 10000, pattern: '00K' },
      { min: 100000, pattern: '000K' },
      { min: 1000000, pattern: '0M' },
      { min: 10000000, pattern: '00M' },
      { min: 100000000, pattern: '000M' },
      { min: 1000000000, pattern: '0B' },
      { min: 10000000000, pattern: '00B' },
      { min: 100000000000, pattern: '000B' },
      { min: 1000000000000, pattern: '0T' },
    ],
  },
  hi: {
    decimal: '.',
    group: ',',
    tiers: [
      { min: 1000, pattern: '0 हज़ार' },
      { min: 10000, pattern: '00 हज़ार' },
      { min: 100000, pattern: '0 लाख' },
      { min: 1000000, pattern: '00 लाख' },
      { min: 10000000, pattern: '0 क॰' },
      { min: 100000000, pattern: '00 क॰' },
      { min: 1000000000, pattern: '0 अ॰' },
      { min: 10000000000, pattern: '00 अ॰' },
      { min: 100000000000, pattern: '0 ख॰' },
      { min: 1000000000000, pattern: '00 ख॰' },
    ],
  },
  ar: {
    decimal: '.',
    group: ',',
    tiers: [
      { min: 1000, pattern: '0 ألف', few: '0 آلاف' },
      { min: 10000, pattern: '00 ألف' },
      { min: 100000, pattern: '000 ألف' },
      { min: 1000000, pattern: '0 مليون' },
      { min: 10000000, pattern: '00 مليون' },
      { min: 100000000, pattern: '000 مليون' },
      { min: 1000000000, pattern: '0 مليار' },
      { min: 10000000000, pattern: '00 مليار' },
      { min: 100000000000, pattern: '000 مليار' },
      { min: 1000000000000, pattern: '0 ترليون' },
    ],
  },
};

/** Upper bound of the value domain (rules: integer 0 ... 10^15). */
const MAX_VALUE = 1_000_000_000_000_000;

/**
 * Resolves any language tag (BCP 47, POSIX "_" form, Android legacy "in", ICU "@" keywords) to one
 * of the 16 table locales; anything unknown, empty included, falls back to "en".
 */
export function resolveCompactLocale(tag: string): CompactLocale {
  const at = tag.indexOf('@');
  const cleaned = (at >= 0 ? tag.slice(0, at) : tag).replace(/_/g, '-');
  const subtags: string[] = [];
  for (const raw of cleaned.split('-')) {
    const part = raw.toLowerCase();
    // Drop the first single-letter subtag (extensions such as -u- / -x-) and everything after it.
    if (part.length === 1) break;
    subtags.push(part);
  }
  const language = subtags[0] ?? '';
  if (language === 'zh') {
    // Look at the script code first; only without one, use the region (TW / HK / MO) to detect Traditional Chinese.
    const rest = subtags.slice(1);
    if (rest.includes('hans')) return 'zh-Hans';
    if (rest.includes('hant')) return 'zh-Hant';
    const traditional = rest.some((s) => s === 'tw' || s === 'hk' || s === 'mo');
    return traditional ? 'zh-Hant' : 'zh-Hans';
  }
  if (language === 'pt') return 'pt-BR';
  if (language === 'in') return 'id';
  switch (language) {
    case 'en':
    case 'ja':
    case 'ko':
    case 'de':
    case 'fr':
    case 'es':
    case 'ru':
    case 'tr':
    case 'id':
    case 'vi':
    case 'th':
    case 'hi':
    case 'ar':
      return language;
    default:
      return 'en';
  }
}

/** Groups ASCII digits every 3 from the right. */
function groupDigits(digits: string, separator: string): string {
  let out = '';
  for (let i = 0; i < digits.length; i += 1) {
    if (i > 0 && (digits.length - i) % 3 === 0) out += separator;
    out += digits[i];
  }
  return out;
}

/**
 * Formats a non-negative integer count in the compact form of the resolved locale, always rounding
 * down (D-C08). Negative values count as 0; values above 10^15 are clamped.
 */
export function formatCompactNumber(value: number, locale: string): string {
  const n = Number.isFinite(value) ? Math.min(Math.max(Math.floor(value), 0), MAX_VALUE) : 0;
  if (n < 1000) return String(n);
  const table = COMPACT_NUMBER_LOCALES[resolveCompactLocale(locale)];
  let tier = table.tiers[0];
  for (const candidate of table.tiers) {
    if (candidate.min <= n) tier = candidate;
  }
  const zeroRun = /0+/.exec(tier.pattern);
  const zeros = zeroRun ? zeroRun[0].length : 0;
  if (!zeroRun || zeros === tier.pattern.length) {
    // Pure-0 pattern: no abbreviation; grouping starts at 10000 (ICU compact minimum grouping is 2).
    const digits = String(n);
    return n >= 10000 ? groupDigits(digits, table.group) : digits;
  }
  // unit10 = min / 10^(z-1) / 10 is always an integer >= 100; integer arithmetic rounds down.
  const unit10 = tier.min / 10 ** zeros;
  const tenths = Math.floor(n / unit10);
  const int = Math.floor(tenths / 10);
  const frac = tenths % 10;
  const text = frac === 0 ? String(int) : `${int}${table.decimal}${frac}`;
  const mod100 = int % 100;
  const pattern = tier.few !== undefined && frac === 0 && mod100 >= 3 && mod100 <= 10 ? tier.few : tier.pattern;
  return pattern.replace(/0+/, text);
}
