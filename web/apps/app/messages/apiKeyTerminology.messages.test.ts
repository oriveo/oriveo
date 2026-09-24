import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// Older th / vi translations turned the API key into something else: a door key (th กุญแจ, vi chìa khóa), a keyboard
// key (vi phím), an English/local duplicate ("API Key คีย์", "Khóa API Key"), or dropped the key and kept only "API"
// ("กรอก API ของคุณ" reads as "enter your API"). The th placeholder also transliterated the literal sk-... into
// "สค-...". The terms are th "คีย์ API" and vi "khóa API".
const WRONG_SENSE: Record<string, Array<[RegExp, string]>> = {
  th: [
    [/กุญแจ/, 'กุญแจ is a door key'],
    [/API Key คีย์|คีย์ API Key|API คีย์/, 'duplicated or reversed term'],
    [/สค-/, 'the sk- placeholder was transliterated'],
  ],
  vi: [
    [/chìa khóa/i, 'chìa khóa is a physical key'],
    [/phím API/i, 'phím is a keyboard key'],
    [/khóa API Key/i, 'duplicated term'],
  ],
};
// API key in English (request header names such as x-api-key / x-goog-api-key do not count)
const ENGLISH_API_KEY = /(?<![-\w])API[ -]?keys?\b/i;
const KEEPS_KEY: Record<string, RegExp> = { th: /คีย์|API ?Key/i, vi: /khóa|API ?Key/i };

type Tree = Record<string, unknown>;

function flatten(tree: Tree, prefix = ''): Map<string, string> {
  const out = new Map<string, string>();
  for (const [key, value] of Object.entries(tree)) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (typeof value === 'string') out.set(path, value);
    else if (value && typeof value === 'object') flatten(value as Tree, path).forEach((v, k) => out.set(k, v));
  }
  return out;
}

function load(locale: string): Map<string, string> {
  return flatten(JSON.parse(readFileSync(join(process.cwd(), 'messages', `${locale}.json`), 'utf8')) as Tree);
}

describe('API key terminology in th / vi', () => {
  const english = load('en');

  it.each(['th', 'vi'])('%s never renders the key as a door key, a keyboard key, or a duplicate', (locale) => {
    const problems = [...load(locale)].flatMap(([key, value]) =>
      WRONG_SENSE[locale].filter(([pattern]) => pattern.test(value)).map(([, why]) => `${key}: ${value} (${why})`),
    );
    expect(problems).toEqual([]);
  });

  it.each(['th', 'vi'])('%s keeps the word key wherever English says API key', (locale) => {
    const problems = [...load(locale)]
      .filter(([key, value]) => ENGLISH_API_KEY.test(english.get(key) ?? '') && !KEEPS_KEY[locale].test(value))
      .map(([key, value]) => `${key}: ${value}`);
    expect(problems).toEqual([]);
  });
});
