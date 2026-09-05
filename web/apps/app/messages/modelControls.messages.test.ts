/**
 * Guards the model-control message keys against becoming orphans.
 *
 * `InputComposer.test.tsx > retires the vocabulary of the forms that no longer exist` covers the
 * opposite direction: it fails when a form the product no longer has still leaves copy behind.
 * This file covers the direction that is easy to miss — a key that survives in all sixteen locale
 * files after the code that rendered it is gone. Nothing fails at runtime in that state, the
 * translations simply sit there being maintained for a screen nobody can reach.
 *
 * The check is deliberately coarse. It collects every identifier in production sources and asks
 * whether the leaf name of each watched key appears among them. That accepts an indirect
 * `t('common.' + suffix)` as a use, which is the intended trade: a false pass costs one stale key,
 * a false failure costs a broken build for a key that is genuinely in use.
 */

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const APP_ROOT = process.cwd();

/** Leaf-name prefixes owned by the model-control surfaces. */
const WATCHED_PREFIXES = ['capabilityControl', 'customRequestFields', 'generationParameter'] as const;

/**
 * The production sources to search: tracked and untracked files minus deletions, tests excluded.
 *
 * Asking git rather than walking the tree keeps ignored output (`.next`, build artefacts, vendored
 * copies) out of the search, so a key that only survives in a stale build cannot look alive.
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

/** Every identifier-shaped token in production sources, used as the "is this key referenced" set. */
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

describe('model-control message keys', () => {
  it('has no watched key that production code never references', () => {
    const english = JSON.parse(readFileSync(join(APP_ROOT, 'messages/en.json'), 'utf8')) as unknown;
    const watched = leafPaths(english)
      .map((path) => ({ path, leaf: path.slice(path.lastIndexOf('.') + 1) }))
      .filter(({ leaf }) => WATCHED_PREFIXES.some((prefix) => leaf.startsWith(prefix)));

    // A floor on the sample: if the scan is pointed at the wrong directory, or the key naming
    // changes, this collapses to a handful of keys and the assertion below would pass vacuously.
    expect(watched.length).toBeGreaterThan(60);

    const identifiers = productionIdentifiers();
    const orphans = watched.filter(({ leaf }) => !identifiers.has(leaf)).map(({ path }) => path);

    expect(
      orphans,
      'These keys are translated in all sixteen locales but referenced nowhere in production code. '
      + 'Delete them from every locale file, or reconnect the surface that was meant to render them.',
    ).toEqual([]);
  });
});
