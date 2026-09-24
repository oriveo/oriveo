import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// Builtin skill and category names are shared by all three apps. hi / id / ru / th / tr / vi used to carry machine
// translations (Coding as "encryption", Interview Coach as "news interview", Proofreader as "purifier"...). They were
// rewritten for their meaning and must match Android entry by entry.
const LOCALES: Record<string, string> = {
  hi: 'values-hi',
  id: 'values-in',
  ru: 'values-ru',
  th: 'values-th',
  tr: 'values-tr',
  vi: 'values-vi',
};

type Skills = Record<string, { name?: string } | Record<string, string>>;

function androidStrings(directory: string): Map<string, string> {
  const path = join(process.cwd(), '..', '..', '..', 'android', 'app', 'src', 'main', 'res', directory, 'strings.xml');
  const out = new Map<string, string>();
  for (const match of readFileSync(path, 'utf8').matchAll(/<string name="([^"]+)"[^>]*>([\s\S]*?)<\/string>/g)) {
    out.set(match[1], match[2].replace(/\\'/g, "'").replace(/\\"/g, '"'));
  }
  return out;
}

describe('builtin skill names and categories', () => {
  it.each(Object.keys(LOCALES))('%s matches Android', (locale) => {
    const messages = JSON.parse(readFileSync(join(process.cwd(), 'messages', `${locale}.json`), 'utf8')) as {
      builtinSkills: Skills;
    };
    const android = androidStrings(LOCALES[locale]);
    const problems: string[] = [];
    for (const [key, value] of Object.entries(messages.builtinSkills)) {
      if (key === 'category') {
        for (const [id, label] of Object.entries(value as Record<string, string>)) {
          if (id === 'all') continue;
          const expected = android.get(`skill_category_${id}`);
          if (label !== expected) problems.push(`category.${id}: web=${label} android=${expected}`);
        }
      } else {
        const name = (value as { name?: string }).name;
        const expected = android.get(`skill_${key}_name`);
        if (name !== expected) problems.push(`${key}.name: web=${name} android=${expected}`);
      }
    }
    expect(problems).toEqual([]);
  });
});
