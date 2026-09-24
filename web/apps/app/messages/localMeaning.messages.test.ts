import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// In data-related strings, local means "on this device". Older translations used the geographic sense
// ("area / region"): th "ข้อมูลท้องถิ่น" or "ในพื้นที่", vi "địa phương", which read as data belonging to a place.
// Local time (th เวลาท้องถิ่น, vi giờ địa phương) and local network (th เครือข่ายท้องถิ่น) really mean that and are allowed.
const GEOGRAPHIC: Record<string, RegExp> = {
  th: /(?<!เวลา|เครือข่าย)ท้องถิ่น|ในพื้นที่/,
  vi: /(?<!giờ )địa phương/i,
};

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

describe('local (on this device) in th / vi', () => {
  const english = load('en');

  it.each(['th', 'vi'])('%s does not render local data as a geographic place', (locale) => {
    const problems = [...load(locale)]
      .filter(([key, value]) => /\blocal\b/i.test(english.get(key) ?? '') && GEOGRAPHIC[locale].test(value))
      .map(([key, value]) => `${key}: ${value}`);
    expect(problems).toEqual([]);
  });
});
