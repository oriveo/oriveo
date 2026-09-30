import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// Skill descriptions and starters in hi/id/ru/th/tr/vi used to be machine translations
// ("patient", "commitment", gendered Thai particles), and iOS fell back to English.
// After the native rewrite, each string must be the same sentence on all three clients.
const LOCALES: Record<string, string> = {
  hi: 'values-hi',
  id: 'values-in',
  ru: 'values-ru',
  th: 'values-th',
  tr: 'values-tr',
  vi: 'values-vi',
};

const BANNED: Record<string, string[]> = {
  hi: ['रोगी', 'प्रतिबद्ध'],
  id: ['pasien', 'komitmen'],
  ru: ['пациент'],
  th: ['ครับ', 'ค่ะ', 'ผม', 'เธอ'],
  tr: ['taahhüt', 'hasta eğit'],
  vi: ['bệnh nhân', 'cam kết'],
};

type Skill = { description?: string; starters?: Record<string, string> };

function readJson(path: string): unknown {
  return JSON.parse(readFileSync(path, 'utf8'));
}

function androidStrings(directory: string): Map<string, string> {
  const path = join(process.cwd(), '..', '..', '..', 'android', 'app', 'src', 'main', 'res', directory, 'strings.xml');
  if (!existsSync(path)) throw new Error(`Android ${directory}/strings.xml not found`);
  const out = new Map<string, string>();
  for (const match of readFileSync(path, 'utf8').matchAll(/<string name="([^"]+)"[^>]*>([\s\S]*?)<\/string>/g)) {
    out.set(match[1], match[2].replace(/\\'/g, "'").replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>'));
  }
  return out;
}

function iosSkillCopy(): Map<string, Record<string, string>> {
  const path = join(process.cwd(), '..', '..', '..', 'ios', 'Oriveo', 'Oriveo', 'Localizable.xcstrings');
  if (!existsSync(path)) throw new Error('Localizable.xcstrings not found');
  const strings = (readJson(path) as { strings: Record<string, { localizations?: Record<string, { stringUnit?: { value?: string } }> }> }).strings;
  const out = new Map<string, Record<string, string>>();
  for (const [key, entry] of Object.entries(strings)) {
    if (!/^skill\.[a-z0-9_]+\.(description|starter_\d+)$/.test(key)) continue;
    const values: Record<string, string> = {};
    for (const [locale, localization] of Object.entries(entry.localizations ?? {})) {
      const value = localization.stringUnit?.value;
      if (value) values[locale] = value;
    }
    out.set(key, values);
  }
  return out;
}

function webSkills(locale: string): Record<string, Skill> {
  const messages = readJson(join(process.cwd(), 'messages', `${locale}.json`)) as { builtinSkills: Record<string, Skill> };
  return messages.builtinSkills;
}

describe('builtin skill descriptions and starters', () => {
  const english = webSkills('en');
  const ios = iosSkillCopy();

  it.each(Object.keys(LOCALES))('%s is native and matches Android and iOS', (locale) => {
    const web = webSkills(locale);
    const android = androidStrings(LOCALES[locale]);
    const problems: string[] = [];
    for (const [id, source] of Object.entries(english)) {
      if (id === 'category') continue;
      const fields: Array<[string, string | undefined]> = [
        ['description', source.description],
        ...Object.entries(source.starters ?? {}).map(([index, text]) => [`starter_${index}`, text] as [string, string]),
      ];
      for (const [field, englishText] of fields) {
        const webText = field === 'description' ? web[id]?.description : web[id]?.starters?.[field.slice('starter_'.length)];
        const androidText = android.get(`skill_${id}_${field === 'description' ? 'desc' : field}`);
        const iosText = ios.get(`skill.${id}.${field}`)?.[locale];
        if (!webText || !androidText || !iosText || webText !== androidText || webText !== iosText) {
          problems.push(`${id}.${field}: web=${webText ?? '<nil>'} android=${androidText ?? '<nil>'} ios=${iosText ?? '<nil>'}`);
          continue;
        }
        if (webText === englishText) problems.push(`${id}.${field} still English`);
        if (englishText?.includes('...') && !webText.includes('...')) problems.push(`${id}.${field} lost ...`);
        for (const needle of BANNED[locale] ?? []) {
          if (webText.toLowerCase().includes(needle.toLowerCase())) problems.push(`${id}.${field} contains ${needle}`);
        }
      }
    }
    expect(problems.slice(0, 40)).toEqual([]);
  });
});
