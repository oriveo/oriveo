import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Light color roles contract: every web token listed in light-roles.v1.json, resolved inside the
 * `:root, [data-theme='light']` block of variables.css, equals the contract color and alpha.
 * Only the default light block is read; dark and palette blocks are out of scope.
 */
const REPO_ROOT = resolve(__dirname, '../../../../../..');
const CONTRACT_PATH = resolve(REPO_ROOT, '\u5171\u4eab/theme-contracts/light-roles.v1.json');
const CSS_PATH = resolve(__dirname, 'variables.css');

interface Role {
  color: string;
  alpha?: number;
  web: string[];
}
interface PendingEntry {
  end: string;
  token: string;
  current: string;
}
const contract = JSON.parse(readFileSync(CONTRACT_PATH, 'utf8')) as {
  alphaTolerance: number;
  roles: Record<string, Role>;
  webComponentTokens: { names: string[] };
  pending: PendingEntry[];
};
const css = readFileSync(CSS_PATH, 'utf8');

const LIGHT_SELECTOR = ":root,\n[data-theme='light']";

function lightBlock(): string {
  const start = css.indexOf(`\n${LIGHT_SELECTOR} {`);
  if (start < 0) throw new Error(`variables.css has no ${LIGHT_SELECTOR} block`);
  return css.slice(start, css.indexOf('}', start)).replace(/\/\*[\s\S]*?\*\//g, '');
}
const block = lightBlock();

/** Last declaration of `name` in the light block (cascade order), whitespace collapsed. */
function declaration(name: string): string | null {
  const escaped = name.replace(/[-]/g, '\\-');
  const matches = [...block.matchAll(new RegExp(`(?:^|[\\s;{])${escaped}\\s*:\\s*([^;]+);`, 'g'))];
  if (matches.length === 0) return null;
  return matches[matches.length - 1][1].replace(/\s+/g, ' ').trim();
}

interface Rgba {
  r: number;
  g: number;
  b: number;
  a: number;
}

function parseHex(hex: string): Rgba | null {
  const h = hex.slice(1);
  const full = h.length === 3 || h.length === 4 ? [...h].map((c) => c + c).join('') : h;
  if (!/^[0-9a-f]{6}([0-9a-f]{2})?$/i.test(full)) return null;
  const n = (i: number) => parseInt(full.slice(i, i + 2), 16);
  return { r: n(0), g: n(2), b: n(4), a: full.length === 8 ? n(6) / 255 : 1 };
}

function parseRgbFunction(value: string): Rgba | null {
  const m = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)$/i.exec(value);
  if (!m) return null;
  const alphaRaw = m[4];
  const a = alphaRaw == null ? 1 : alphaRaw.endsWith('%') ? Number(alphaRaw.slice(0, -1)) / 100 : Number(alphaRaw);
  return { r: Math.round(Number(m[1])), g: Math.round(Number(m[2])), b: Math.round(Number(m[3])), a };
}

/** Resolves a token to a single color, expanding var() chains inside the light block. Throws on anything else. */
function resolveColor(value: string, trail: string[]): Rgba {
  const v = value.trim();
  const ref = /^var\(\s*(--o-[a-z0-9-]+)\s*\)$/i.exec(v);
  if (ref) return resolveToken(ref[1], trail);
  if (v.startsWith('#')) {
    const hex = parseHex(v);
    if (hex) return hex;
  }
  const rgb = parseRgbFunction(v);
  if (rgb) return rgb;
  const mix = /^color-mix\(\s*in srgb\s*,\s*(.+?)\s+([\d.]+)%\s*,\s*transparent\s*\)$/i.exec(v);
  if (mix) {
    const base = resolveColor(mix[1], trail);
    return { ...base, a: base.a * (Number(mix[2]) / 100) };
  }
  throw new Error(`${trail.join(' -> ')}: cannot resolve "${v}" to a single color`);
}

function resolveToken(name: string, trail: string[] = []): Rgba {
  if (trail.includes(name)) throw new Error(`${[...trail, name].join(' -> ')}: var() cycle`);
  const value = declaration(name);
  if (value == null) throw new Error(`${[...trail, name].join(' -> ')}: not declared in the light block`);
  return resolveColor(value, [...trail, name]);
}

const fmt = (c: Rgba) => `rgb(${c.r}, ${c.g}, ${c.b}) alpha ${Number(c.a.toFixed(4))}`;

/** Returns null when `token` resolves to `hex` with `alpha`, otherwise a readable mismatch line. */
function mismatch(token: string, hex: string, alpha: number): string | null {
  let actual: Rgba;
  try {
    actual = resolveToken(token);
  } catch (e) {
    return (e as Error).message;
  }
  const expected = parseHex(hex);
  if (!expected) return `${token}: contract color "${hex}" is not #RRGGBB`;
  const sameRgb = actual.r === expected.r && actual.g === expected.g && actual.b === expected.b;
  const sameAlpha = Math.abs(actual.a - alpha) <= contract.alphaTolerance;
  if (sameRgb && sameAlpha) return null;
  return `${token}: expected ${fmt({ ...expected, a: alpha })}, got ${fmt(actual)}`;
}

const webPending = contract.pending.filter((p) => p.end === 'web');
const pendingNames = new Set(webPending.map((p) => p.token));
const roleTokens = Object.entries(contract.roles).flatMap(([role, r]) => r.web.map((token) => ({ role, token, r })));

describe('light_roles_contract', () => {
  it('everyContractTokenIsMapped', () => {
    const names = [...roleTokens.map((t) => t.token), ...contract.webComponentTokens.names, ...webPending.map((p) => p.token)];
    expect(names.length).toBeGreaterThan(0);
    const missing = names.filter((n) => declaration(n) == null);
    expect(missing, 'contract web tokens with no declaration in the light block').toEqual([]);
  });

  it('lightTokensMatchContract', () => {
    const checked = roleTokens.filter((t) => !pendingNames.has(t.token));
    expect(checked.length).toBeGreaterThan(0);
    const failures = checked
      .map(({ role, token, r }) => {
        const m = mismatch(token, r.color, r.alpha ?? 1);
        return m == null ? null : `[${role}] ${m}`;
      })
      .filter((m): m is string => m != null);
    expect(failures, 'light tokens that differ from light-roles.v1.json').toEqual([]);
  });

  it('pendingTokensStillAtCurrent', () => {
    const failures = webPending.map((p) => mismatch(p.token, p.current, 1)).filter((m): m is string => m != null);
    expect(failures, 'pending web tokens must still be at `current`; remove the pending entry when its unit lands').toEqual([]);
  });

  it('darkStatusTextEqualsStatusColor', () => {
    const declarations = (selector: string): Map<string, string> => {
      const start = css.indexOf(`\n${selector} {`);
      if (start < 0) throw new Error(`variables.css has no ${selector} block`);
      const body = css.slice(start, css.indexOf('}', start)).replace(/\/\*[\s\S]*?\*\//g, '');
      return new Map([...body.matchAll(/(--o-[\w-]+)\s*:\s*([^;]+);/g)].map((m) => [m[1], m[2].replace(/\s+/g, ' ').trim()]));
    };
    const base = declarations("[data-theme='dark']");
    const palettes = [...css.matchAll(/\n(\[data-theme='dark'\]\[data-palette='[\w-]+'\]) \{/g)].map((m) => m[1]);
    // Every non-default dark palette must have its block, so a renamed selector cannot silently drop out of the check.
    const darkContract = JSON.parse(readFileSync(resolve(REPO_ROOT, '\u5171\u4eab/theme-contracts/dark-palettes.v1.json'), 'utf8')) as { defaultId: string; order: string[] };
    expect(palettes.map((s) => s.match(/data-palette='([\w-]+)'/)?.[1]).sort()).toEqual(darkContract.order.filter((id) => id !== darkContract.defaultId).sort());
    const pairs = [
      ['--o-success-text', '--o-success'],
      ['--o-error-text', '--o-error'],
      ['--o-info-text', '--o-info'],
    ];
    const failures: string[] = [];
    for (const selector of ["[data-theme='dark']", ...palettes]) {
      const merged = new Map([...base, ...(selector === "[data-theme='dark']" ? [] : declarations(selector))]);
      // Follow plain var() aliases to the final value within this palette.
      const resolve = (name: string, depth = 0): string | undefined => {
        const value = merged.get(name);
        const alias = value?.match(/^var\((--o-[\w-]+)\)$/);
        return alias && depth < 8 ? resolve(alias[1], depth + 1) : value;
      };
      for (const [text, status] of pairs) {
        const got = resolve(text);
        const want = resolve(status);
        if (got == null || got !== want) failures.push(`${selector} ${text}=${got} ${status}=${want}`);
      }
    }
    expect(failures, 'dark status text must equal the same palette status color').toEqual([]);
  });
});
