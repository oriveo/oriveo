/**
 * Source text integrity gate: TypeScript sources under `apps/app` must contain no bare NUL byte (0x00).
 *
 * What happened: an editor wrote a few real 0x00 bytes into a `.tsx` file. git decides text vs
 * binary by looking for a NUL in the first 8000 bytes, so once one lands the file is binary as far
 * as git is concerned:
 *   1. `git diff` prints only `Binary files a/... and b/... differ`, so a review cannot see the change;
 *   2. `git grep` / `git log -S` skip binary files by default, making repository-wide search
 *      silently blind to it - "grep finds nothing" then reads as "nothing references this", and
 *      any work that scopes itself by grep reaches the opposite conclusion;
 *   3. merge conflicts cannot be resolved per line, only whole file against whole file.
 *
 * None of the three raise an error; they just quietly give less information, which is why a gate has to catch this rather than a reviewer.
 *
 * Using NUL as a sentinel (separator, placeholder prefix) is perfectly legitimate - write it as the
 * `\u0000` escape and the runtime string is identical while the file stays plain text. The two
 * existing uses (the composite key separator in `cost-summary.ts` and the placeholder affixes in
 * `latex-normalizer.ts`) are written that way.
 */

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

/** `process.cwd()` is the apps/app directory under the apps/app vitest project. */
const APP_ROOT = process.cwd();

/**
 * List the TS sources under apps/app as POSIX paths relative to APP_ROOT.
 *
 * Same rule as `lib/design-system/source-css-files.ts`: ask git rather than maintaining a directory
 * denylist, so `.gitignore` is the single source of truth for what is not source.
 * `--cached --others --exclude-standard` = tracked plus untracked-but-not-ignored, so a newly
 * written file that has not been `git add`ed is still scanned and there is no "skip the add to skip
 * the gate" loophole.
 */
function collectSourceFiles(): string[] {
  const listFiles = (args: readonly string[]) => execFileSync(
    'git',
    ['ls-files', '-z', ...args, '--', '*.ts', '*.tsx'],
    { cwd: APP_ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
  ).split('\0').filter(Boolean);
  // A file that was deleted but still sits in the index is not source: while a deletion is
  // uncommitted the scanner would readFileSync a path that does not exist and throw, turning
  // "a file was deleted" into an unreadable gate failure.
  const deleted = new Set(listFiles(['--deleted']));
  return listFiles(['--cached', '--others', '--exclude-standard'])
    .filter((file) => !deleted.has(file))
    .sort();
}

describe('apps/app source text integrity', () => {
  it('TypeScript sources contain no bare NUL byte (write \u0000 when the character is needed)', () => {
    const files = collectSourceFiles();
    // git listing zero files means the scan surface collapsed (wrong cwd, or not inside the repo),
    // and the assertion below would then be vacuously true. Pin the surface itself first.
    expect(files.length).toBeGreaterThan(100);

    // Read bytes: `readFileSync(path, 'utf8')` would also preserve U+0000, but Buffer.indexOf is
    // more direct and faster, finishing all 1000+ files in a few hundred milliseconds.
    const offenders = files.filter((file) => readFileSync(join(APP_ROOT, file)).indexOf(0) !== -1);

    expect(
      offenders,
      'These files contain a bare NUL byte, so git treats them as binary: diff shows no changes and git grep cannot find them. '
      + 'Replace the NUL with the \\u0000 escape; the runtime string is unchanged.',
    ).toEqual([]);
  });
});
