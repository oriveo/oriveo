/**
 * Enumerates the tracked CSS sources the design-system audits read.
 *
 * The list comes from git rather than a directory walk. A build directory that is ignored by
 * `.gitignore` can still contain dozens of generated stylesheets whose hashed class names and
 * inlined custom properties would produce a wall of false violations, and adding every such
 * directory to a hand-maintained deny list is a losing game.
 *
 * `--cached --others --exclude-standard` means "tracked plus untracked-but-not-ignored", so a new
 * `.css` file is audited from the moment it is written, without waiting for `git add`. Files that
 * are staged for deletion are dropped, because `readFileSync` would throw on them.
 */

import { execFileSync } from 'node:child_process';
import { join } from 'node:path';

/** Vitest runs with the workspace directory as cwd, so the web root is two levels up. */
export const WEB_ROOT = join(process.cwd(), '..', '..');

/**
 * Returns POSIX paths relative to `WEB_ROOT`, sorted, for every tracked CSS file under `prefixes`.
 *
 * @param prefixes top-level directories to keep, relative to `WEB_ROOT`, e.g. `['apps', 'packages']`
 */
export function collectSourceCssFiles(prefixes: readonly string[]): string[] {
  const listFiles = (args: readonly string[]) => execFileSync(
    'git',
    ['ls-files', '-z', ...args, '--', '*.css'],
    { cwd: WEB_ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
  ).split('\0').filter(Boolean);
  const deleted = new Set(listFiles(['--deleted']));
  return listFiles(['--cached', '--others', '--exclude-standard'])
    .filter((file) => !deleted.has(file))
    .filter((file) => prefixes.some((prefix) => file === prefix || file.startsWith(`${prefix}/`)))
    .sort();
}

/** The same list as absolute paths, ready for `readFileSync`. */
export function collectSourceCssPaths(prefixes: readonly string[]): string[] {
  return collectSourceCssFiles(prefixes).map((file) => join(WEB_ROOT, file));
}
