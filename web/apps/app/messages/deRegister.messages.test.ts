import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// German app copy addresses the user with "du" and calls the Skills feature "Fähigkeit(en)"
// on iOS, Android and Web alike. The scan lives in one script so all three ends share one rule.
const script = join(process.cwd(), '..', '..', '..', '..', 'scripts', 'l10n-de-register-check.mjs');

function run(args: string[]): { code: number; out: string } {
  try {
    return { code: 0, out: execFileSync(process.execPath, [script, ...args], { encoding: 'utf8' }) };
  } catch (error) {
    const e = error as { status?: number; stdout?: string };
    return { code: e.status ?? 1, out: e.stdout ?? '' };
  }
}

describe.skipIf(!existsSync(script))('German register across iOS / Android / Web', () => {
  it('detector self-test passes', () => {
    expect(run(['--self-test']).code).toBe(0);
  });

  it('no formal address or English "Skill" left in de app copy', () => {
    const { code, out } = run([]);
    expect(out.trim().split('\n').at(-1)).toBe('l10n-de-register: 0 issues');
    expect(code).toBe(0);
  });
});
