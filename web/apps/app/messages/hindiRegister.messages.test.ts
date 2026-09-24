import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// When the app speaks to the user, hi uses the आप register. Older translations left तुम-register -ओ imperatives
// ("सबको अचयनित करो", "घर जाओ", "विवरण छुपाओ") that read as ordering the user around. Quick prompts the user sends
// to the assistant are in the user's own voice, may use तुम, and are not in this word list.
const TUM_IMPERATIVES = ['करो', 'जाओ', 'हटाओ', 'हटो', 'छुपाओ', 'छिपाओ', 'दिखाओ', 'देखो', 'चुनो', 'रखो', 'बदलो', 'भेजो'];
const WORD = new RegExp(`(?<![\\u0900-\\u097F])(${TUM_IMPERATIVES.join('|')})(?![\\u0900-\\u097F])`);

type Tree = Record<string, unknown>;

function strings(tree: Tree, prefix = ''): Array<[string, string]> {
  return Object.entries(tree).flatMap(([key, value]) => {
    const path = prefix ? `${prefix}.${key}` : key;
    if (typeof value === 'string') return [[path, value] as [string, string]];
    return value && typeof value === 'object' ? strings(value as Tree, path) : [];
  });
}

describe('hi register', () => {
  it('does not order the user around with तुम imperatives', () => {
    const hi = JSON.parse(readFileSync(join(process.cwd(), 'messages', 'hi.json'), 'utf8')) as Tree;
    const problems = strings(hi)
      .filter(([, value]) => WORD.test(value))
      .map(([key, value]) => `${key}: ${value}`);
    expect(problems).toEqual([]);
  });
});
