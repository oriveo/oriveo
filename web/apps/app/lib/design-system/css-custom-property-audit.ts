/**
 * Static audit of CSS custom properties across the web workspaces.
 *
 * A `var(--x)` whose property is never defined resolves to the guaranteed-invalid value and the
 * declaration is dropped. Nothing throws, nothing logs, and jsdom's `getComputedStyle` cannot see
 * it either, so this class of mistake survives every runtime test. The audit reads the `.css`
 * sources directly instead.
 *
 * A reference is legitimate when one of these holds:
 *   (a) the property is a design token, always defined in the tokens file below;
 *   (b) the property is written from JS at runtime (inline style, `setProperty`, a Tailwind
 *       arbitrary property, or a CSS module that is not the one being scanned) and is registered
 *       in `ALLOWED`;
 *   (c) the reference carries a deliberate fallback, e.g. `var(--x, 0ms)`.
 *
 * Definitions:
 *   - token = a `--o-` property declared in `packages/ui/src/tokens/variables.css` under
 *     `:root, [data-theme='light']` or `[data-theme='dark']`. The dark block is authoritative;
 *     `prefers-color-scheme` is not consulted.
 *   - app-local = anything else defined by the file under audit or by a module it is composed with.
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { WEB_ROOT, collectSourceCssFiles } from './source-css-files';

export { WEB_ROOT };

const TOKENS_FILE = 'packages/ui/src/tokens/variables.css';

/**
 * Workspace prefixes to scan. `source-css-files.ts` asks git for the file list, so build output
 * and anything else ignored by `.gitignore` never reaches the audit.
 */
const SCAN_PREFIXES = ['apps', 'packages'] as const;

/** One registered exception: the property, why it is legitimate, and where it is referenced. */
export interface AllowedCustomProperty {
  /** Property name without the leading `--`. */
  readonly name: string;
  /**
   * `injected` covers case (b): the property is written from JS or by another stylesheet.
   * `intentional-fallback` covers case (c): every reference carries a fallback on purpose.
   */
  readonly kind: 'injected' | 'intentional-fallback';
  /** Stylesheets that reference the property, relative to the `web/` root. */
  readonly files: readonly string[];
  /** Why this is not a missing token. */
  readonly reason: string;
}

export const ALLOWED: readonly AllowedCustomProperty[] = [
  // Properties written from JS: inline style, setProperty, or a Tailwind arbitrary property.
  {
    name: 'kind-accent',
    kind: 'injected',
    files: ['apps/app/components/providers/RelayKindPicker.module.css'],
    reason: 'Set as an inline style by components/providers/RelayKindPicker.tsx, one accent per relay kind.',
  },
  {
    name: 'skill-color',
    kind: 'injected',
    files: [
      'apps/app/app/skills/SkillsPage.module.css',
      'apps/app/components/chat/SkillStarterView.module.css',
      'apps/app/components/mobile/MobileHomeView.module.css',
      'apps/app/components/sidebar/SkillsPills.module.css',
    ],
    reason: 'Set as an inline style from skill.color by app/skills/SkillsPage.tsx, components/chat/SkillStarterView.tsx and components/chat/SkillIntro.tsx.',
  },
  {
    name: 'i',
    kind: 'injected',
    files: ['apps/app/app/skills/SkillsPage.module.css'],
    reason: 'Per-item stagger index set as an inline style by app/skills/SkillsPage.tsx.',
  },
  {
    name: 'card-bg',
    kind: 'injected',
    files: ['apps/app/app/providers/new/ProviderCard.module.css'],
    reason: 'Per-provider card background set as an inline style by app/providers/new/ProviderCard.tsx.',
  },
  {
    name: 'card-accent',
    kind: 'injected',
    files: ['apps/app/app/providers/new/ProviderCard.module.css'],
    reason: 'Per-provider card accent set as an inline style by app/providers/new/ProviderCard.tsx.',
  },
  ...(['seg-c', 'seg-c-dark'] as const).map((name) => ({
    name,
    kind: 'injected' as const,
    files: ['apps/app/components/providers/ProviderCostSummaryCard.module.css'],
    reason: 'Per-segment cost bar color set as an inline style by components/providers/ProviderCostSummaryCard.tsx.',
  })),
  ...(['chip-c', 'chip-c-dark'] as const).map((name) => ({
    name,
    kind: 'injected' as const,
    files: ['apps/app/components/providers/ProviderCostSummaryCard.module.css'],
    reason: 'Per-chip legend color set as an inline style by components/providers/ProviderCostSummaryCard.tsx.',
  })),
  {
    name: 'section-tint-dark',
    kind: 'injected',
    files: ['apps/app/app/providers/[providerId]/components/RelayTintedSection.module.css'],
    reason: 'Section tint set as an inline style by app/providers/[providerId]/components/RelayTintedSection.tsx.',
  },
  {
    name: 'menu-select-min-width',
    kind: 'injected',
    files: ['apps/app/components/MenuSelect.module.css'],
    reason: 'Set from the minWidth prop as an inline style by components/MenuSelect.tsx.',
  },
  {
    name: 'menu-select-menu-min-width',
    kind: 'injected',
    files: ['apps/app/components/MenuSelect.module.css'],
    reason: 'Set from the menuMinWidth prop as an inline style by components/MenuSelect.tsx.',
  },
  ...(
    [
      'vendor-frame-bg',
      'vendor-frame-fg',
      'vendor-logo-padding-x',
      'vendor-logo-padding-y',
      'vendor-logo-shift-x',
      'vendor-logo-shift-y',
      'vendor-logo-scale',
    ] as const
  ).map((name) => ({
    name,
    kind: 'injected' as const,
    files: ['apps/app/components/VendorIdentity.module.css'],
    reason: 'Per-vendor logo framing set as an inline style by components/VendorIdentity.tsx.',
  })),
  {
    name: 'o-crosscheck-sidebar-width',
    kind: 'injected',
    files: ['apps/app/components/chat/CrosscheckSheet.module.css'],
    reason: 'Written onto document.body with setProperty by components/chat/CrosscheckSheet.tsx.',
  },
  {
    name: 'folder-color',
    kind: 'injected',
    files: ['apps/app/components/notes/Notes.module.css'],
    reason: 'Per-folder color set as an inline style by components/notes/NoteFolderList.tsx.',
  },
  {
    name: 'o-sidebar-width-user',
    kind: 'injected',
    files: ['packages/ui/src/components/AppShell/AppShell.module.css'],
    reason: 'User-dragged sidebar width set as an inline style by packages/ui/src/components/AppShell/AppShell.tsx; it feeds --o-sidebar-width.',
  },
  {
    name: 'o-mobile-tabbar-height',
    kind: 'injected',
    files: ['apps/app/components/mobile/MobileHomeView.module.css'],
    reason: 'Defined on the AppShell shell class in packages/ui/src/components/AppShell/AppShell.module.css and read here with an 88px fallback, so the mobile view does not have to import the shell stylesheet.',
  },

  // Fonts registered through next/font, which defines the variable on <html>.
  {
    name: 'font-inter',
    kind: 'injected',
    files: [TOKENS_FILE],
    reason: 'Declared by next/font in app/layout.tsx as variable "--font-inter" on <html>.',
  },
  {
    name: 'font-jetbrains-mono',
    kind: 'injected',
    files: [TOKENS_FILE],
    reason: 'Declared by next/font in app/layout.tsx as variable "--font-jetbrains-mono" on <html>.',
  },
];

export interface VarReference {
  readonly file: string;
  readonly line: number;
  readonly name: string;
  readonly hasFallback: boolean;
}

export interface Violation extends VarReference {
  /** Token names close enough to be a likely typo of the referenced property. */
  readonly suggestions: readonly string[];
}

/** Blanks out comment bodies while preserving line numbers. */
function stripComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, (chunk) => chunk.replace(/[^\n]/g, ' '));
}

interface ParsedCss {
  readonly file: string;
  readonly isModule: boolean;
  readonly defined: ReadonlySet<string>;
  readonly references: readonly VarReference[];
}

function parseCss(file: string): ParsedCss {
  const source = stripComments(readFileSync(join(WEB_ROOT, file), 'utf8'));
  const defined = new Set<string>();
  for (const match of source.matchAll(/(?:^|[;{\s])--([A-Za-z0-9_-]+)\s*:/g)) defined.add(match[1]);
  // `@property --x { … }`  
  for (const match of source.matchAll(/@property\s+--([A-Za-z0-9_-]+)/g)) defined.add(match[1]);

  const references: VarReference[] = [];
  for (const match of source.matchAll(/var\(\s*--([A-Za-z0-9_-]+)\s*(,)?/g)) {
    references.push({
      file,
      line: source.slice(0, match.index).split('\n').length,
      name: match[1],
      hasFallback: Boolean(match[2]),
    });
  }
  return { file, isModule: file.endsWith('.module.css'), defined, references };
}

function appOf(file: string): string {
  const match = /^apps\/([^/]+)\//.exec(file);
  return match ? `apps/${match[1]}` : 'packages';
}

function levenshtein(a: string, b: string): number {
  const rows = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array<number>(b.length).fill(0)]);
  for (let j = 0; j <= b.length; j++) rows[0][j] = j;
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      rows[i][j] = Math.min(
        rows[i - 1][j] + 1,
        rows[i][j - 1] + 1,
        rows[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1),
      );
    }
  }
  return rows[a.length][b.length];
}

/**
 * Historical misnames mapped to the token that replaced them.
 *
 * Edit distance is useless for a rename that changed the whole word: `--o-accent` is seven edits
 * from `--o-primary` and ranks below `--o-success`, so the suggestion engine would confidently
 * offer the wrong answer. These pairs were resolved by hand once and pinned here.
 */
export const KNOWN_ALIASES: Readonly<Record<string, string>> = {
  'o-accent': 'o-primary',
  'o-surface-2': 'o-surface-raised',
  'o-surface-elevated': 'o-surface-raised',
  'o-surface-subtle': 'o-bg-subtle',
  'o-surface-inset': 'o-bg-inset',
  'o-surface-hover': 'o-surface-raised',
  'o-surface-muted': 'o-bg-inset',
  'o-text-primary': 'o-text',
  'o-text-md': 'o-text-base',
  'o-border-subtle': 'o-border',
  'o-border-default': 'o-border',
  'o-danger': 'o-error',
  'o-status-error': 'o-error',
  'o-status-success': 'o-success',
  'o-on-primary': 'o-primary-text',
  'o-mono': 'o-font-mono',
  'font-mono': 'o-font-mono',
  'o-weight-bold': 'o-weight-semibold',
  'o-brand': 'o-primary',
  'o-color-bg': 'o-bg',
  'o-color-text': 'o-text',
  'o-color-text-secondary': 'o-text-secondary',
  'o-color-text-tertiary': 'o-text-tertiary',
  'o-color-primary': 'o-primary',
  'o-color-danger': 'o-error',
  'text-primary': 'o-text',
  'text-secondary': 'o-text-secondary',
  border: 'o-border',
};

function suggest(name: string, candidates: readonly string[]): string[] {
  const alias = KNOWN_ALIASES[name];
  const nearest = [...candidates]
    .filter((candidate) => candidate !== alias)
    .map((candidate) => ({ candidate, distance: levenshtein(name, candidate) }))
    .sort((a, b) => a.distance - b.distance || a.candidate.localeCompare(b.candidate))
    .slice(0, alias ? 2 : 3)
    .map((entry) => `--${entry.candidate}`);
  // A known correspondence goes first, marked so it does not read as a guess.
  return alias ? [`--${alias} `, ...nearest] : nearest;
}

export interface AuditResult {
  readonly violations: readonly Violation[];
  /** Registered exceptions without a single live reference; each one is a future hole. */
  readonly staleAllowances: readonly string[];
  /** References registered as `intentional-fallback` that carry no fallback, so the claim is false. */
  readonly fallbacklessAllowances: readonly string[];
  readonly scannedFiles: number;
  readonly tokenCount: number;
}

export function auditCssCustomProperties(): AuditResult {
  const parsed = collectSourceCssFiles(SCAN_PREFIXES).map(parseCss);

  const tokens = parsed.find((entry) => entry.file === TOKENS_FILE);
  if (!tokens) throw new Error(`design token source not found: ${TOKENS_FILE}`);
  const tokenNames = [...tokens.defined];

  /** Each app's global scope: the design tokens plus every non-module `.css` in that app. */
  const globalScope = new Map<string, Set<string>>();
  for (const entry of parsed) {
    if (entry.isModule) continue;
    const app = appOf(entry.file);
    const scope = globalScope.get(app) ?? new Set<string>();
    for (const name of entry.defined) scope.add(name);
    globalScope.set(app, scope);
  }
  for (const scope of globalScope.values()) for (const name of tokenNames) scope.add(name);

  const allowedByName = new Map(ALLOWED.map((entry) => [entry.name, entry]));
  const usedAllowances = new Set<string>();
  const fallbacklessAllowances: string[] = [];
  const violations: Violation[] = [];

  for (const entry of parsed) {
    const scope = globalScope.get(appOf(entry.file)) ?? new Set(tokenNames);
    for (const reference of entry.references) {
      if (scope.has(reference.name) || entry.defined.has(reference.name)) continue;
      const allowance = allowedByName.get(reference.name);
      if (allowance?.files.includes(entry.file)) {
        usedAllowances.add(`${allowance.name}@${entry.file}`);
        // The whole point of the `intentional-fallback` class is the fallback.
        if (allowance.kind === 'intentional-fallback' && !reference.hasFallback) {
          fallbacklessAllowances.push(`--${reference.name} @ ${reference.file}:${reference.line}`);
        }
        continue;
      }
      violations.push({ ...reference, suggestions: suggest(reference.name, tokenNames) });
    }
  }

  const staleAllowances = ALLOWED.flatMap((entry) =>
    entry.files.filter((file) => !usedAllowances.has(`${entry.name}@${file}`)).map((file) => `--${entry.name} @ ${file}`),
  );

  return {
    violations,
    staleAllowances,
    fallbacklessAllowances,
    scannedFiles: parsed.length,
    tokenCount: tokenNames.length,
  };
}

/** Renders a violation report: file, line, property, likely token, and how to register an exception. */
export function formatViolations(violations: readonly Violation[]): string {
  if (violations.length === 0) return '';
  const lines = violations.map(
    (violation) =>
      `  ${violation.file}:${violation.line}  var(--${violation.name}${violation.hasFallback ? ', …' : ''})\n` +
      `      ↳ This name is defined nowhere: not in the token source, not in this app's global stylesheets, not locally in this file.\n` +
      `      ↳ You may have meant: ${violation.suggestions.join('  /  ')}\n` +
      `      ↳ If it is in fact injected by JS inline style / setProperty / a Tailwind arbitrary property / an ancestor module, ` +
      `register it in ALLOWED in apps/app/lib/design-system/css-custom-property-audit.ts, stating the injection point.`,
  );
  return `\nFound ${violations.length} reference(s) to undefined CSS custom properties:\n${lines.join('\n')}\n`;
}
