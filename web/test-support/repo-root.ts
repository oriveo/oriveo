import { existsSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

// Tests reach files outside the web workspace through these helpers instead of counting "../":
// the workspace does not sit at the same depth in every checkout, so a fixed climb lands in the
// wrong directory as soon as the tree is laid out differently.
export const WEB_ROOT = resolve(__dirname, '..');

let cached: { root: string; shared: string } | null = null;

// The repository root is the nearest ancestor of the web workspace that holds the shared contracts
// directory, recognised by its contents rather than its name.
function locate(): { root: string; shared: string } {
  if (cached) return cached;
  for (let dir = dirname(WEB_ROOT); ; dir = dirname(dir)) {
    for (const name of readdirSync(dir)) {
      const candidate = join(dir, name);
      if (existsSync(join(candidate, 'model-contracts')) && existsSync(join(candidate, 'test-fixtures'))) {
        cached = { root: dir, shared: candidate };
        return cached;
      }
    }
    if (dirname(dir) === dir) throw new Error(`no shared contracts directory above ${WEB_ROOT}`);
  }
}

export function repoRoot(...segments: string[]): string {
  return join(locate().root, ...segments);
}

export function sharedPath(...segments: string[]): string {
  return join(locate().shared, ...segments);
}
