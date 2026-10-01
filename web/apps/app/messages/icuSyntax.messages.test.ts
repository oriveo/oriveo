import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { IntlMessageFormat } from 'intl-messageformat';
import { describe, expect, it } from 'vitest';

// At runtime next-intl parses every message with intl-messageformat; a message that fails to parse renders as its key
// or throws. Count messages whose ICU keywords had been translated along with the text
// ({count, множественное число, ... else {...}}, {đếm, số nhiều, ... khác ...}, {count, plural, ... diğer ...}) left
// the provider list's "N models" badges unrenderable in those locales. Every message is parsed here with the same
// parser, and its argument names must stay within the ones en uses (a translated argument name breaks interpolation
// just as badly).

type Tree = Record<string, unknown>;
type Ast = ReturnType<IntlMessageFormat['getAst']>;
// intl-messageformat AST node types: 0 = literal (plain text), 7 = pound (the # inside plural). Neither is an argument
// name. The enum lives in the transitive dependency @formatjs/icu-messageformat-parser, which this test does not
// import directly, so the values are compared as numbers.
const TYPE_LITERAL = 0;
const TYPE_POUND = 7;

function strings(tree: unknown, prefix = ''): Array<[string, string]> {
  if (typeof tree === 'string') return [[prefix, tree]];
  if (!tree || typeof tree !== 'object') return [];
  return Object.entries(tree as Tree).flatMap(([key, value]) =>
    strings(value, prefix ? `${prefix}.${key}` : key),
  );
}

function argumentNames(ast: Ast, names = new Set<string>()): Set<string> {
  for (const element of ast) {
    if ('value' in element && typeof element.value === 'string' && (element.type as number) !== TYPE_LITERAL && (element.type as number) !== TYPE_POUND) {
      names.add(element.value);
    }
    if ('options' in element && element.options) {
      for (const option of Object.values(element.options as Record<string, { value: Ast }>)) {
        argumentNames(option.value, names);
      }
    }
    if ('children' in element && Array.isArray(element.children)) {
      argumentNames(element.children as Ast, names);
    }
  }
  return names;
}

describe('ICU message syntax', () => {
  const dir = join(process.cwd(), 'messages');
  const locales = readdirSync(dir)
    .filter((file) => file.endsWith('.json'))
    .map((file) => file.slice(0, -'.json'.length));
  const load = (locale: string) =>
    new Map(strings(JSON.parse(readFileSync(join(dir, `${locale}.json`), 'utf8'))));

  it('every message in every locale parses and uses only the arguments of en', () => {
    // Finding no locale means the path broke; without this the test would pass forever.
    expect(locales.length).toBeGreaterThanOrEqual(16);
    const en = load('en');
    const enArguments = new Map<string, Set<string>>();
    for (const [key, value] of en) enArguments.set(key, argumentNames(new IntlMessageFormat(value, 'en').getAst()));

    const problems: string[] = [];
    for (const locale of locales) {
      for (const [key, value] of load(locale)) {
        let ast: Ast;
        try {
          ast = new IntlMessageFormat(value, locale).getAst();
        } catch (error) {
          problems.push(`${locale} ${key}: ${(error as Error).message} - ${value}`);
          continue;
        }
        const allowed = enArguments.get(key);
        if (!allowed) continue;
        const extra = [...argumentNames(ast)].filter((name) => !allowed.has(name));
        if (extra.length > 0) problems.push(`${locale} ${key}: unknown argument ${extra.join(', ')} - ${value}`);
      }
    }
    expect(problems).toEqual([]);
  });
});
