import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// Full-width punctuation belongs to Chinese and Japanese only. A Korean error message once ended in "。", the mark
// of a sentence carried over from a Chinese draft. Outside zh-Hans / zh-Hant / ja no locale may contain
// （）。，：；！？「」、
const CJK_LOCALES = new Set(['zh-Hans', 'zh-Hant', 'ja']);
const FULLWIDTH = /[（）。，：；！？「」、]/;

type Tree = Record<string, unknown>;

function strings(tree: unknown, prefix = ''): Array<[string, string]> {
  if (typeof tree === 'string') return [[prefix, tree]];
  if (!tree || typeof tree !== 'object') return [];
  return Object.entries(tree as Tree).flatMap(([key, value]) =>
    strings(value, prefix ? `${prefix}.${key}` : key),
  );
}

describe('fullwidth punctuation outside CJK', () => {
  it('does not appear in any non zh/ja locale', () => {
    const dir = join(process.cwd(), 'messages');
    const locales = readdirSync(dir)
      .filter((file) => file.endsWith('.json'))
      .map((file) => file.slice(0, -'.json'.length))
      .filter((locale) => !CJK_LOCALES.has(locale));
    // Finding no locale means the path broke; without this the test would pass forever.
    expect(locales.length).toBeGreaterThanOrEqual(13);

    const problems = locales.flatMap((locale) =>
      strings(JSON.parse(readFileSync(join(dir, `${locale}.json`), 'utf8')))
        .filter(([, value]) => FULLWIDTH.test(value))
        .map(([key, value]) => `${locale} ${key}: ${value}`),
    );
    expect(problems).toEqual([]);
  });
});
