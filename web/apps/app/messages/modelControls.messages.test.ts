/**
 *  ** ** 
 *
 *   `InputComposer.test.tsx > retires the vocabulary of the forms that no longer exist`
 *  ** ** ——
 * ** ** 16  
 *
 *   2026-08-16   Android A4  `generation_parameter_unset_note` 16  
 *   iOS  Web   `generationParameterUnsetNote` 
 *  —— ** 
 *  16  ** 
 *
 *   `t('…')`  
 *   key  ——  `'common.xxx'`  
 *  
 *  ** ** 
 */

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const APP_ROOT = process.cwd();

/**  ——  */
const WATCHED_PREFIXES = ['capabilityControl', 'customRequestFields', 'generationParameter'] as const;

/**
 *  
 *
 *  ——  grep  
 *  
 */
function productionSources(): string[] {
  const listFiles = (args: readonly string[]) => execFileSync(
    'git',
    ['ls-files', '-z', ...args, '--', '*.ts', '*.tsx'],
    { cwd: APP_ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
  ).split('\0').filter(Boolean);
  const deleted = new Set(listFiles(['--deleted']));
  return listFiles(['--cached', '--others', '--exclude-standard'])
    .filter((file) => !deleted.has(file))
    .filter((file) => !/\.test\.tsx?$/.test(file) && !file.includes('__tests__/'));
}

/**   key   */
function productionIdentifiers(): Set<string> {
  const identifiers = new Set<string>();
  for (const file of productionSources()) {
    const source = readFileSync(join(APP_ROOT, file), 'utf8');
    for (const token of source.match(/[A-Za-z_$][A-Za-z0-9_$]*/g) ?? []) identifiers.add(token);
  }
  return identifiers;
}

function leafPaths(value: unknown, prefix = ''): string[] {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return [prefix];
  return Object.entries(value as Record<string, unknown>)
    .flatMap(([key, child]) => leafPaths(child, prefix ? `${prefix}.${key}` : key));
}

describe('  -  ', () => {
  it('capabilityControl / customRequestFields / generationParameter  ', () => {
    const english = JSON.parse(readFileSync(join(APP_ROOT, 'messages/en.json'), 'utf8')) as unknown;
    const watched = leafPaths(english)
      .map((path) => ({ path, leaf: path.slice(path.lastIndexOf('.') + 1) }))
      .filter(({ leaf }) => WATCHED_PREFIXES.some((prefix) => leaf.startsWith(prefix)));

    //  cwd   / key  
    expect(watched.length).toBeGreaterThan(60);

    const identifiers = productionIdentifiers();
    const orphans = watched.filter(({ leaf }) => !identifiers.has(leaf)).map(({ path }) => path);

    expect(
      orphans,
      '  16   16  '
      + ' —— ',
    ).toEqual([]);
  });
});
