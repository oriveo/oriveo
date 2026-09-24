import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// The brand name Oriveo stays in Latin in every language. Older hi strings transliterated it as "ओरिवियो".
// Other languages may drop the subject, so only hi is required to keep Oriveo wherever the English names it.
const TRANSLITERATION = /ओर[िी]व/;

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

describe('brand name in hi', () => {
  const english = load('en');
  const hindi = load('hi');

  it('is never transliterated', () => {
    const problems = [...hindi].filter(([, value]) => TRANSLITERATION.test(value)).map(([key, value]) => `${key}: ${value}`);
    expect(problems).toEqual([]);
  });

  it('stays in Latin wherever English names Oriveo', () => {
    const problems = [...hindi]
      .filter(([key, value]) => (english.get(key) ?? '').includes('Oriveo') && !value.includes('Oriveo'))
      .map(([key, value]) => `${key}: ${value}`);
    expect(problems).toEqual([]);
  });
});
