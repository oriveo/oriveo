/**
 * Contrast gate for semantic colors used as body text.
 *
 * The vivid group `--o-success` / `--o-error` / `--o-warning` / `--o-info` / `--o-primary` is
 * meant for non-text use (fills, icons, strokes, badge backgrounds) where WCAG only asks for
 * 3:1. Written straight into `color:` none of them reach the 4.5:1 body-text threshold in the
 * light theme: against #FFFFFF they measure success 2.54 / warning 2.15 / error 3.76 /
 * info 3.68 / primary 4.23.
 *
 * These gaps stayed invisible because another defect masked them: the call sites referenced
 * ghost names such as `--o-status-success` / `--o-danger`, and an undefined `var()` with no
 * fallback invalidates the whole `color` declaration at computed-value time (IACVT), so the
 * text inherited the parent body color and rendered at 15:1. Only once the ghost names resolve
 * and the semantic colors actually take effect does the tokens' own AA gap become observable.
 *
 * The assertions have to work on the CSS source: jsdom does not cascade or resolve custom
 * properties, so `getComputedStyle` always returns the literal the author wrote. It can detect
 * neither "this name does not exist" nor "this token only reaches 2.2:1 on this background".
 * Same approach as components/generation/GenerationParameterPanel.visual-contract.test.ts and
 * lib/design-system/css-custom-property-audit.ts.
 *
 * Three layers of defence:
 *   1. `TEXT_VARIANT_TOKENS` -- the text variants themselves clear 4.5:1 on both themes and
 *      both declared backgrounds.
 *   2. `VERIFIED_TEXT_SITES` -- each text usage is composited from the live CSS source (color
 *      and every background layer are read at run time) and must clear 4.5:1. A site claiming
 *      the 3:1 large-text exemption has its font-size/font-weight read to prove it qualifies.
 *   3. `scanBareVividSemanticText()` -- scans the tree for rules that declare both a font-size
 *      and a bare vivid semantic color, and requires every hit to appear in the table above,
 *      in `KNOWN_GAPS`, or in `LEGACY_UNTRIAGED`. A new one turns the gate red.
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { WEB_ROOT, collectSourceCssFiles } from './source-css-files';

export { WEB_ROOT };

const TOKENS_FILE = 'packages/ui/src/tokens/variables.css';
/**
 * The scan surface is source code, and `.gitignore` decides what counts as source (see the
 * notes in `source-css-files.ts`). Build output such as `apps/app/out-desktop/` holds
 * lightningcss-minified CSS with hashed class names: once a desktop export has been produced
 * locally, the scanner reports every site a second time under a different file and class name
 * and the gate turns red with no source change. A hand-maintained directory blocklist regressed
 * every time a directory name was missed, so the question goes to git instead.
 */
const SCAN_PREFIXES = ['apps/app', 'packages/ui'] as const;

/** Vivid semantic colors are for non-text use only; written into `color:` they must be swapped for the matching `-text` variant. */
export const VIVID_SEMANTIC_TOKENS = ['--o-success', '--o-warning', '--o-error', '--o-info', '--o-primary'] as const;

/** Vivid color -> the text variant to use instead, so a failure reports the answer rather than leaving it to be guessed. */
export const TEXT_VARIANT_OF: Readonly<Record<string, string>> = {
  '--o-success': '--o-success-text',
  '--o-warning': '--o-warning-text',
  '--o-error': '--o-error-text',
  '--o-info': '--o-info-text',
  '--o-primary': '--o-primary-text-on-surface',
};

/**
 * A variant token has to pass on both of these backdrops. Two rather than one because this copy
 * (error bars, success cards, field errors, badges) appears on the `--o-surface` white card and
 * on the `--o-bg-subtle` grey alike; tuning only for white would be self-deception.
 */
export const REQUIRED_BACKDROPS = ['--o-surface', '--o-bg-subtle'] as const;

export const AA_NORMAL_TEXT = 4.5;
export const AA_LARGE_TEXT = 3;

// ─────────────────────────── Color evaluation ───────────────────────────

export type Rgba = readonly [number, number, number, number];
export type Theme = 'light' | 'dark';

const NAMED_COLORS: Readonly<Record<string, Rgba>> = {
  white: [255, 255, 255, 1],
  black: [0, 0, 0, 1],
  transparent: [0, 0, 0, 0],
};

/** Strips block comments while keeping the newlines, so line numbers do not shift. */
function stripComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, (chunk) => chunk.replace(/[^\n]/g, ' '));
}

function splitTopLevel(input: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let current = '';
  for (const char of input) {
    if (char === '(') depth += 1;
    if (char === ')') depth -= 1;
    if (char === ',' && depth === 0) {
      parts.push(current);
      current = '';
      continue;
    }
    current += char;
  }
  parts.push(current);
  return parts.map((part) => part.trim());
}

function splitPercentage(input: string): [string, number | null] {
  const trailing = /^([\s\S]+?)\s+([\d.]+)%$/.exec(input.trim());
  if (trailing) return [trailing[1].trim(), Number.parseFloat(trailing[2])];
  const leading = /^([\d.]+)%\s+([\s\S]+)$/.exec(input.trim());
  if (leading) return [leading[2].trim(), Number.parseFloat(leading[1])];
  return [input.trim(), null];
}

export interface ThemeTokens {
  readonly light: ReadonlyMap<string, string>;
  readonly dark: ReadonlyMap<string, string>;
}

function collectDeclarations(source: string): Map<string, string> {
  const tokens = new Map<string, string>();
  for (const match of source.matchAll(/(--[a-zA-Z0-9-]+)\s*:\s*([^;]+);/g)) tokens.set(match[1], match[2].trim());
  return tokens;
}

/**
 * The source has exactly two theme blocks, `:root,[data-theme='light']` and
 * `[data-theme='dark']`, with no `prefers-color-scheme` fallback. The dark block redefines only
 * part of the tokens and inherits the rest from the light block.
 */
export function readThemeTokens(): ThemeTokens {
  const source = stripComments(readFileSync(join(WEB_ROOT, TOKENS_FILE), 'utf8'));
  const darkStart = source.indexOf("[data-theme='dark']");
  if (darkStart < 0) throw new Error(`${TOKENS_FILE}   [data-theme='dark']  `);
  const light = collectDeclarations(source.slice(0, darkStart));
  return { light, dark: new Map([...light, ...collectDeclarations(source.slice(darkStart))]) };
}

/** Evaluates a CSS color expression to RGBA. Supports hex, rgb(a), `var()` chains and `color-mix(in srgb ...)`. */
export function parseColor(raw: string, theme: Theme, tokens: ThemeTokens, depth = 0): Rgba {
  if (depth > 16) throw new Error(`var()  ${raw}`);
  const value = raw.trim();

  const named = NAMED_COLORS[value];
  if (named) return named;

  const hex = /^#([0-9a-fA-F]{3,8})$/.exec(value);
  if (hex) {
    let digits = hex[1];
    if (digits.length === 3 || digits.length === 4) digits = [...digits].map((d) => d + d).join('');
    const channels = [0, 2, 4].map((offset) => Number.parseInt(digits.slice(offset, offset + 2), 16));
    const alpha = digits.length === 8 ? Number.parseInt(digits.slice(6, 8), 16) / 255 : 1;
    return [channels[0], channels[1], channels[2], alpha];
  }

  const rgb = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)\s*(?:[,/]\s*([\d.%]+))?\s*\)$/.exec(value);
  if (rgb) {
    const alpha = rgb[4] === undefined ? 1 : rgb[4].endsWith('%') ? Number.parseFloat(rgb[4]) / 100 : Number(rgb[4]);
    return [Number(rgb[1]), Number(rgb[2]), Number(rgb[3]), alpha];
  }

  const reference = /^var\(\s*(--[a-zA-Z0-9-]+)\s*(?:,\s*([\s\S]+))?\)$/.exec(value);
  if (reference) {
    const resolved = tokens[theme].get(reference[1]);
    // No value means the name does not exist in the design system: in production the whole declaration is IACVT, or always hits the literal fallback.
    if (resolved !== undefined) return parseColor(resolved, theme, tokens, depth + 1);
    if (reference[2]) throw new Error(`${reference[1]}   ${theme}   fallback ${reference[2]} `);
    throw new Error(`${reference[1]}   ${theme}   IACVT`);
  }

  const mix = /^color-mix\(\s*in\s+srgb\s*,\s*([\s\S]+)\)$/.exec(value);
  if (mix) {
    const operands = splitTopLevel(mix[1]);
    if (operands.length !== 2) throw new Error(`color-mix  ${value}`);
    const [firstColor, firstPercent] = splitPercentage(operands[0]);
    const [secondColor, secondPercent] = splitPercentage(operands[1]);
    let weightA = firstPercent;
    let weightB = secondPercent;
    if (weightA === null && weightB === null) [weightA, weightB] = [50, 50];
    else if (weightA === null) weightA = 100 - (weightB as number);
    else if (weightB === null) weightB = 100 - weightA;
    const total = (weightA as number) + (weightB as number);
    const ratioA = (weightA as number) / total;
    const ratioB = (weightB as number) / total;
    const a = parseColor(firstColor, theme, tokens, depth + 1);
    const b = parseColor(secondColor, theme, tokens, depth + 1);
    // CSS color-mix interpolates with premultiplied alpha in srgb.
    const alpha = a[3] * ratioA + b[3] * ratioB;
    if (alpha === 0) return [0, 0, 0, 0];
    const channels = [0, 1, 2].map((i) => (a[i] * a[3] * ratioA + b[i] * b[3] * ratioB) / alpha);
    return [channels[0], channels[1], channels[2], alpha];
  }

  throw new Error(` /  KNOWN_GAPS ${value}`);
}

/** source-over compositing: flattens a translucent foreground onto an opaque background. */
export function composite(foreground: Rgba, background: Rgba): Rgba {
  if (foreground[3] >= 1) return [foreground[0], foreground[1], foreground[2], 1];
  const channels = [0, 1, 2].map((i) => foreground[i] * foreground[3] + background[i] * (1 - foreground[3]));
  return [channels[0], channels[1], channels[2], 1];
}

/** WCAG 2.x relative luminance. */
export function relativeLuminance(color: Rgba): number {
  const [r, g, b] = [color[0], color[1], color[2]].map((channel) => {
    const value = channel / 255;
    return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrastRatio(foreground: Rgba, background: Rgba): number {
  const a = relativeLuminance(foreground);
  const b = relativeLuminance(background);
  const [lighter, darker] = a >= b ? [a, b] : [b, a];
  return (lighter + 0.05) / (darker + 0.05);
}

// ─────────────────────────── CSS source reading ───────────────────────────

const sourceCache = new Map<string, string>();

export function readCss(file: string): string {
  const cached = sourceCache.get(file);
  if (cached !== undefined) return cached;
  const source = stripComments(readFileSync(join(WEB_ROOT, file), 'utf8'));
  sourceCache.set(file, source);
  return source;
}

function normalizeSelector(selector: string): string {
  return selector.trim().replace(/\s+/g, ' ');
}

/**
 * Returns the declaration body of one rule.
 * Throws when the selector is missing, so a rename cannot be skipped silently, and throws on
 * multiple matches too: quietly taking the first of several same-name rules (an override inside
 * a media query, say) bets on cascade order, which is a common way for this kind of test to go
 * falsely green.
 */
export function readRuleBody(file: string, selector: string): string {
  const wanted = normalizeSelector(selector);
  const bodies = [...readCss(file).matchAll(/([^{}]+)\{([^{}]*)\}/g)]
    .filter((match) => normalizeSelector(match[1]) === wanted)
    .map((match) => match[2]);
  if (bodies.length === 0) throw new Error(`${file}   \`${selector}\` `);
  if (bodies.length > 1) {
    throw new Error(`${file}   \`${selector}\`   ${bodies.length}  `);
  }
  return bodies[0];
}

/** Returns the raw declaration text of one property in a rule, not its evaluated value. */
export function readDeclaration(file: string, selector: string, property: string): string {
  const body = readRuleBody(file, selector);
  const match = new RegExp(`(?:^|;)\\s*${property}\\s*:\\s*([^;]+)`).exec(body);
  if (!match) throw new Error(`${file} \`${selector}\`   ${property}`);
  return match[1].trim();
}

// ─────────────────────────── Registry ───────────────────────────

/**
 * A background layer. A string is a literal expression (the page background, a gradient stop
 * that can be resolved statically, and so on); an object reads `background` from the live CSS
 * rule, so editing that rule updates this table with it.
 */
export type BackgroundLayer = string | { readonly file?: string; readonly selector: string };

export interface TextSite {
  readonly id: string;
  readonly file: string;
  /** The rule selector verbatim; it must match the source file character for character. */
  readonly selector: string;
  /** Background layers, bottom first. The first layer must be opaque. */
  readonly layers: readonly BackgroundLayer[];
  /**
   * Required when claiming the 3:1 large-text exemption. Claiming it is not enough: the engine
   * reads font-size / font-weight from the rule and rechecks against WCAG (>=24px, or >=18.66px
   * at weight >=700), and falls back to 4.5:1 when the text is not actually large.
   */
  readonly largeTextExemption?: { readonly why: string };
  readonly note: string;
}

/**
 * Semantic-color-as-body-text sites that meet AA.
 * Each entry reads `color` and every `background` layer live, so reverting to a vivid token or
 * darkening a background turns the gate red immediately.
 */
export const VERIFIED_TEXT_SITES: readonly TextSite[] = [
  // ── Backup page: result card, the three message rows, recommended badge ──
  {
    id: 'backup-result-title',
    file: 'apps/app/app/settings/backup/BackupPage.module.css',
    selector: '.resultTitle',
    layers: ['var(--o-bg)', { selector: '.section' }, { selector: '.resultCard' }],
    note: ' /  --o-success 2.41:1 ',
  },
  {
    id: 'backup-success-message',
    file: 'apps/app/app/settings/backup/BackupPage.module.css',
    selector: '.successMsg',
    layers: ['var(--o-bg)', { selector: '.section' }, { selector: '.successMsg' }],
    note: 'Green success bar; was --o-success at 2.33:1.',
  },
  {
    id: 'backup-error-message',
    file: 'apps/app/app/settings/backup/BackupPage.module.css',
    selector: '.errorMsg',
    layers: ['var(--o-bg)', { selector: '.section' }, { selector: '.errorMsg' }],
    note: 'Red error bar; was --o-error at 3.30:1.',
  },
  {
    id: 'backup-warning-message',
    file: 'apps/app/app/settings/backup/BackupPage.module.css',
    selector: '.warningMsg',
    layers: ['var(--o-bg)', { selector: '.section' }, { selector: '.warningMsg' }],
    note: 'Yellow warning bar; --o-warning as body text is only 1.99:1.',
  },
];

/**
 * Neutral (non-semantic) text sites fixed in the same pass.
 * Kept separate because the vivid-semantic scanner ignores them, but the same
 * failure mode still applies when a background change pushes text under AA.
 */
export const VERIFIED_NEUTRAL_TEXT_SITES: readonly TextSite[] = [
  {
    id: 'notes-manual-source-token',
    file: 'apps/app/components/notes/Notes.module.css',
    selector: '.manualSourceToken',
    // .noteCard is a 145deg two-layer gradient; the chip sits at the top of the card, on the
    // --o-surface-card-from stop. The other stop (--o-surface) is lighter and only more
    // forgiving for dark text, so this end is the worst case.
    layers: ['var(--o-bg)', 'var(--o-surface-card-from)', { selector: '.manualSourceToken' }],
    note: '  chip  chip   --o-surface   --o-bg-subtle  --o-text-tertiary   4.42:1 ',
  },

  // ── Tier pills in the model options panel (light and dark measured separately) ──
  //
  // There is no disabled tier state: selectable tiers render as selectable, and when nothing is
  // selectable the whole block degrades to a single line of status text. So no `:disabled` pill
  // sites are registered here.
  {
    id: 'model-control-pill-unselected',
    file: 'apps/app/components/chat/InputComposer.module.css',
    selector: '.modelControlPill',
    // The pill sits inside the capability card (--o-bg-subtle) with --o-surface as its own fill.
    layers: ['var(--o-bg)', 'var(--o-surface)', 'var(--o-bg-subtle)', { selector: '.modelControlPill' }],
    note: '  --o-text-tertiary   4.40:1  --o-text-secondary ',
  },
  {
    id: 'model-control-pill-selected',
    file: 'apps/app/components/chat/InputComposer.module.css',
    selector: ".modelControlPill[data-active='true']",
    layers: [
      'var(--o-bg)', 'var(--o-surface)', 'var(--o-bg-subtle)',
      { selector: ".modelControlPill[data-active='true']" },
    ],
    note:
      '  pill accent  ** **——  --o-primary ' +
      '  4.23:1  text-safe  ',
  },
  // ── Explanatory text inside the panel ──
  //
  // `--o-text-tertiary` measures 4.3969:1 on the light `--o-bg-subtle` behind the capability
  // card, the read-only banner and the "Advanced settings >" row -- 0.1 short of AA, exactly the
  // kind of gap that looks fine until it is measured. Half of this family sits on the card and
  // half on the popover surface (--o-surface), so rather than splitting it across two greys the
  // whole family uses secondary, which clears 7:1 on both backgrounds in both themes.
  // Every entry registers both backgrounds: dropping back to tertiary, or moving a site into or
  // out of the card, fails immediately.
  {
    id: 'model-control-note-on-card',
    file: 'apps/app/components/chat/InputComposer.module.css',
    selector: '.modelControlNote',
    layers: ['var(--o-bg)', 'var(--o-surface)', 'var(--o-bg-subtle)'],
    note: ' tertiary   --o-bg-subtle   4.40:1  secondary ',
  },
  {
    id: 'model-control-note-on-surface',
    file: 'apps/app/components/chat/InputComposer.module.css',
    selector: '.modelControlNote',
    // The alternative-model page and the reload-failure sentences sit straight on the popover surface, with no card layer.
    layers: ['var(--o-bg)', 'var(--o-surface)'],
    note: ' ',
  },
  {
    id: 'model-control-subtitle',
    file: 'apps/app/components/chat/InputComposer.module.css',
    selector: '.modelControlsSubtitle',
    layers: ['var(--o-bg)', 'var(--o-surface)'],
    note: '  -   note  ',
  },
  {
    id: 'model-control-navigation-subtitle',
    file: 'apps/app/components/chat/InputComposer.module.css',
    selector: '.modelControlNavigationSubtitle',
    layers: ['var(--o-bg)', 'var(--o-surface)', { selector: '.modelControlNavigationRow' }],
    note: '  Token   --o-bg-subtle  tertiary   4.40:1 ',
  },
  {
    id: 'model-control-scope-upgrade-note',
    file: 'apps/app/components/chat/InputComposer.module.css',
    selector: '.modelControlScopeUpgradeNote',
    layers: ['var(--o-bg)', { selector: '.modelControlsFooter' }],
    note: ' 11px   secondary ',
  },

  // Badges are the only text in the panel that sits on a semantic color background: a 12% (20%
  // in dark) color-mix of warning / error. That is the combination most likely to land just
  // under the threshold, so both sites are registered and measured here.
  {
    id: 'model-control-badge-manual',
    file: 'apps/app/components/chat/InputComposer.module.css',
    selector: ".modelControlBadge[data-tone='manual']",
    layers: [
      'var(--o-bg)', 'var(--o-surface)', 'var(--o-bg-subtle)',
      { selector: ".modelControlBadge[data-tone='manual']" },
    ],
    note: '  /   Oriveo   /  warning   12%   --o-warning-text ',
  },
  {
    id: 'model-control-badge-unavailable',
    file: 'apps/app/components/chat/InputComposer.module.css',
    selector: ".modelControlBadge[data-tone='unavailable']",
    layers: [
      'var(--o-bg)', 'var(--o-surface)', 'var(--o-bg-subtle)',
      { selector: ".modelControlBadge[data-tone='unavailable']" },
    ],
    note: ' error   12%   --o-error-text ',
  },
];

/**
 * Sites that have been measured, confirmed to miss the threshold, and whose fix is larger than
 * swapping in a text variant.
 *
 * These record the measured value rather than ">=4.5": any change, better or worse, fails the
 * assertion and forces a fresh judgement instead of letting a known gap drift quietly. A fix
 * fails too, at which point the entry moves into `VERIFIED_TEXT_SITES`.
 */
export interface KnownGap {
  readonly id: string;
  readonly foreground: string;
  readonly layers: readonly BackgroundLayer[];
  readonly measured: { readonly light: number; readonly dark: number };
  readonly reason: string;
}

export const KNOWN_GAPS: readonly KnownGap[] = [
  {
    id: 'primary-fill-with-primary-text',
    foreground: 'var(--o-primary-text)',
    layers: ['var(--o-surface)', 'var(--o-primary)'],
    measured: { light: 4.2344, dark: 6.8896 },
    reason:
      'Primary fill with primary text on .btnPrimary and similar CTAs. Contrast is accepted as a known gap.',
  },
  {
    id: 'subscription-right-on-card-pro-with-glow',
    foreground: 'var(--o-primary-text-on-surface)',
    layers: [
      'var(--o-bg)',
      'color-mix(in srgb, var(--o-primary) 8%, var(--o-surface-raised))',
      'color-mix(in srgb, var(--o-primary) 14%, transparent)',
      'color-mix(in srgb, var(--o-primary) 22%, transparent)',
    ],
    measured: { light: 4.0233, dark: 2.7284 },
    reason:
      'Primary text on a card with a glow overlay. Contrast is accepted as a known gap.',
  },
];

/** Frozen baseline: bare semantic colors used as text that have not been triaged one by one yet. */
export const LEGACY_UNTRIAGED: readonly string[] = [
  'apps/app/app/providers/[providerId]/ModelBrowser.module.css {.allShortcutBadge}',
  'apps/app/app/providers/[providerId]/ProviderBalanceCard.module.css {.breakdownValueWarning}',
  'apps/app/app/providers/[providerId]/ProviderBalanceCard.module.css {.errorTitle}',
  'apps/app/app/providers/[providerId]/ProviderBalanceCard.module.css {.owingTag}',
  'apps/app/app/providers/[providerId]/ProviderBalanceCard.module.css {.retryChip}',
  'apps/app/app/providers/[providerId]/ProviderDetail.module.css {.dangerLabel}',
  'apps/app/app/providers/[providerId]/ProviderDetail.module.css {.editFieldError}',
  'apps/app/app/providers/[providerId]/ProviderDetail.module.css {.managedWalletError}',
  'apps/app/app/providers/[providerId]/components/RelayConnectionCard.module.css {.apiKeyEditError}',
  'apps/app/app/providers/[providerId]/components/RelayConnectionCard.module.css {.changeCapsule}',
  'apps/app/app/providers/[providerId]/components/RelayConnectionCard.module.css {.endpointError}',
  'apps/app/app/providers/[providerId]/manual-model/page.module.css {.providerChip}',
  'apps/app/app/providers/new/ProviderSetup.module.css {.fieldError}',
  'apps/app/app/providers/new/ProviderSetup.module.css {.helpLink}',
  'apps/app/app/providers/new/ProviderSetup.module.css {.manualLink}',
  'apps/app/app/providers/new/ProviderSetup.module.css {.progress}',
  'apps/app/app/providers/relay/new/RelaySetup.module.css {.fieldError}',
  'apps/app/app/providers/relay/new/RelaySetup.module.css {.statusCard > strong}',
  'apps/app/app/settings/Settings.module.css {.signInLink}',
  'apps/app/app/skills/edit/SkillEditPage.module.css {.addStarterBtn}',
  'apps/app/app/skills/edit/SkillEditPage.module.css {.inlineActionBtn}',
  'apps/app/app/welcome/Welcome.module.css {.errorMsg}',
  'apps/app/components/chat/AttachmentPreview.module.css {.ctaKnowledge}',
  'apps/app/components/chat/ChatView.module.css {.dragContent}',
  'apps/app/components/chat/CrosscheckSheet.module.css {.modelChevron}',
  'apps/app/components/chat/ImageGeneration.module.css {.toggle}',
  'apps/app/components/chat/LibraryContextPicker.module.css {.search button, .status button, .loadMore}',
  'apps/app/components/chat/MessageBubble.module.css {.metaActionBtn}',
  'apps/app/components/chat/MessageTokenUsageDialog.module.css {.total strong}',
  'apps/app/components/chat/NoteReferencePreview.module.css {.sourceChip}',
  'apps/app/components/conversations/ConflictCopyGroup.module.css {.banner}',
  'apps/app/components/mobile/MobileHomeView.module.css {.sectionHeader button}',
  'apps/app/components/notes/Notes.module.css {.countPill}',
  'apps/app/components/providers/RelayKindPicker.module.css {.badgeDefault}',
  'apps/app/components/providers/RelaySecurityModeControl.module.css {.change}',
  'apps/app/components/providers/RelaySecurityModeControl.module.css {.error}',
  'packages/ui/src/components/Input/Input.module.css {.error}',
  'packages/ui/src/components/PageSection/PageSection.module.css {.eyebrow}',
];

// ─────────────────────────── Evaluation and scanning ───────────────────────────

function resolveLayer(layer: BackgroundLayer, fallbackFile: string, theme: Theme, tokens: ThemeTokens): Rgba {
  if (typeof layer === 'string') return parseColor(layer, theme, tokens);
  return parseColor(readDeclaration(layer.file ?? fallbackFile, layer.selector, 'background'), theme, tokens);
}

/** Composites the background layers bottom-up into one opaque color. */
export function resolveBackground(
  layers: readonly BackgroundLayer[],
  fallbackFile: string,
  theme: Theme,
  tokens: ThemeTokens,
): Rgba {
  const bottom = resolveLayer(layers[0], fallbackFile, theme, tokens);
  if (bottom[3] < 1) throw new Error(' ');
  let result: Rgba = bottom;
  for (const layer of layers.slice(1)) result = composite(resolveLayer(layer, fallbackFile, theme, tokens), result);
  return result;
}

/** Reads the site's `color` and background layers live, composites them, and returns the actual contrast ratio. */
export function measureTextSite(site: TextSite, theme: Theme, tokens: ThemeTokens): number {
  const background = resolveBackground(site.layers, site.file, theme, tokens);
  const foreground = composite(parseColor(readDeclaration(site.file, site.selector, 'color'), theme, tokens), background);
  return contrastRatio(foreground, background);
}

export function measureKnownGap(gap: KnownGap, theme: Theme, tokens: ThemeTokens): number {
  const background = resolveBackground(gap.layers, TOKENS_FILE, theme, tokens);
  return contrastRatio(composite(parseColor(gap.foreground, theme, tokens), background), background);
}

/** WCAG large text: >=24px, or >=18.66px at font-weight >=700. */
export function isLargeText(fontSizePx: number, fontWeight: number): boolean {
  return fontSizePx >= 24 || (fontSizePx >= 18.66 && fontWeight >= 700);
}

/**
 * Reads font-size / font-weight from the rule to decide whether it really qualifies for 3:1.
 * Returns null when no exact pixel value can be resolved (a relative unit outside the known
 * size tokens, for instance): an undecidable case must be judged at 4.5:1, never waved through.
 */
export function readFontMetrics(file: string, selector: string, tokens: ThemeTokens): { size: number | null; weight: number } {
  const body = readRuleBody(file, selector);
  const sizeMatch = /(?:^|;)\s*font-size\s*:\s*([^;]+)/.exec(body);
  const weightMatch = /(?:^|;)\s*font-weight\s*:\s*([^;]+)/.exec(body);
  const weight = weightMatch ? Number.parseFloat(weightMatch[1].trim()) || 400 : 400;

  let raw = sizeMatch?.[1].trim();
  for (let i = 0; raw && i < 8; i += 1) {
    const reference = /^var\(\s*(--[a-zA-Z0-9-]+)\s*\)$/.exec(raw);
    if (!reference) break;
    raw = tokens.light.get(reference[1]);
  }
  const px = raw && /^[\d.]+px$/.test(raw) ? Number.parseFloat(raw) : null;
  return { size: px, weight };
}

export interface ScannedUsage {
  readonly key: string;
  readonly file: string;
  readonly selector: string;
  readonly token: string;
}

/**
 * Scans for rules that declare a font-size and a `color` and reference a vivid semantic color
 * directly.
 *
 * The font-size requirement is what makes this decidable from source: a bare `color` could be
 * tinting an SVG icon, which is held to the 3:1 non-text threshold instead. A rule that also
 * sets its own font-size is the author declaring that there is text here -- stable to detect
 * from source, and exactly the shape of the defect.
 *
 * Only bare references count (`color: var(--o-error)`). Something like
 * `color-mix(... var(--o-warning) 50%, black)` is already a deliberate darkening and is out of
 * scope.
 */
export function scanBareVividSemanticText(): ScannedUsage[] {
  const found: ScannedUsage[] = [];
  for (const file of collectSourceCssFiles(SCAN_PREFIXES)) {
    const source = stripComments(readFileSync(join(WEB_ROOT, file), 'utf8'));
    for (const rule of source.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const body = rule[2];
      if (!/(?:^|;|\s)font-size\s*:/.test(body)) continue;
      const declaration = /(?:^|;)\s*color\s*:\s*([^;]+)/.exec(body);
      if (!declaration) continue;
      const value = declaration[1].trim();
      const token = VIVID_SEMANTIC_TOKENS.find((name) => new RegExp(`^var\\(\\s*${name}\\s*[,)]`).test(value));
      if (!token) continue;
      const selector = normalizeSelector(rule[1]);
      found.push({ key: `${file} {${selector}}`, file, selector, token });
    }
  }
  return found.sort((a, b) => a.key.localeCompare(b.key));
}
