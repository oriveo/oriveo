/**
 * Local gate: the list of bare `localStorage.setItem` / `sessionStorage.setItem` call sites in the repo.
 *
 * **Why this test exists**: in Chrome, Web Storage is a 5MB quota **shared by the whole origin**,
 * and the auth session plus the cross-tab broadcast keys all live in that same pool. "Anything
 * larger than a few dozen KB goes through blob-cache" used to be a convention with nothing
 * enforcing it, and the result was a multi-megabyte metadata snapshot eating most of the quota,
 * and later a leaking key filling it completely so users could not sign in at all.
 * `safeLocalStorage.setItem` now caps a single key at 64KB, but it can only guard callers that go
 * through the facade; this test is what keeps **new bare call sites** from slipping in.
 *
 * Gates like this one run locally, so run it right after touching storage code.
 *
 * **Adding a new write**:
 *   - small values (<=64KB) -> use `safeLocalStorage` / `safeSessionStorage` (web-storage.ts),
 *     which also handles the case where property access itself throws when site data is blocked;
 *   - large objects -> use `blob-cache.ts` (IndexedDB, quota scaled to disk, on the order of GB);
 *   - a genuinely unavoidable bare write (an early path that runs before initialization) -> add the
 *     file to the allowlist below and make sure the value written is small. The allowlist counts
 *     per file, so even one extra call site in an already listed file is caught.
 */

import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/**
 * Files allowed to call setItem bare -> number of call sites (a snapshot; all small values).
 * The direction is one-way: only ever fewer -- when you touch one of these files, prefer moving it to safeLocalStorage.
 */
const ALLOWED_CALL_SITES: Record<string, number> = {
  'apps/app/app/layout.tsx': 1,
  'apps/app/app/providers/[providerId]/ModelBrowser.tsx': 1,
  'apps/app/app/providers/new/relay-handoff.ts': 1,
  'apps/app/components/AppShellWrapper.tsx': 1,
  'apps/app/components/chat/ModelSwitcher/hooks/useModelSwitcherData.ts': 1,
  'apps/app/components/conversations/ConflictCopyGroup.tsx': 1,
  'apps/app/lib/core/chat/capability-recovery-runtime.ts': 5,
  'apps/app/lib/core/chat/generation-panel-presentation.ts': 1,
  'apps/app/lib/core/chat/generation-parameter-diagnostics.ts': 1,
  'apps/app/lib/core/provider-id-migration.ts': 1,
  'apps/app/lib/core/store/stream-partial-backup.ts': 1,
  'apps/app/lib/infra/storage/partitioned-local-store.ts': 3,
  'apps/app/lib/infra/storage/preferences.ts': 2,
};

const WORKSPACE_ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '..', '..', '..', '..', '..', '..',
);

const SCAN_DIRS = ['apps', 'packages'];
const SKIP_DIRS = new Set([
  // out-desktop is the static export directory and holds minified framework chunks:
  // without skipping it, framework setItem calls would look like new bare call sites.
  'node_modules', '.next', 'dist', 'build', 'out', 'out-desktop', 'coverage', '.turbo',
  '__tests__', '__mocks__',
]);
const SOURCE_EXT = new Set(['.ts', '.tsx', '.js', '.jsx', '.mts', '.mjs']);

/**
 * Bare setItem calls: `localStorage.setItem`, `window.sessionStorage.setItem` and the like.
 * The negative lookbehind keeps facade calls such as `safeLocalStorage.setItem` out of the match.
 */
const BARE_SET_ITEM = /(?<![A-Za-z0-9_$.])(?:window\.|globalThis\.)?(?:localStorage|sessionStorage)\.setItem\b/g;

function isCommentLine(line: string): boolean {
  const trimmed = line.trimStart();
  return trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('/*');
}

function countBareCalls(filePath: string): number {
  const content = readFileSync(filePath, 'utf8');
  let count = 0;
  for (const line of content.split('\n')) {
    if (isCommentLine(line)) continue;
    count += line.match(BARE_SET_ITEM)?.length ?? 0;
  }
  return count;
}

function* walkSourceFiles(dir: string): Generator<string> {
  for (const entry of readdirSync(dir)) {
    // A leading dot always means a build or tooling directory (.next / .next-dev / .turbo), skip it
    if (entry.startsWith('.') || SKIP_DIRS.has(entry)) continue;
    const full = path.join(dir, entry);
    const stat = statSync(full);
    if (stat.isDirectory()) {
      yield* walkSourceFiles(full);
      continue;
    }
    if (!SOURCE_EXT.has(path.extname(entry))) continue;
    if (/\.(test|spec)\.[a-z]+$/.test(entry) || entry.endsWith('.d.ts')) continue;
    yield full;
  }
}

function scanWorkspace(): Record<string, number> {
  const found: Record<string, number> = {};
  for (const scanDir of SCAN_DIRS) {
    for (const file of walkSourceFiles(path.join(WORKSPACE_ROOT, scanDir))) {
      const count = countBareCalls(file);
      if (count === 0) continue;
      found[path.relative(WORKSPACE_ROOT, file).split(path.sep).join('/')] = count;
    }
  }
  return found;
}

describe('localStorage write gate', () => {
  it('bare setItem call sites must stay on the allowlist (new code goes through safeLocalStorage or blob-cache)', () => {
    const found = scanWorkspace();
    const allowed = { ...ALLOWED_CALL_SITES };

    const violations: string[] = [];
    for (const [file, count] of Object.entries(found)) {
      const expected = allowed[file];
      if (expected === undefined) {
        violations.push(`new bare call site ${file} (${count} occurrences)`);
      } else if (count !== expected) {
        violations.push(`${file} call site count changed: allowlist says ${expected}, found ${count}`);
      }
    }
    for (const file of Object.keys(allowed)) {
      if (!(file in found)) {
        violations.push(`stale allowlist entry: ${file} has no bare call left, remove it from the allowlist`);
      }
    }

    expect(
      violations,
      [
        'Bare localStorage/sessionStorage.setItem call sites do not match the allowlist.',
        'New code should use safeLocalStorage/safeSessionStorage (<=64KB, lib/infra/storage/web-storage.ts)',
        'or blob-cache.ts (IndexedDB, large objects); if a bare write is really needed, update the allowlist in this file.',
        'Current full scan result (paste as the new allowlist):',
        JSON.stringify(found, null, 2),
      ].join('\n'),
    ).toEqual([]);
  });
});
