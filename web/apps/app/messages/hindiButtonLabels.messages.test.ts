import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// Older translations turned hi buttons and short labels into bare infinitives (-ना), which read like dictionary
// entries rather than buttons: Save as बचाना ("to rescue"), Default as गलती करना ("to make a mistake"), Apply as
// आवेदन करना ("to apply for a job"). Buttons use the आप-register imperative (-एँ / -ें) and labels use nouns.
// These words end in -ना but are nouns or adjectives, not infinitives:
const NOUNS_ENDING_IN_NA: Record<string, string> = {
  महीना: 'month (noun)',
  योजना: 'plan (noun)',
  सालाना: 'yearly (adjective)',
  नमूना: 'sample (noun)',
  संरचना: 'composition (noun)',
};

type Tree = Record<string, unknown>;

function strings(tree: Tree, prefix = ''): Array<[string, string]> {
  return Object.entries(tree).flatMap(([key, value]) => {
    const path = prefix ? `${prefix}.${key}` : key;
    if (typeof value === 'string') return [[path, value] as [string, string]];
    return value && typeof value === 'object' ? strings(value as Tree, path) : [];
  });
}

/** Three words or fewer whose last Devanagari word ends in -ना and is not a listed noun = an infinitive label */
function looksLikeInfinitiveLabel(value: string): boolean {
  const trimmed = value.trim();
  if (trimmed.split(/\s+/).length > 3) return false;
  const words = trimmed.match(/[ऀ-ॿ]+/g);
  const last = words?.[words.length - 1];
  return !!last && last.endsWith('ना') && !(last in NOUNS_ENDING_IN_NA);
}

describe('hi short labels', () => {
  it('are not bare infinitives', () => {
    const hi = JSON.parse(readFileSync(join(process.cwd(), 'messages', 'hi.json'), 'utf8')) as Tree;
    const problems = strings(hi)
      .filter(([, value]) => looksLikeInfinitiveLabel(value))
      .map(([key, value]) => `${key}: ${value}`);
    expect(problems).toEqual([]);
  });
});
