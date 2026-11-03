import { readdirSync, readFileSync } from 'node:fs';
import { join, relative } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Skills and usage surfaces must use logical text alignment so RTL locales mirror.
 *
 * Regression: `.charCount { text-align: right }` kept the
 * character counter on the physical right in Arabic, and the same physical
 * `left/right` pattern was found in usage dialogs/cards and the top-bar popover.
 */
const APP_ROOT = join(__dirname, '..', '..');
const SCAN_DIRS = ['app/skills', 'components/usage', 'app/chat/usage'];
const SCAN_FILES = ['components/chat/TopBar.module.css'];

function cssFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) return cssFiles(full);
    return entry.name.endsWith('.css') ? [full] : [];
  });
}

describe('logical text-align on Skills and usage surfaces', () => {
  it('has no physical text-align: left/right', () => {
    const files = [
      ...SCAN_DIRS.flatMap((dir) => cssFiles(join(APP_ROOT, dir))),
      ...SCAN_FILES.map((file) => join(APP_ROOT, file)),
    ];
    expect(files.length).toBeGreaterThan(10);
    const offenders = files.flatMap((file) =>
      readFileSync(file, 'utf8')
        .split('\n')
        .map((line, index) => ({ line, index }))
        .filter(({ line }) => /text-align:\s*(left|right)\b/.test(line))
        .map(({ index }) => `${relative(APP_ROOT, file)}:${index + 1}`),
    );
    expect(offenders).toEqual([]);
  });
});
